use std::{path::PathBuf, ptr};
use tamaios::*;

struct Handle(*mut Emu);
impl Drop for Handle {
    fn drop(&mut self) { tg_destroy(self.0); }
}
fn create(rom: &[u8], snapshot: Option<&[u8]>) -> Handle {
    let (snap, len) = snapshot.map(|s| (s.as_ptr(), s.len())).unwrap_or((ptr::null(), 0));
    let mut elapsed = 0.0;
    let h = tg_create(rom.as_ptr(), rom.len(), snap, len, ptr::null(), 0, ptr::null(), tg_rtc_seconds(2026, 11, 9, 12, 0, 0), &mut elapsed);
    assert!(!h.is_null(), "FFI create failed");
    tg_set_volume(h, 0.0);
    Handle(h)
}
fn peek(h: &Handle, address: u32) -> [u8; 4] {
    let mut out = [0; 4];
    assert_eq!(tg_peek(h.0, address, out.as_mut_ptr(), out.len()), 1);
    out
}
fn status(h: &Handle) -> String {
    let mut out = ptr::null_mut();
    let mut len = 0;
    tg_status(h.0, &mut out, &mut len);
    assert!(!out.is_null());
    let text = unsafe { String::from_utf8_lossy(std::slice::from_raw_parts(out, len)).into_owned() };
    tg_free(out, len);
    text
}
fn snapshot(h: &Handle) -> Vec<u8> {
    let mut out = ptr::null_mut();
    let mut len = 0;
    assert_eq!(tg_snapshot(h.0, &mut out, &mut len), 1);
    assert!(!out.is_null() && len > 8);
    let bytes = unsafe { std::slice::from_raw_parts(out, len).to_vec() };
    tg_free(out, len);
    bytes
}
fn exercise(suffix: &str) {
    let folder = std::env::var("TAMAIOS_AUDIT_FIRMWARE").expect("firmware folder required");
    let matches: Vec<PathBuf> = std::fs::read_dir(folder).unwrap().map(|e| e.unwrap().path()).filter(|p| p.file_name().unwrap().to_string_lossy().ends_with(suffix)).collect();
    assert_eq!(matches.len(), 1, "expected one matching firmware");
    let rom = std::fs::read(&matches[0]).unwrap();
    let a = create(&rom, None);
    let b = create(&rom, None);
    for _ in 0..100 {
        assert_eq!(tg_tick(a.0, 0.02), TG_OK, "first handle tick");
        assert_eq!(tg_tick(b.0, 0.02), TG_OK, "second handle tick");
    }
    let before = status(&b);
    for _ in 0..25 { assert_eq!(tg_tick(a.0, 0.02), TG_OK); }
    assert_eq!(status(&b), before, "inactive handle changed while peer ran");
    let address = 0xF80F_F000;
    let peer_bytes = peek(&b, address);
    let marker = [0xA5, 0x5A, 0xC3, 0x3C];
    assert_eq!(tg_poke(a.0, address, marker.as_ptr(), marker.len()), 1);
    assert_eq!(peek(&a, address), marker);
    assert_eq!(peek(&b, address), peer_bytes, "FFI SRAM cross-contamination");
    let saved = snapshot(&a);
    assert_eq!(tg_check_snapshot(rom.as_ptr(), rom.len(), saved.as_ptr(), saved.len()), 1);
    let restored = create(&rom, Some(&saved));
    assert_eq!(peek(&restored, address), marker, "FFI snapshot marker lost");
    assert!(status(&restored).contains("Resumed from autosave"), "snapshot restore path was not used");
    assert_eq!(peek(&b, address), peer_bytes);
    for _ in 0..25 { assert_eq!(tg_tick(restored.0, 0.02), TG_OK, "restored handle tick"); }
    println!("FFI PASS: {suffix}; dual-handle startup, inactive status, SRAM isolation, snapshot validation and third-handle restore. No radio/IR gameplay claimed.");
}
#[test]
fn fairy_real_ffi_isolation_and_restore() { exercise("_fairy.bin"); }
#[test]
fn magic_real_ffi_isolation_and_restore() { exercise("_magic.bin"); }
#[test]
fn wondergarden_real_ffi_isolation_and_restore() { exercise("_wondergarden.bin"); }
