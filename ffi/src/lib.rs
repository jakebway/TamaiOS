//! C interface between the iPhone app and the tg18 (Tamagotchi ON / Meets)
//! emulator core. Every entry point catches panics so a bug in the core shows
//! up as an error code instead of crashing the app.

pub mod mm;

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use tg18::cpu::Bus;
use tg18::save::{self, SaveMeta};
use tg18::snapshot::Snapshot;
use tg18::sound::{CallDetector, ToneSynth};
use tg18::{Key, Machine, Outcome, CPU_HZ, FLASH_SIZE};

pub const AUDIO_RATE: u32 = 44100;

// tick results
pub const TG_OK: i32 = 0;
pub const TG_BLUETOOTH: i32 = 1;
pub const TG_INFRARED: i32 = 2;
pub const TG_BLE_RESTART: i32 = 3;
pub const TG_CRASH: i32 = 4;
pub const TG_STUCK: i32 = 5;
pub const TG_PANIC: i32 = 6;

// flags returned by tg_take_flags
pub const F_FRAME: u32 = 1;
pub const F_CALL: u32 = 2;
pub const F_SLEPT: u32 = 4;
pub const F_WOKE: u32 = 8;
pub const F_SYNCED: u32 = 16;

/// Tunables the console can change at runtime.
#[derive(Clone)]
struct Params {
    max_step: f64,
    max_behind: f64,
    max_catchup: f64,
    min_hold: f64,
    rewind_gap: f64,
}

impl Default for Params {
    fn default() -> Self {
        Params { max_step: 0.02, max_behind: 0.25, max_catchup: 10.0, min_hold: 0.05, rewind_gap: 1.0 }
    }
}

pub struct Emu {
    m: Machine,
    image: Arc<Vec<u8>>,
    synth: ToneSynth,
    calls: CallDetector,
    audio: Vec<i16>,
    audio_t: Option<f64>,
    behind: f64,
    rewind: Option<Snapshot>,
    rewind_at: f64,
    down: [bool; 3],
    frames_seen: u64,
    was_asleep: bool,
    flags: u32,
    stopped: Option<i32>,
    log: std::collections::VecDeque<String>,
    params: Params,
    last_speed: f64,
    boot_note: String,
    /// The phone's local time as toy-clock seconds, and the game time it was read at.
    wall: Option<(f64, f64)>,
    auto_sync: bool,
    last_drift: f64,
    /// Put to sleep from the app: "never sleep" waits until a button is pressed.
    sleep_hold: Option<bool>,
    /// This toy's own infrared line (swapped into the core while it runs).
    ir: tg18::sys::IrCtx,
}

fn log_line(e: &mut Emu, s: String) {
    if e.log.len() >= 400 {
        e.log.pop_front();
    }
    e.log.push_back(s);
}

fn key_of(k: i32) -> Option<Key> {
    match k {
        0 => Some(Key::A),
        1 => Some(Key::B),
        2 => Some(Key::C),
        _ => None,
    }
}

unsafe fn bytes<'a>(p: *const u8, n: usize) -> Option<&'a [u8]> {
    if p.is_null() || n == 0 {
        None
    } else {
        Some(std::slice::from_raw_parts(p, n))
    }
}

unsafe fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        None
    } else {
        Some(CStr::from_ptr(p).to_string_lossy().into_owned())
    }
}

/// Hand a Rust buffer to Swift; freed with tg_free.
fn give(v: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let mut b = v.into_boxed_slice();
    unsafe {
        *out_len = b.len();
        *out = b.as_mut_ptr();
    }
    std::mem::forget(b);
}

fn give_string(s: String, out: *mut *mut u8, out_len: *mut usize) {
    give(s.into_bytes(), out, out_len)
}

#[no_mangle]
pub extern "C" fn tg_free(p: *mut u8, n: usize) {
    if !p.is_null() {
        unsafe { drop(Box::from_raw(std::slice::from_raw_parts_mut(p, n))) };
    }
}

// --- ROM checking ---------------------------------------------------------------

#[repr(C)]
pub struct TgRomInfo {
    pub hash: u64,
    pub known: i32,
    pub name: [u8; 64],
    pub stem: [u8; 96],
}

fn put(dst: &mut [u8], s: &str) {
    let b = s.as_bytes();
    let n = b.len().min(dst.len() - 1);
    dst[..n].copy_from_slice(&b[..n]);
    dst[n] = 0;
}

/// Check a file the user picked.
///  0 = Tamagotchi ON/Meets dump (first 8 MiB used; bigger dumps are trimmed)
/// -1 = too small, -2 = not a tg18 flash dump, -3 = empty/erased.
#[no_mangle]
pub extern "C" fn tg_check_rom(p: *const u8, n: usize, info: *mut TgRomInfo) -> i32 {
    let data = match unsafe { bytes(p, n) } {
        Some(d) => d,
        None => return -1,
    };
    if data.len() < FLASH_SIZE {
        return -1;
    }
    let img = &data[..FLASH_SIZE];
    if img.iter().take(4096).all(|&b| b == 0xFF) || img.iter().take(4096).all(|&b| b == 0) {
        return -3;
    }
    if !tg18::is_image(img) {
        return -2;
    }
    if !info.is_null() {
        let i = unsafe { &mut *info };
        i.hash = tg18::code_hash(img);
        match tg18::roms::identify_hash(i.hash) {
            Some(k) => {
                i.known = 1;
                put(&mut i.name, &k.display_name());
                put(&mut i.stem, &k.stem());
            }
            None => {
                i.known = 0;
                put(&mut i.name, "Unknown version");
                put(&mut i.stem, &format!("fw_tg18_unknown_{:016x}", i.hash));
            }
        }
    }
    0
}

/// Look inside a .zip for a tg18 dump. Returns 0 and the 8 MiB image, or -1.
#[no_mangle]
pub extern "C" fn tg_rom_from_zip(p: *const u8, n: usize, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    let data = match unsafe { bytes(p, n) } {
        Some(d) => d,
        None => return -1,
    };
    match catch_unwind(|| zip_find(data)) {
        Ok(Some(img)) => {
            give(img, out, out_len);
            0
        }
        _ => -1,
    }
}

fn u16le(d: &[u8], o: usize) -> Option<usize> {
    d.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]]) as usize)
}
fn u32le(d: &[u8], o: usize) -> Option<usize> {
    d.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
}

fn zip_find(d: &[u8]) -> Option<Vec<u8>> {
    if d.len() < 22 {
        return None;
    }
    let start = d.len().saturating_sub(22 + 65535);
    let eocd = (start..=d.len() - 22).rev().find(|&i| d[i..i + 4] == [0x50, 0x4B, 0x05, 0x06])?;
    let count = u16le(d, eocd + 10)?;
    let mut off = u32le(d, eocd + 16)?;
    for _ in 0..count {
        if d.get(off..off + 4)? != [0x50, 0x4B, 0x01, 0x02] {
            return None;
        }
        let method = u16le(d, off + 10)?;
        let csize = u32le(d, off + 20)?;
        let usize_ = u32le(d, off + 24)?;
        let nlen = u16le(d, off + 28)?;
        let xlen = u16le(d, off + 30)?;
        let clen = u16le(d, off + 32)?;
        let local = u32le(d, off + 42)?;
        off += 46 + nlen + xlen + clen;
        if usize_ < FLASH_SIZE {
            continue;
        }
        let lnlen = u16le(d, local + 26)?;
        let lxlen = u16le(d, local + 28)?;
        let body = d.get(local + 30 + lnlen + lxlen..local + 30 + lnlen + lxlen + csize)?;
        let raw = match method {
            0 => body.to_vec(),
            8 => match miniz_oxide::inflate::decompress_to_vec(body) {
                Ok(v) => v,
                Err(_) => continue,
            },
            _ => continue,
        };
        if raw.len() >= FLASH_SIZE && tg18::is_image(&raw[..FLASH_SIZE]) {
            return Some(raw[..FLASH_SIZE].to_vec());
        }
    }
    None
}

#[no_mangle]
pub extern "C" fn tg_rtc_seconds(y: i64, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> f64 {
    tg18::rtc_seconds(y, mo, d, h, mi, s)
}

// --- creating ------------------------------------------------------------------

/// Switch on the built-in infrared partner (a pretend second toy that answers the toy's
/// PLAYDATE / GIFT / MARRY infrared connection). The core reads these two settings when
/// it builds a toy; the trace goes nowhere.
fn ir_partner_setup() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        if std::env::var_os("TG18_IR_TRACE").is_none() {
            std::env::set_var("TG18_IR_TRACE", "/dev/null");
        }
        std::env::set_var("TG18_IR_PARTNER", "1");
    });
}

/// Boot a toy from its newest save. `snap` = autosave snapshot bytes,
/// `flash` = the toy's own flash save with `meta` (its JSON), any may be null.
/// `rtc_now` = tg_rtc_seconds for the local time now. On success `elapsed`
/// gets the seconds the clock was moved forward by (0 if none).
#[no_mangle]
pub extern "C" fn tg_create(
    rom: *const u8,
    rom_len: usize,
    snap: *const u8,
    snap_len: usize,
    flash: *const u8,
    flash_len: usize,
    meta: *const c_char,
    rtc_now: f64,
    elapsed: *mut f64,
) -> *mut Emu {
    ir_partner_setup();
    let rom = match unsafe { bytes(rom, rom_len) } {
        Some(r) if r.len() >= FLASH_SIZE => r[..FLASH_SIZE].to_vec(),
        _ => return std::ptr::null_mut(),
    };
    let snap = unsafe { bytes(snap, snap_len) }.map(|s| s.to_vec());
    let flash = unsafe { bytes(flash, flash_len) }.map(|s| s.to_vec());
    let meta: Option<SaveMeta> = unsafe { cstr(meta) }.and_then(|t| serde_json::from_str(&t).ok());
    let r = catch_unwind(move || boot(rom, snap, flash, meta, rtc_now));
    match r {
        Ok(Some((e, el))) => {
            if !elapsed.is_null() {
                unsafe { *elapsed = el };
            }
            Box::into_raw(Box::new(e))
        }
        _ => std::ptr::null_mut(),
    }
}


// --- Places storage ----------------------------------------------------------------------
// The firmware's Places list is hard-wired for exactly two slots (code reads 0x710000 and 0x720000 directly),
// so more than two Places can be stored but never shown. An earlier build widened the storage record; this
// puts the stock record back and moves anything stored in the widened slots into the two real ones.
const PLACES_STOCK: [u8; 8] = [0x00, 0x00, 0x01, 0x00, 0x72, 0x02, 0x00, 0x00];
const PLACES_WIDE: [u8; 8] = [0x00, 0x90, 0x00, 0x00, 0x77, 0x05, 0x00, 0x00];

fn places_record(ram: &[u8]) -> Option<(usize, bool)> {
    let end = tg18::CODE_CHECK_LEN.min(ram.len()).saturating_sub(16);
    let mut i = 0x100000usize;
    while i < end {
        let w = &ram[i..i + 16];
        if w[8..] == [0u8; 8] {
            if w[..8] == PLACES_STOCK { return Some((i, false)); }
            if w[..8] == PLACES_WIDE { return Some((i, true)); }
        }
        i += 4;
    }
    None
}

/// Make a flash image's Places record the stock one again (true = stock). Places that were stored in the
/// widened slots are copied into any empty real slot so they show up on the toy.
fn places_stock_ram(ram: &mut [u8]) {
    let (at, wide) = match places_record(ram) { Some(r) => r, None => return };
    if !wide || ram.len() < 0x790000 { return; }
    let mut free: Vec<usize> = (0..2usize).map(|k| 0x710000 + k * 0x10000)
        .filter(|&o| ram[o..o + 0x10000].iter().all(|&b| b == 0xFF)).collect();
    for k in 0..5usize {
        let from = 0x760000 + k * 0x9000;
        if &ram[from..from + 6] != b"TAMAGO" { continue; }
        let dup = (0..2usize).any(|j| { let o = 0x710000 + j * 0x10000; &ram[o..o + 0x80] == &ram[from..from + 0x80] });
        if dup || free.is_empty() { continue; }
        let to = free.remove(0);
        for x in 0..0x9000 { ram[to + x] = ram[from + x]; }
    }
    ram[at..at + 8].copy_from_slice(&PLACES_STOCK);
}

fn places_wide(m: &mut Machine, _on: bool) { places_stock_ram(&mut m.sys.ram); }

fn new_emu(m: Machine, image: Arc<Vec<u8>>) -> Emu {
    let mut m = m;
    places_wide(&mut m, true);
    m.stop_on_bluetooth = true;
    m.sys.radio = Some(tg18::radio::Radio::new()); // the phone app is built in
    Emu {
        m,
        image,
        synth: ToneSynth::new(AUDIO_RATE, 0.6),
        calls: CallDetector::default(),
        audio: Vec::new(),
        audio_t: None,
        behind: 0.0,
        rewind: None,
        rewind_at: -1e9,
        down: [false; 3],
        frames_seen: u64::MAX,
        was_asleep: false,
        flags: F_FRAME,
        stopped: None,
        log: Default::default(),
        params: Params::default(),
        last_speed: 1.0,
        boot_note: String::new(),
        wall: None,
        auto_sync: true,
        last_drift: 0.0,
        sleep_hold: None,
        ir: Default::default(),
    }
}

fn boot(rom: Vec<u8>, snap: Option<Vec<u8>>, flash: Option<Vec<u8>>, meta: Option<SaveMeta>, rtc_now: f64) -> Option<(Emu, f64)> {
    let image = Arc::new(rom);
    let flash_at = meta.as_ref().map(|m| m.saved_at).unwrap_or(-1.0);
    // the snapshot, if it is the newest save and still matches the ROM
    if let Some(s) = snap.and_then(|b| Snapshot::from_bytes(&b).ok()) {
        if s.saved_at() >= flash_at {
            let mut m = Machine::new(image.clone(), &image, 0.0);
            if s.restore(&mut m).is_ok() {
                let mut e = new_emu(m, image.clone());
                let away = (tg18::unix_now() - s.saved_at()).max(0.0);
                e.boot_note = "Resumed from autosave".into();
                let mut moved = 0.0;
                if away > 30.0 {
                    if advance_clock(&mut e, away) {
                        moved = away;
                    } else {
                        e.m.sys.rtc.base_ticks += (away * 32768.0) as i64;
                        moved = away;
                    }
                }
                return Some((e, moved));
            }
        }
    }
    // the toy's own flash save
    if let Some(f) = flash {
        let same = f.len() == FLASH_SIZE && {
            // the Places storage record is the one thing allowed to differ from the stock ROM
            let mut probe = f.clone();
            places_stock_ram(&mut probe);
            probe[..tg18::CODE_CHECK_LEN] == image[..tg18::CODE_CHECK_LEN]
        };
        if same {
            let mut m = Machine::new(image.clone(), &f, rtc_now);
            let mut moved = 0.0;
            if let Some(meta) = &meta {
                save::restore_rtc(&mut m, meta, true);
                if meta.asleep {
                    m.press(0.0, Key::B);
                }
                moved = (tg18::unix_now() - meta.saved_at).max(0.0);
            }
            let mut e = new_emu(m, image.clone());
            e.boot_note = "Resumed from the toy's own save".into();
            return Some((e, moved));
        }
    }
    let m = Machine::new(image.clone(), &image, rtc_now);
    let mut e = new_emu(m, image);
    e.boot_note = "New toy".into();
    Some((e, 0.0))
}

#[no_mangle]
pub extern "C" fn tg_destroy(e: *mut Emu) {
    if !e.is_null() {
        unsafe { drop(Box::from_raw(e)) };
    }
}

fn with<R: Default>(e: *mut Emu, f: impl FnOnce(&mut Emu) -> R) -> R {
    if e.is_null() {
        return R::default();
    }
    let em = unsafe { &mut *e };
    catch_unwind(AssertUnwindSafe(|| f(em))).unwrap_or_default()
}

// --- running -------------------------------------------------------------------

/// Run for `real_dt` seconds of wall time. Returns a TG_* code.
#[no_mangle]
pub extern "C" fn tg_tick(e: *mut Emu, real_dt: f64) -> i32 {
    if e.is_null() {
        return TG_PANIC;
    }
    let em = unsafe { &mut *e };
    // the infrared line lives in process-wide state: only one toy runs at a time
    static TICK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _g = TICK.lock().unwrap_or_else(|p| p.into_inner());
    tg18::sys::ir_ctx_swap(&mut em.ir);
    let r = catch_unwind(AssertUnwindSafe(|| tick(em, real_dt)));
    tg18::sys::ir_ctx_swap(&mut em.ir);
    match r {
        Ok(c) => c,
        Err(_) => {
            em.stopped = Some(TG_PANIC);
            TG_PANIC
        }
    }
}

fn tick(e: &mut Emu, real: f64) -> i32 {
    if let Some(c) = e.stopped {
        return c;
    }
    let p = e.params.clone();
    let mut debt = e.behind + real.max(0.0);
    let dropped = (debt - p.max_behind).max(0.0);
    debt -= dropped;
    let step = debt.min(p.max_step);
    e.behind = debt - step;
    let t_start = e.m.now();
    let target = e.m.executed + (step * CPU_HZ) as u64;
    e.m.sys.turbo = if step > 0.0 { ((step + dropped) / step).min(p.max_catchup) } else { 1.0 };
    e.last_speed = e.m.sys.turbo;

    if e.m.sys.powered_off {
        let now = e.m.now();
        if e.m.never_sleep && !e.m.sys.key_script.iter().any(|&(t, _)| t >= now) {
            e.m.press(now, Key::B);
        }
        if !e.m.power_cycle(target) {
            e.m.sys.game_time += (target - e.m.executed) as f64 / CPU_HZ * e.m.sys.turbo;
            e.m.executed = target;
            e.m.sys.now = target as f64 / CPU_HZ;
        }
    } else {
        match e.m.run(target) {
            out @ (Outcome::Bluetooth | Outcome::Infrared) => {
                let code = if out == Outcome::Bluetooth { TG_BLUETOOTH } else { TG_INFRARED };
                log_line(e, format!("game asked for {:?}; rewinding", out));
                if !rewind(e) {
                    e.m.restart();
                    reset_timing(e);
                    return TG_BLE_RESTART;
                }
                return code;
            }
            Outcome::BleFail => {
                log_line(e, "BLE init fail; restarting".into());
                e.m.restart();
                reset_timing(e);
                return TG_BLE_RESTART;
            }
            out @ (Outcome::Crash | Outcome::Stuck) => {
                let c = if out == Outcome::Crash { TG_CRASH } else { TG_STUCK };
                log_line(e, format!("stopped {:?} pc={:08X} fault={:?}", out, e.m.cpu.pc(), e.m.fault()));
                e.stopped = Some(c);
                return c;
            }
            _ => {}
        }
    }
    for l in std::mem::take(&mut e.m.log) {
        log_line(e, format!("[fw] {}", l));
    }
    let t_end = e.m.now();
    let events = std::mem::take(&mut e.m.sys.sound.events);
    if e.calls.feed(&events) {
        e.flags |= F_CALL;
    }
    let start = *e.audio_t.get_or_insert(t_start);
    let rate = AUDIO_RATE as f64;
    let n = ((t_end - start) * rate).max(0.0) as usize;
    e.synth.render(&events, start, start + n as f64 / rate, n, &mut e.audio);
    e.audio_t = Some(start + n as f64 / rate);
    if e.audio.len() > AUDIO_RATE as usize {
        let cut = e.audio.len() - AUDIO_RATE as usize / 4;
        e.audio.drain(..cut);
    }
    let asleep = e.m.sys.powered_off;
    if asleep && !e.was_asleep {
        e.flags |= F_SLEPT;
    }
    if !asleep && e.was_asleep {
        e.flags |= F_WOKE;
    }
    if asleep != e.was_asleep || e.m.sys.lcd.frames != e.frames_seen {
        e.flags |= F_FRAME;
    }
    e.was_asleep = asleep;
    if asleep {
        auto_sync(e);
    }
    TG_OK
}

/// While the toy sleeps, keep its clock chip on the phone's time (the game
/// reads it when it next wakes). The wake alarm moves with it, so the
/// once-a-minute wake-ups carry on as before.
fn auto_sync(e: &mut Emu) {
    let (wall, at) = match e.wall {
        Some(w) => w,
        None => return,
    };
    let m = &mut e.m;
    let want = ((wall + (m.sys.game_time - at)) * 32768.0) as i64;
    let diff = want - m.sys.rtc.ticks(m.sys.game_time);
    e.last_drift = diff as f64 / 32768.0;
    if !e.auto_sync || diff.abs() < 30 * 32768 {
        return;
    }
    m.sys.rtc.base_ticks += diff;
    if let Some(alarm) = m.sys.rtc.alarm_ticks() {
        let a = (alarm + diff).max(0) as u64;
        for i in 0..6 {
            m.sys.rtc.regs[0x20 + i] = (a >> (8 * i)) as u8;
        }
    }
    let msg = format!("clock synced to phone (was off by {:.0} s)", diff as f64 / 32768.0);
    log_line(e, msg);
    e.flags |= F_SYNCED;
}

/// How far the toy's clock is from the phone's, in seconds (0 if unknown).
#[no_mangle]
pub extern "C" fn tg_clock_drift(e: *mut Emu) -> f64 {
    with(e, |e| match e.wall {
        Some((wall, at)) => {
            let m = &e.m;
            let want = ((wall + (m.sys.game_time - at)) * 32768.0) as i64;
            (want - m.sys.rtc.ticks(m.sys.game_time)) as f64 / 32768.0
        }
        None => 0.0,
    })
}

/// The phone's local time now, as tg_rtc_seconds gives it. Call about once a second.
#[no_mangle]
pub extern "C" fn tg_set_wall_clock(e: *mut Emu, rtc_now: f64) {
    with(e, |e| e.wall = Some((rtc_now, e.m.sys.game_time)))
}

fn reset_timing(e: &mut Emu) {
    e.behind = 0.0;
    e.audio_t = None;
    e.frames_seen = u64::MAX;
    e.flags |= F_FRAME;
}

fn rewind(e: &mut Emu) -> bool {
    release_all(e);
    let snap = match e.rewind.take() {
        Some(s) => s,
        None => return false,
    };
    let mut m = Machine::new(e.image.clone(), &e.image, 0.0);
    if snap.restore(&mut m).is_err() {
        return false;
    }
    m.stop_on_bluetooth = true;
    m.sys.radio = Some(tg18::radio::Radio::new());
    m.never_sleep = e.m.never_sleep;
    m.idle_skip = e.m.idle_skip;
    e.m = m;
    reset_timing(e);
    true
}

fn release_all(e: &mut Emu) {
    e.down = [false; 3];
    e.m.sys.live_keys = [false; 3];
}

#[no_mangle]
pub extern "C" fn tg_take_flags(e: *mut Emu) -> u32 {
    with(e, |e| std::mem::take(&mut e.flags))
}

#[no_mangle]
pub extern "C" fn tg_press(e: *mut Emu, key: i32, wall: f64) {
    with(e, |e| {
        let k = match key_of(key) {
            Some(k) => k,
            None => return,
        };
        let i = k.index();
        if e.down[i] {
            return;
        }
        e.down[i] = true;
        if let Some(v) = e.sleep_hold.take() {
            e.m.never_sleep = v;
        }
        if !e.m.sys.powered_off && wall - e.rewind_at >= e.params.rewind_gap {
            e.rewind = Some(Snapshot::capture(&e.m));
            e.rewind_at = wall;
        }
        e.m.sys.live_keys[i] = true;
        e.m.alarm_wake = false;
        let now = e.m.now();
        e.m.sys.hold_until[i] = now + e.params.min_hold;
        if e.m.sys.powered_off {
            e.m.sys.key_script.retain(|&(t, _)| t > now - 1.0);
            e.m.press(now, k);
        }
    })
}

#[no_mangle]
pub extern "C" fn tg_release(e: *mut Emu, key: i32) {
    with(e, |e| {
        if let Some(k) = key_of(key) {
            e.down[k.index()] = false;
            e.m.sys.live_keys[k.index()] = false;
        }
    })
}

#[no_mangle]
pub extern "C" fn tg_release_all(e: *mut Emu) {
    with(e, |e| release_all(e))
}

/// Copy the 128x128 screen as 0x00RRGGBB into `out` (16384 u32).
/// Returns 1 when the screen is dark (asleep / backlight off).
#[no_mangle]
pub extern "C" fn tg_frame(e: *mut Emu, out: *mut u32) -> i32 {
    with(e, |e| {
        if out.is_null() {
            return 0;
        }
        e.frames_seen = e.m.sys.lcd.frames;
        let px = unsafe { std::slice::from_raw_parts_mut(out, 128 * 128) };
        e.m.sys.lcd.argb(px);
        (e.m.sys.powered_off || e.m.alarm_wake) as i32
    })
}

#[no_mangle]
pub extern "C" fn tg_is_asleep(e: *mut Emu) -> i32 {
    with(e, |e| e.m.sys.powered_off as i32)
}

/// Move up to `max` audio samples (44.1 kHz mono i16) into `out`.
#[no_mangle]
pub extern "C" fn tg_take_audio(e: *mut Emu, out: *mut i16, max: usize) -> usize {
    with(e, |e| {
        if out.is_null() {
            return 0;
        }
        let n = e.audio.len().min(max);
        unsafe { std::ptr::copy_nonoverlapping(e.audio.as_ptr(), out, n) };
        e.audio.drain(..n);
        n
    })
}

#[no_mangle]
pub extern "C" fn tg_set_volume(e: *mut Emu, v: f64) {
    with(e, |e| e.synth.set_volume(v.clamp(0.0, 1.5)))
}

#[no_mangle]
pub extern "C" fn tg_set_never_sleep(e: *mut Emu, on: i32) {
    with(e, |e| match e.sleep_hold.as_mut() {
        Some(h) => *h = on != 0,
        None => e.m.never_sleep = on != 0,
    })
}

// --- saving, sleeping, the clock -------------------------------------------------

#[no_mangle]
pub extern "C" fn tg_snapshot(e: *mut Emu, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    with(e, |e| {
        give(Snapshot::capture(&e.m).to_bytes(), out, out_len);
        1
    })
}

/// Write the toy's own flash save to `path` (+ path.json).
#[no_mangle]
pub extern "C" fn tg_flash_save(e: *mut Emu, path: *const c_char) -> i32 {
    let path = match unsafe { cstr(path) } {
        Some(p) => p,
        None => return 0,
    };
    with(e, |e| {
        let asleep = e.m.sys.powered_off;
        save::write_machine(&e.m, &path, asleep, asleep).is_ok() as i32
    })
}

fn force_sleep(e: &mut Emu, limit: f64) -> bool {
    let m = &mut e.m;
    if m.sys.powered_off {
        return true;
    }
    let counter = match m.idle_counter {
        Some(c) => c,
        None => return false,
    };
    let never = m.never_sleep;
    m.never_sleep = false;
    let end = m.executed + (limit * CPU_HZ) as u64;
    while !m.sys.powered_off && m.executed < end {
        m.sys.poke(counter, &[0xFE]);
        let out = m.run(end.min(m.executed + CPU_HZ as u64 / 10));
        if !matches!(out, Outcome::Limit | Outcome::PowerOff) {
            break;
        }
    }
    m.never_sleep = never;
    m.sys.sound.events.clear();
    m.sys.powered_off
}

fn change_clock(e: &mut Emu, ticks: impl Fn(&Machine) -> i64) -> bool {
    if !force_sleep(e, 10.0) {
        return false;
    }
    let m = &mut e.m;
    let shift = ticks(m) - m.sys.rtc.ticks(m.sys.game_time);
    m.sys.rtc.base_ticks += shift;
    let now = m.now();
    m.press(now, Key::B);
    let limit = m.executed + CPU_HZ as u64;
    m.power_cycle(limit);
    // whatever the buzzer did while the clock was being moved is not played (it would be one long beep)
    m.sys.sound.events.clear();
    e.audio.clear();
    reset_timing(e);
    true
}

fn advance_clock(e: &mut Emu, secs: f64) -> bool {
    let add = (secs * 32768.0) as i64;
    change_clock(e, |m| m.sys.rtc.ticks(m.sys.game_time) + add)
}

/// Put the toy to sleep now (it saves itself, like the real one).
#[no_mangle]
pub extern "C" fn tg_force_sleep(e: *mut Emu) -> i32 {
    with(e, |e| {
        let r = force_sleep(e, 10.0);
        if r && e.sleep_hold.is_none() {
            // stay asleep (the once-a-minute clock wake-ups go straight back to sleep)
            e.sleep_hold = Some(e.m.never_sleep);
            e.m.never_sleep = false;
        }
        e.was_asleep = e.m.sys.powered_off;
        e.m.sys.sound.events.clear();
        e.audio.clear();
        reset_timing(e);
        r as i32
    })
}

/// Wake a sleeping toy with the middle button.
#[no_mangle]
pub extern "C" fn tg_wake(e: *mut Emu) {
    with(e, |e| {
        if e.m.sys.powered_off {
            let now = e.m.now();
            e.m.press(now, Key::B);
        }
    })
}

#[no_mangle]
pub extern "C" fn tg_advance_clock(e: *mut Emu, secs: f64) -> i32 {
    with(e, |e| advance_clock(e, secs) as i32)
}

#[no_mangle]
pub extern "C" fn tg_sync_clock(e: *mut Emu, rtc_seconds: f64) -> i32 {
    with(e, |e| change_clock(e, |_| (rtc_seconds * 32768.0) as i64) as i32)
}

/// Like pulling the batteries: flash and clock stay.
#[no_mangle]
pub extern "C" fn tg_restart(e: *mut Emu) {
    with(e, |e| {
        e.m.restart();
        e.stopped = None;
        release_all(e);
        reset_timing(e);
    })
}

// --- console ---------------------------------------------------------------------

/// Status, log and boot note as text.
#[no_mangle]
pub extern "C" fn tg_status(e: *mut Emu, out: *mut *mut u8, out_len: *mut usize) {
    let s = with(e, |e| {
        let m = &e.m;
        let p = &e.params;
        format!(
            "boot: {}\nclock drift vs phone: {:.0} s (auto_sync {})\nstopped: {:?}\nasleep: {} alarm_wake: {}\npc: {:08X} fault: {:?}\nexecuted: {} ({:.1} s emulated)\ngame_time: {:.1}\nirqs: {} frames: {}\nidle_skip: {} skipped: {} probes: {:?}\nnever_sleep: {} idle_counter: {:?}\nflash writes: {}\nrtc ticks: {} alarm: {:?}\nturbo: {:.2}\nbluetooth_used: {} ble_failed: {}\nparams: max_step={} max_behind={} max_catchup={} min_hold={} rewind_gap={}\naudio queued: {}",
            e.boot_note, e.last_drift, e.auto_sync, e.stopped, m.sys.powered_off, m.alarm_wake, m.cpu.pc(), m.fault(), m.executed, m.now(), m.sys.game_time,
            m.irqs, m.sys.lcd.frames, m.idle_skip, m.idle_skipped, m.probe_stats, m.never_sleep, m.idle_counter,
            m.sys.flash.writes, m.sys.rtc.ticks(m.sys.game_time), m.sys.rtc.alarm_ticks(), e.last_speed,
            m.bluetooth_used, m.ble_failed, p.max_step, p.max_behind, p.max_catchup, p.min_hold, p.rewind_gap, e.audio.len()
        )
    });
    give_string(s, out, out_len)
}

#[no_mangle]
pub extern "C" fn tg_log(e: *mut Emu, out: *mut *mut u8, out_len: *mut usize) {
    let s = with(e, |e| e.log.iter().cloned().collect::<Vec<_>>().join("\n"));
    give_string(s, out, out_len)
}

/// Set a tunable: max_step, max_behind, max_catchup, min_hold, rewind_gap,
/// idle_skip, never_sleep, print_log, turbo_now. Returns 1 if known.
#[no_mangle]
pub extern "C" fn tg_set_param(e: *mut Emu, name: *const c_char, v: f64) -> i32 {
    let name = match unsafe { cstr(name) } {
        Some(n) => n,
        None => return 0,
    };
    with(e, |e| {
        let p = &mut e.params;
        match name.as_str() {
            "max_step" => p.max_step = v.clamp(0.001, 0.5),
            "max_behind" => p.max_behind = v.clamp(0.0, 30.0),
            "max_catchup" => p.max_catchup = v.clamp(1.0, 1000.0),
            "min_hold" => p.min_hold = v.clamp(0.0, 1.0),
            "rewind_gap" => p.rewind_gap = v.clamp(0.0, 60.0),
            "idle_skip" => e.m.idle_skip = v != 0.0,
            "never_sleep" => e.m.never_sleep = v != 0.0,
            "stop_on_bluetooth" => e.m.stop_on_bluetooth = v != 0.0,
            "unstop" => e.stopped = None,
            "auto_sync" => e.auto_sync = v != 0.0,
            _ => return 0,
        }
        1
    })
}

#[no_mangle]
pub extern "C" fn tg_peek(e: *mut Emu, addr: u32, out: *mut u8, n: usize) -> i32 {
    with(e, |e| {
        if out.is_null() {
            return 0;
        }
        let o = unsafe { std::slice::from_raw_parts_mut(out, n) };
        for (i, b) in o.iter_mut().enumerate() {
            *b = e.m.sys.read8(addr.wrapping_add(i as u32));
        }
        1
    })
}

#[no_mangle]
pub extern "C" fn tg_poke(e: *mut Emu, addr: u32, data: *const u8, n: usize) -> i32 {
    let d = match unsafe { bytes(data, n) } {
        Some(d) => d.to_vec(),
        None => return 0,
    };
    with(e, |e| {
        e.m.sys.poke(addr, &d);
        1
    })
}

/// Queue a scripted press `delay` emulated seconds from now (works asleep too).
#[no_mangle]
pub extern "C" fn tg_script_press(e: *mut Emu, key: i32, delay: f64) {
    with(e, |e| {
        if let Some(k) = key_of(key) {
            let t = e.m.now() + delay.max(0.0);
            e.m.press(t, k);
        }
    })
}

/// Read a C string from emulated memory (for the console).
#[no_mangle]
pub extern "C" fn tg_read_cstr(e: *mut Emu, addr: u32, out: *mut *mut u8, out_len: *mut usize) {
    let s = with(e, |e| e.m.read_cstr(addr, 256));
    give_string(s, out, out_len)
}

/// 1 if `snap` is a snapshot that can be restored with this ROM.
#[no_mangle]
pub extern "C" fn tg_check_snapshot(rom: *const u8, rom_len: usize, snap: *const u8, snap_len: usize) -> i32 {
    let (rom, snap) = match unsafe { (bytes(rom, rom_len), bytes(snap, snap_len)) } {
        (Some(r), Some(s)) if r.len() >= FLASH_SIZE => (r[..FLASH_SIZE].to_vec(), s.to_vec()),
        _ => return 0,
    };
    catch_unwind(move || {
        let image = Arc::new(rom);
        let s = match Snapshot::from_bytes(&snap) {
            Ok(s) => s,
            Err(_) => return 0,
        };
        let mut m = Machine::new(image.clone(), &image, 0.0);
        s.restore(&mut m).is_ok() as i32
    })
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_moves_clock_and_alarm_while_asleep() {
        let mut img = vec![0u8; FLASH_SIZE];
        img[..4].copy_from_slice(b"SPII");
        let image = Arc::new(img);
        let m = Machine::new(image.clone(), &image, 1000.0);
        let mut e = new_emu(m, image);
        e.m.sys.rtc.regs[0x40] = 2; // alarm armed
        let alarm: u64 = 1060 * 32768;
        for i in 0..6 {
            e.m.sys.rtc.regs[0x20 + i] = (alarm >> (8 * i)) as u8;
        }
        e.wall = Some((5000.0, e.m.sys.game_time));
        // awake: nothing changes
        auto_sync(&mut e);
        let t = e.m.sys.rtc.ticks(e.m.sys.game_time);
        assert!(((t as f64 / 32768.0) - 5000.0).abs() < 1.0);
        // alarm stays 60 s ahead
        let a = e.m.sys.rtc.alarm_ticks().unwrap();
        assert!(((a - t) as f64 / 32768.0 - 60.0).abs() < 1.0);
        assert!(e.flags & F_SYNCED != 0);
        // small drift is left alone
        e.flags = 0;
        e.wall = Some((5010.0, e.m.sys.game_time));
        auto_sync(&mut e);
        assert_eq!(e.flags & F_SYNCED, 0);
    }
}

// --- Bluetooth module (the "phone app" side) ---------------------------------------

/// Turn the emulated Bluetooth module on (1) or off (0).
#[no_mangle]
pub extern "C" fn tg_radio_enable(e: *mut Emu, on: i32) {
    with(e, |e| {
        if on != 0 {
            if e.m.sys.radio.is_none() {
                e.m.sys.radio = Some(tg18::radio::Radio::new());
            }
            if let Some(r) = e.m.sys.radio.as_mut() {
                r.tracing = on == 2; // 2 = also keep a message log (console)
            }
        } else {
            e.m.sys.radio = None;
        }
    })
}

/// A phone connects (1) or disconnects (0).
#[no_mangle]
pub extern "C" fn tg_radio_connect(e: *mut Emu, on: i32) {
    with(e, |e| {
        if let Some(r) = e.m.sys.radio.as_mut() {
            r.connected = on != 0;
        }
    })
}

/// 1 once the firmware has set the module up for a connection.
#[no_mangle]
pub extern "C" fn tg_radio_ready(e: *mut Emu) -> i32 {
    with(e, |e| e.m.sys.radio.as_ref().map_or(0, |r| r.setup_done as i32))
}

/// Write from the phone (characteristic fff2). 1 = taken, 0 = try again.
#[no_mangle]
pub extern "C" fn tg_radio_write(e: *mut Emu, d: *const u8, n: usize) -> i32 {
    let d = match unsafe { bytes(d, n) } {
        Some(d) => d.to_vec(),
        None => return 1,
    };
    with(e, |e| e.m.sys.radio.as_mut().map_or(0, |r| r.from_phone(&d) as i32))
}

/// Next notification for the phone (characteristic fff1); 0 if none.
#[no_mangle]
pub extern "C" fn tg_radio_read(e: *mut Emu, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    let v = with(e, |e| e.m.sys.radio.as_mut().and_then(|r| r.to_phone.pop_front()));
    match v {
        Some(v) => {
            give(v, out, out_len);
            1
        }
        None => 0,
    }
}

/// The module's message log (for research).
#[no_mangle]
pub extern "C" fn tg_radio_trace(e: *mut Emu, out: *mut *mut u8, out_len: *mut usize) {
    let s = with(e, |e| e.m.sys.radio.as_ref().map(|r| r.trace.join("\n")).unwrap_or_default());
    give_string(s, out, out_len)
}

// --- Tama Town: marriage (see mm.rs) ------------------------------------------------

static TOWN: std::sync::Mutex<Option<mm::Library>> = std::sync::Mutex::new(None);

fn zip_entries(d: &[u8]) -> Vec<(String, Vec<u8>)> {
    let mut out = Vec::new();
    if d.len() < 22 {
        return out;
    }
    let start = d.len().saturating_sub(22 + 65535);
    let eocd = match (start..=d.len() - 22).rev().find(|&i| d[i..i + 4] == [0x50, 0x4B, 0x05, 0x06]) {
        Some(e) => e,
        None => return out,
    };
    let (count, mut off) = match (u16le(d, eocd + 10), u32le(d, eocd + 16)) {
        (Some(c), Some(o)) => (c, o),
        _ => return out,
    };
    for _ in 0..count {
        let ok = (|| -> Option<()> {
            if d.get(off..off + 4)? != [0x50, 0x4B, 0x01, 0x02] {
                return None;
            }
            let method = u16le(d, off + 10)?;
            let csize = u32le(d, off + 20)?;
            let nlen = u16le(d, off + 28)?;
            let xlen = u16le(d, off + 30)?;
            let clen = u16le(d, off + 32)?;
            let local = u32le(d, off + 42)?;
            let name = String::from_utf8_lossy(d.get(off + 46..off + 46 + nlen)?).to_string();
            off += 46 + nlen + xlen + clen;
            let lnlen = u16le(d, local + 26)?;
            let lxlen = u16le(d, local + 28)?;
            let s = local + 30 + lnlen + lxlen;
            let body = d.get(s..s + csize)?;
            let data = match method {
                0 => body.to_vec(),
                8 => miniz_oxide::inflate::decompress_to_vec(body).ok()?,
                _ => return Some(()),
            };
            out.push((name, data));
            Some(())
        })();
        if ok.is_none() {
            break;
        }
    }
    out
}

/// Load the MyMeets character pack (the zip as downloaded). Returns the number
/// of usable characters (0 = nothing usable).
#[no_mangle]
pub extern "C" fn tg_mm_load_zip(p: *const u8, n: usize) -> i32 {
    let d = match unsafe { bytes(p, n) } {
        Some(d) => d,
        None => return 0,
    };
    catch_unwind(|| {
        let mut lib = mm::Library::default();
        for (name, data) in zip_entries(d) {
            let low = name.to_ascii_lowercase().replace('\\', "/");
            if low.contains("assets/characters/") {
                lib.add_file(&name, data);
            } else if low.contains("assets/items/") && low.ends_with(".txt") {
                lib.add_item(&name, data);
            }
        }
        lib.finish();
        let c = lib.ids.len() as i32;
        if c > 0 {
            *TOWN.lock().unwrap() = Some(lib);
        }
        c
    })
    .unwrap_or(0)
}

/// Character ids (up to max) into out; returns how many.
#[no_mangle]
pub extern "C" fn tg_mm_ids(out: *mut u16, max: usize) -> usize {
    let g = TOWN.lock().unwrap();
    let ids = match g.as_ref() {
        Some(l) => &l.ids,
        None => return 0,
    };
    let n = ids.len().min(max);
    if !out.is_null() {
        unsafe { std::ptr::copy_nonoverlapping(ids.as_ptr(), out, n) };
    }
    n
}

/// Draw a character from parts (ids + palettes for B M A K) into out
/// (64*64 0xAARRGGBB). Returns 1 on success.
#[no_mangle]
pub extern "C" fn tg_mm_compose(b: u16, bp: i32, m: u16, a: u16, ap: i32, k: u16, kp: i32, out: *mut u32) -> i32 {
    if out.is_null() {
        return 0;
    }
    let g = TOWN.lock().unwrap();
    let lib = match g.as_ref() {
        Some(l) => l,
        None => return 0,
    };
    let picks = [(b, bp.max(0) as usize), (m, 0), (a, ap.max(0) as usize), (k, kp.max(0) as usize)];
    match catch_unwind(AssertUnwindSafe(|| lib.compose(&picks, false))) {
        Ok(Some(img)) => {
            let o = unsafe { std::slice::from_raw_parts_mut(out, 64 * 64) };
            o.copy_from_slice(&img.px[..64 * 64]);
            1
        }
        _ => 0,
    }
}

/// One part on its own (0 Body, 1 Face, 2 Head, 3 Back), centred in 64*64 0xAARRGGBB. Returns 1 on success.
#[no_mangle]
pub extern "C" fn tg_mm_layer(part: i32, id: u16, pal: i32, out: *mut u32) -> i32 {
    if out.is_null() || !(0..4).contains(&part) {
        return 0;
    }
    let g = TOWN.lock().unwrap();
    let Some(lib) = g.as_ref() else { return 0 };
    match catch_unwind(AssertUnwindSafe(|| lib.layer(part as usize, id, pal.max(0) as usize))) {
        Ok(Some(img)) => {
            let o = unsafe { std::slice::from_raw_parts_mut(out, 64 * 64) };
            o.copy_from_slice(&img.px[..64 * 64]);
            1
        }
        _ => 0,
    }
}

/// A character's body: out[0] = opaque pixels, out[1] = anchors it has (1 head, 2 face, 4 back). Returns 1 on success.
#[no_mangle]
pub extern "C" fn tg_mm_body_info(id: u16, out: *mut i32) -> i32 {
    if out.is_null() {
        return 0;
    }
    let g = TOWN.lock().unwrap();
    let Some(lib) = g.as_ref() else { return 0 };
    match catch_unwind(AssertUnwindSafe(|| lib.body_info(id))) {
        Ok(Some((n, m))) => {
            unsafe { *out = n as i32; *out.add(1) = m as i32 };
            1
        }
        _ => 0,
    }
}

/// How many wallpapers the pack has.
#[no_mangle]
pub extern "C" fn tg_mm_wallpaper_count() -> i32 {
    let g = TOWN.lock().unwrap();
    g.as_ref().map_or(0, |l| l.wallpaper_count() as i32)
}

/// The nth wallpaper: size in wh[0], wh[1], pixels (0xAARRGGBB, up to 128*128) in out. Returns 1 on success.
#[no_mangle]
pub extern "C" fn tg_mm_wallpaper(n: i32, wh: *mut i32, out: *mut u32) -> i32 {
    if wh.is_null() || out.is_null() || n < 0 {
        return 0;
    }
    let g = TOWN.lock().unwrap();
    let Some(lib) = g.as_ref() else { return 0 };
    match catch_unwind(AssertUnwindSafe(|| lib.wallpaper(n as usize))) {
        Ok(Some(img)) if img.w * img.h <= 128 * 128 => {
            unsafe {
                *wh = img.w as i32;
                *wh.add(1) = img.h as i32;
                std::ptr::copy_nonoverlapping(img.px.as_ptr(), out, img.w * img.h);
            }
            1
        }
        _ => 0,
    }
}

/// The 8 colours of a palette (for colour buttons).
#[no_mangle]
pub extern "C" fn tg_mm_palette(pal: i32, out: *mut u32) -> i32 {
    if out.is_null() {
        return 0;
    }
    let s = mm::palette_swatch(pal.max(0) as usize);
    unsafe { std::ptr::copy_nonoverlapping(s.as_ptr(), out, 8) };
    mm::PALETTE_COUNT as i32
}

/// A plain app packet (op 0x14 visit / 0x15 back / 0x16 marriage, cmd 0 = hello).
#[no_mangle]
pub extern "C" fn tg_mm_packet(op: u8, cmd: u8, out: *mut *mut u8, out_len: *mut usize) {
    give(mm::packet(op, cmd, 258, 0, None, None), out, out_len)
}

/// What the toy sent on a visit: bit0 adult, bit1 sex; name via tg_mm_visit_name.
#[no_mangle]
pub extern "C" fn tg_mm_visit_info(p: *const u8, n: usize) -> i32 {
    match unsafe { bytes(p, n) } {
        Some(v) => (mm::visit_is_adult(v) as i32) | ((mm::visit_sex(v) as i32 & 1) << 1),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn tg_mm_visit_name(p: *const u8, n: usize, out: *mut *mut u8, out_len: *mut usize) {
    let s = unsafe { bytes(p, n) }.map(mm::visit_name).unwrap_or_default();
    give_string(s, out, out_len)
}

/// The marriage packet. kind: 0 like the app, 1 the baby becomes the partner,
/// 2 random genes. baby_sex 0/1. lang 4 JP / 8 EN. Returns 1 on success.
#[no_mangle]
pub extern "C" fn tg_mm_marriage(
    visit: *const u8, visit_len: usize,
    b: u16, bp: i32, m: u16, a: u16, ap: i32, k: u16, kp: i32,
    baby_sex: u8, lang: u8, kind: u8, name: *const c_char, seed: u64,
    out: *mut *mut u8, out_len: *mut usize,
) -> i32 {
    let v = unsafe { bytes(visit, visit_len) }.map(|x| x.to_vec()).unwrap_or_default();
    let name = unsafe { cstr(name) }.unwrap_or_default();
    let g = TOWN.lock().unwrap();
    let lib = match g.as_ref() {
        Some(l) => l,
        None => return 0,
    };
    let c = mm::Choice {
        picks: [(b, bp.max(0) as usize), (m, 0), (a, ap.max(0) as usize), (k, kp.max(0) as usize)],
        baby_sex,
        lang,
        kind,
        name,
    };
    match catch_unwind(AssertUnwindSafe(|| mm::marriage_packet(lib, &v, &c, seed))) {
        Ok(Some(p)) => {
            give(p, out, out_len);
            1
        }
        _ => 0,
    }
}


/// Shop items from the loaded pack as JSON: [{"i":0,"lang":"en","file":..,"id":..,"name":..,"kind":"food"}]
#[no_mangle]
pub extern "C" fn tg_mm_items(out: *mut *mut u8, out_len: *mut usize) {
    let g = TOWN.lock().unwrap();
    let v: Vec<serde_json::Value> = g
        .as_ref()
        .map(|l| {
            l.items
                .iter()
                .enumerate()
                .map(|(i, it)| serde_json::json!({"i": i, "lang": it.lang, "file": it.file, "id": it.id, "name": it.name, "kind": it.kind}))
                .collect()
        })
        .unwrap_or_default();
    give_string(serde_json::Value::Array(v).to_string(), out, out_len)
}

/// Delivery packet for pack item i, with Gotchi Points. Returns 1 on success.
#[no_mangle]
pub extern "C" fn tg_mm_item_packet(i: usize, points: u32, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    let g = TOWN.lock().unwrap();
    match g.as_ref().and_then(|l| l.items.get(i)) {
        Some(it) => {
            give(mm::item_packet(&it.data, points), out, out_len);
            1
        }
        None => 0,
    }
}

/// Delivery packet for an item file the user brought. Returns 1 on success.
#[no_mangle]
pub extern "C" fn tg_mm_user_item(p: *const u8, n: usize, points: u32, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    match unsafe { bytes(p, n) }.and_then(|d| mm::wrap_user_item(d, points)) {
        Some(v) => {
            give(v, out, out_len);
            1
        }
        None => 0,
    }
}

/// Name of an item file the user brought ("" if it isn't one).
#[no_mangle]
pub extern "C" fn tg_mm_user_item_name(p: *const u8, n: usize, out: *mut *mut u8, out_len: *mut usize) {
    let name = unsafe { bytes(p, n) }
        .and_then(|d| {
            if d.len() > 0x110 && d[0x4c] == 0x17 {
                let l = u32::from_le_bytes([d[0x108], d[0x109], d[0x10a], d[0x10b]]) as usize;
                d.get(0x10c..0x10c + l).and_then(mm::item_info)
            } else {
                mm::item_info(d)
            }
        })
        .map(|(id, name)| if name.is_empty() { id } else { name })
        .unwrap_or_default();
    give_string(name, out, out_len)
}

/// Gotchi Points only (no item), like the app's point gifts.
#[no_mangle]
pub extern "C" fn tg_mm_points_packet(points: u32, out: *mut *mut u8, out_len: *mut usize) {
    give(mm::packet(0x17, 0x3A, 258, points, None, None), out, out_len)
}

/// Come-home packet carrying an optional item (raw item file or delivery packet) and points.
#[no_mangle]
pub extern "C" fn tg_mm_back_packet(p: *const u8, n: usize, points: u32, out: *mut *mut u8, out_len: *mut usize) {
    give(mm::back_packet(unsafe { bytes(p, n) }, points), out, out_len)
}

/// The Tamagotchi's own name from visit data.
#[no_mangle]
pub extern "C" fn tg_mm_tama_name(p: *const u8, n: usize, out: *mut *mut u8, out_len: *mut usize) {
    let s = unsafe { bytes(p, n) }.map(mm::visit_tama_name).unwrap_or_default();
    give_string(s, out, out_len)
}
// English TG18 Param layout; guarded by the exact known firmware fingerprints.
fn profile_base(e: &Emu) -> Option<u32> {
    match tg18::code_hash(&e.image) {
        0xD780_5452_8833_EB90 | 0x8313_24F3_B2FA_6768 | 0xA38D_22B6_76C5_3108 => Some(0xF800_D864),
        _ => None,
    }
}
fn profile_points(e: &mut Emu) -> Option<u16> {
    let base = profile_base(e)?;
    if !(1..=4).contains(&e.m.sys.read8(base + 0x52)) { return None; }
    Some(u16::from_le_bytes([e.m.sys.read8(base + 0x20), e.m.sys.read8(base + 0x21)]))
}
#[no_mangle]
pub extern "C" fn tg_profile_points(e: *mut Emu) -> i32 {
    if e.is_null() { return -1; }
    let em = unsafe { &mut *e };
    catch_unwind(AssertUnwindSafe(|| profile_points(em).map(i32::from).unwrap_or(-1))).unwrap_or(-1)
}
#[no_mangle]
pub extern "C" fn tg_profile_adjust_points(e: *mut Emu, delta: i32) -> i32 {
    if e.is_null() { return -1; }
    let em = unsafe { &mut *e };
    catch_unwind(AssertUnwindSafe(|| {
        let Some(base) = profile_base(em) else { return -1; };
        let Some(current) = profile_points(em) else { return -1; };
        let next = i64::from(current) + i64::from(delta);
        if !(0..=65535).contains(&next) { return -1; }
        em.m.sys.poke(base + 0x20, &(next as u16).to_le_bytes());
        next as i32
    })).unwrap_or(-1)
}
#[no_mangle]
pub extern "C" fn tg_profile_attention(e: *mut Emu) -> i32 {
    if e.is_null() { return -1; }
    let em = unsafe { &mut *e };
    catch_unwind(AssertUnwindSafe(|| {
        let Some(base) = profile_base(em) else { return -1; };
        if !(1..=4).contains(&em.m.sys.read8(base + 0x52)) { return 0; }
        (em.m.sys.read8(base + 0x0C) & 0x0F) as i32
    })).unwrap_or(-1)
}

#[cfg(test)]
mod profile_bridge_tests {
    use super::*;
    #[test]
    fn no_device_is_not_a_zero_balance_or_care_call() {
        assert_eq!(tg_profile_points(std::ptr::null_mut()), -1);
        assert_eq!(tg_profile_adjust_points(std::ptr::null_mut(), 100), -1);
        assert_eq!(tg_profile_attention(std::ptr::null_mut()), -1);
    }
}


// Disposable name-probe machines. Never attached to phone transport, display, audio, or save paths.
pub struct NameProbeSeed { snapshot: Snapshot, image: Arc<Vec<u8>>, owner: String, identity: String }
pub struct NameProbe { m: Machine, identity: String }
fn name_identity(m: &Machine, base: u32) -> String {
    let o = base.wrapping_sub(0xF800_0000) as usize;
    let stage = m.sys.sram[o + 0x52];
    let character = u32::from_le_bytes(m.sys.sram[o+0x60..o+0x64].try_into().unwrap());
    let signature: String = m.sys.sram[o+0x4C..o+0x50].iter().map(|v| format!("{:02X}", v)).collect();
    format!("{}.{}.{}", signature, stage, character)
}
#[no_mangle]
pub extern "C" fn tg_name_seed_capture(e: *mut Emu) -> *mut NameProbeSeed {
    if e.is_null() { return std::ptr::null_mut(); }
    catch_unwind(AssertUnwindSafe(|| {
        let e = unsafe { &mut *e };
        let Some(base) = profile_base(e) else { return std::ptr::null_mut(); };
        if e.stopped.is_some() { return std::ptr::null_mut(); }
        let o = base.wrapping_sub(0xF800_0000) as usize;
        let owner: String = mm::decode_name(&e.m.sys.sram[o+0x7A..o+0x8A]).chars().filter(|c| c.is_alphanumeric() || c.is_whitespace()).collect();
        let seed = NameProbeSeed { snapshot: Snapshot::capture(&e.m), image: e.image.clone(), owner,
            identity: name_identity(&e.m, base) };
        Box::into_raw(Box::new(seed))
    })).unwrap_or(std::ptr::null_mut())
}
#[no_mangle]
pub extern "C" fn tg_name_seed_destroy(p: *mut NameProbeSeed) {
    if !p.is_null() { unsafe { drop(Box::from_raw(p)); } }
}
#[no_mangle]
pub extern "C" fn tg_name_seed_text(p: *const NameProbeSeed, kind: i32, out: *mut *mut u8, n: *mut usize) {
    if p.is_null() { give_string(String::new(), out, n); return; }
    let seed = unsafe { &*p };
    give_string(if kind == 0 { seed.owner.clone() } else { seed.identity.clone() }, out, n)
}
#[no_mangle]
pub extern "C" fn tg_name_probe_from_seed(p: *const NameProbeSeed) -> *mut NameProbe {
    if p.is_null() { return std::ptr::null_mut(); }
    catch_unwind(AssertUnwindSafe(|| {
        let seed = unsafe { &*p };
        let mut m = Machine::new(seed.image.clone(), &seed.image, 0.0);
        // Snapshot includes the live RAM/flash image; restore copies it into independently owned buffers.
        if seed.snapshot.restore(&mut m).is_err() { return std::ptr::null_mut(); }
        m.sys.live_keys = [false; 3]; m.sys.hold_until = [0.0; 3]; m.sys.key_script.clear();
        m.sys.radio = None; m.stop_on_bluetooth = true; m.bluetooth_used = false;
        m.never_sleep = true; m.idle_skip = true; m.sys.turbo = 1.0; m.print_log = false;
        m.log.clear(); m.sys.sound.events.clear();
        Box::into_raw(Box::new(NameProbe { m, identity: seed.identity.clone() }))
    })).unwrap_or(std::ptr::null_mut())
}
#[no_mangle]
pub extern "C" fn tg_name_probe_destroy(p: *mut NameProbe) {
    if !p.is_null() { unsafe { drop(Box::from_raw(p)); } }
}
#[no_mangle]
pub extern "C" fn tg_name_probe_step(p: *mut NameProbe, seconds: f64) -> i32 {
    if p.is_null() || !seconds.is_finite() { return 0; }
    catch_unwind(AssertUnwindSafe(|| {
        let probe = unsafe { &mut *p };
        let m = &mut probe.m;
        let end = m.executed.saturating_add((seconds.clamp(0.001, 0.05) * CPU_HZ) as u64);
        if m.sys.powered_off { let now = m.now(); m.press(now, Key::B); m.power_cycle(end); }
        let result = m.run_with_sleep(end);
        m.log.clear(); m.sys.sound.events.clear();
        matches!(result, Outcome::Limit | Outcome::PowerOff) as i32
    })).unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn tg_name_probe_press(p: *mut NameProbe, key: i32) {
    if p.is_null() { return; }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(k) = key_of(key) { let probe = unsafe { &mut *p };
        let m = &mut probe.m; let now = m.now(); m.press(now, k); }
    }));
}
#[no_mangle]
pub extern "C" fn tg_name_probe_rgb(p: *mut NameProbe, out: *mut u8, n: usize) -> i32 {
    if p.is_null() || out.is_null() || n < 128 * 128 * 3 { return 0; }
    catch_unwind(AssertUnwindSafe(|| {
        let probe = unsafe { &*p };
        if name_identity(&probe.m, 0xF800_D864) != probe.identity { return 0; }
        let pixels = probe.m.lcd_rgb();
        if pixels.len() != 128 * 128 * 3 { return 0; }
        unsafe { std::ptr::copy_nonoverlapping(pixels.as_ptr(), out, pixels.len()); }
        1
    })).unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn tg_name_identity_matches(e: *mut Emu, stage: i32, character: u32, signature: u32) -> i32 {
    if e.is_null() { return 0; }
    catch_unwind(AssertUnwindSafe(|| {
        let e = unsafe { &mut *e };
        let Some(base) = profile_base(e) else { return 0; };
        let o = base.wrapping_sub(0xF800_0000) as usize;
        let current_character = u32::from_le_bytes(e.m.sys.sram[o+0x60..o+0x64].try_into().unwrap());
        let current_signature = u32::from_be_bytes(e.m.sys.sram[o+0x4C..o+0x50].try_into().unwrap());
        (i32::from(e.m.sys.sram[o+0x52]) == stage && current_character == character && current_signature == signature) as i32
    })).unwrap_or(0)
}
#[cfg(test)]
mod name_probe_isolation_tests {
    use super::*;
    #[test]
    fn disposable_copy_does_not_share_mutable_game_memory_or_keys() {
        let mut image = vec![0u8; FLASH_SIZE]; image[..4].copy_from_slice(b"SPII");
        let image = Arc::new(image);
        let live = Machine::new(image.clone(), &image, 0.0);
        let seed = NameProbeSeed { snapshot: Snapshot::capture(&live), image, owner: "JAKE".into(), identity: "test".into() };
        let p = tg_name_probe_from_seed(&seed);
        assert!(!p.is_null());
        let probe = unsafe { &mut *p };
        let old_sram = live.sys.sram[0]; let old_ram = live.sys.ram[0]; let old_keys = live.sys.key_script.len();
        probe.m.sys.sram[0] = old_sram ^ 0xFF; probe.m.sys.ram[0] = old_ram ^ 0xFF;
        let now = probe.m.now(); probe.m.press(now, Key::A);
        assert_eq!(live.sys.sram[0], old_sram); assert_eq!(live.sys.ram[0], old_ram); assert_eq!(live.sys.key_script.len(), old_keys);
        tg_name_probe_destroy(p);
    }
}


#[cfg(test)]
mod bundled_mymeets_asset_tests {
    use super::*;
    #[test]
    fn checked_out_pack_loads_with_the_actual_app_parser() {
        let path = std::env::var("TAMAIOS_BUNDLED_ASSETS").expect("TAMAIOS_BUNDLED_ASSETS must point to the checked-out ZIP");
        let data = std::fs::read(path).expect("bundled ZIP");
        let count = tg_mm_load_zip(data.as_ptr(), data.len());
        assert!(count > 0, "ZIP contains no usable characters for this app parser");
        let mut ids = [0u16; 512];
        let read = tg_mm_ids(ids.as_mut_ptr(), ids.len());
        assert!(read > 0 && read <= ids.len());
        println!("Bundled MyMeets parser verified: {} characters, {} IDs", count, read);
    }
}
/// A brand-new item from a drawing: kind "wallpaper" or "food", pixels 0xAARRGGBB.
/// Returns the delivery packet (with Gotchi Points), or 0 if the pack isn't loaded.
#[no_mangle]
pub extern "C" fn tg_mm_custom_item(kind: *const c_char, name: *const c_char, price: u16,
                                    px: *const u32, w: usize, h: usize, seed: u64, points: u32,
                                    out: *mut *mut u8, out_len: *mut usize) -> i32 {
    if px.is_null() || w == 0 || h == 0 {
        return 0;
    }
    let kind = unsafe { cstr(kind) }.unwrap_or_default();
    let name = unsafe { cstr(name) }.unwrap_or_default();
    let pixels = unsafe { std::slice::from_raw_parts(px, w * h) };
    let g = TOWN.lock().unwrap();
    let Some(lib) = g.as_ref() else { return 0 };
    match mm::custom_item(lib, &kind, &name, price, pixels, w, h, seed) {
        Some(item) => {
            give(mm::item_packet(&item, points), out, out_len);
            1
        }
        None => 0,
    }
}

// --- infrared link between two toys ---------------------------------------------

/// Turn the link on: this toy's infrared goes to the other toy instead of the built-in partner.
#[no_mangle]
pub extern "C" fn tg_ir_link(e: *mut Emu, on: i32) {
    with(e, |em| {
        em.ir.bridge = on != 0;
        if on == 0 {
            em.ir.outbox.clear();
        }
    })
}

/// Take the next frame this toy sent (copied into `out`, up to `max`). Returns its length, or 0.
#[no_mangle]
pub extern "C" fn tg_ir_take(e: *mut Emu, out: *mut u8, max: usize) -> usize {
    with(e, |em| match em.ir.outbox.pop_front() {
        Some(f) if f.len() <= max && !out.is_null() => {
            unsafe { std::ptr::copy_nonoverlapping(f.as_ptr(), out, f.len()) };
            f.len()
        }
        _ => 0,
    })
}

/// Hand this toy a frame from the other toy; it arrives 2 ms of toy time from now.
#[no_mangle]
pub extern "C" fn tg_ir_deliver(e: *mut Emu, data: *const u8, n: usize) {
    with(e, |em| {
        if let Some(d) = unsafe { bytes(data, n) } {
            let due = em.m.now() + 0.002;
            em.ir.deliver(d, due);
        }
    })
}

fn pal16<B: Bus>(s: &mut B, a: u32) -> Vec<u16> {
    let n = u32::from(s.read8(a + 2));
    (0..n).map(|i| u16::from(s.read8(a + 6 + 2 * i)) << 8 | u16::from(s.read8(a + 7 + 2 * i))).collect()
}

/// The profile picture of the current built-in Tama, decoded straight from firmware data.
/// rom: 0 Wonder Garden, 1 Magic, 2 Fairy. `out` holds 64*64 ARGB pixels. Returns (w<<8)|h, or 0 when not a built-in Tama.
#[no_mangle]
pub extern "C" fn tg_profile_sprite(e: *mut Emu, rom: i32, out: *mut u32) -> i32 {
    if e.is_null() || out.is_null() { return 0; }
    // (character table, colour strips table, grey reference palette image)
    const T: [(u32, u32, u32); 3] = [
        (0x201a_e1cc, 0x201d_44cc, 0x2038_5e78),
        (0x201a_aadc, 0x201c_f33c, 0x2037_ac68),
        (0x201a_909c, 0x201c_d8f8, 0x2037_a744),
    ];
    let Some(&(chars, strips, refimg)) = T.get(rom as usize) else { return 0 };
    with(e, |e| {
        let s = &mut e.m.sys;
        if s.read8(0xF800_D89E) != 1 || s.read8(0xF800_D8B6) < 1 { return 0; }
        let key = u32::from(s.read8(0xF800_D864)) | u32::from(s.read8(0xF800_D865)) << 8;
        if key >= 200 { return 0; }
        let cidx = u32::from(s.read8(0xF800_BF68));
        if cidx > 11 { return 0; }
        let img = s.read32(chars + key * 14 * 4);
        if !(0x2020_0000..0x2080_0000).contains(&img) { return 0; }
        let reference = pal16(s, refimg);
        let strip_addr = s.read32(strips + (6 + cidx) * 4);
        let strip = pal16(s, strip_addr);
        let (w, h) = (u32::from(s.read8(img)), u32::from(s.read8(img + 1)));
        if w == 0 || h == 0 || w > 64 || h > 64 { return 0; }
        let mut colors = pal16(s, img);
        for c in colors.iter_mut() {
            if let Some(p) = reference.iter().skip(1).take(8).position(|r| r == c) {
                if let Some(&n) = strip.get(p + 1) { *c = n; }
            }
        }
        let data = img + 6 + 2 * colors.len() as u32;
        let o = unsafe { std::slice::from_raw_parts_mut(out, 64 * 64) };
        for p in o.iter_mut() { *p = 0; }
        for y in 0..h {
            for x in 0..w {
                let b = s.read8(data + (y * w + x) / 2);
                let i = ((b >> (4 * (x & 1))) & 15) as usize;
                if i == 0 { continue; }
                let Some(&v) = colors.get(i) else { continue };
                // pure red marks a single spot the toy paints over itself: it is not part of the Tama, so take the colour beside it
                if v == 0x001f && x > 0 {
                    o[(y * 64 + x) as usize] = o[(y * 64 + x - 1) as usize];
                    continue;
                }
                let (b5, g6, r5) = (u32::from(v >> 11) & 31, u32::from(v >> 5) & 63, u32::from(v) & 31);
                o[(y * 64 + x) as usize] = 0xFF00_0000 | (r5 * 255 / 31) << 16 | (g6 * 255 / 63) << 8 | (b5 * 255 / 31);
            }
        }
        // a lone pixel with nothing around it is a leftover in the art, not part of the picture
        let snapshot: Vec<u32> = o.to_vec();
        for y in 0..h as i32 {
            for x in 0..w as i32 {
                if snapshot[(y * 64 + x) as usize] == 0 { continue; }
                let mut near = false;
                for dy in -1..=1 { for dx in -1..=1 {
                    if dx == 0 && dy == 0 { continue; }
                    let (nx, ny) = (x + dx, y + dy);
                    if nx >= 0 && ny >= 0 && nx < w as i32 && ny < h as i32 && snapshot[(ny * 64 + nx) as usize] != 0 { near = true; }
                } }
                if !near { o[(y * 64 + x) as usize] = 0; }
            }
        }
        (w << 8 | h) as i32
    })
}

/// Look of a Tama born after a marriage (parts + colours the toy stores): out = body, face, head, back, bodyColor, headColor, backColor.
/// Returns 1 for such a Tama, else 0.
#[no_mangle]
pub extern "C" fn tg_profile_look(e: *mut Emu, out: *mut i32) -> i32 {
    if e.is_null() || out.is_null() { return 0; }
    with(e, |e| {
        let s = &mut e.m.sys;
        if s.read8(0xF800_D89E) < 2 || s.read8(0xF800_D8B6) < 1 { return 0; }
        let o = unsafe { std::slice::from_raw_parts_mut(out, 7) };
        for i in 0..4u32 {
            o[i as usize] = i32::from(s.read8(0xF800_DAC6 + 2 * i)) | i32::from(s.read8(0xF800_DAC7 + 2 * i)) << 8;
        }
        for i in 0..3u32 { o[4 + i as usize] = i32::from(s.read8(0xF800_DAC2 + i)); }
        if o[0] == 0 && o[1] == 0 && o[2] == 0 && o[3] == 0 { return 0; }
        1
    })
}
