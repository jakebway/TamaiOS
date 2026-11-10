use std::{path::PathBuf, ptr};
use serde_json::{json, Value};
use tamaios::*;

struct Device(*mut Emu);
impl Drop for Device { fn drop(&mut self) { tg_destroy(self.0); } }
fn sample(h: &Device, tag: &str, action: usize) -> Value {
    fn read(h: &Device, address: u32, length: usize) -> Option<Vec<u8>> {
        let mut out = vec![0; length];
        (tg_peek(h.0, address, out.as_mut_ptr(), length) == 1).then_some(out)
    }
    let mut chain = [0u32; 16];
    let count = tg_call_chain(h.0, chain.as_mut_ptr(), chain.len()).clamp(0, 16) as usize;
    let mut frame = vec![0u32; 128 * 128];
    let dark = tg_frame(h.0, frame.as_mut_ptr());
    let hash = frame.iter().fold(2166136261u32, |v, pixel| (v ^ pixel).wrapping_mul(16777619));
    let directory = PathBuf::from(std::env::var("TAMAIOS_SURVEY_FRAMES").expect("temporary frame directory"));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join(format!("{tag}-{action}.png"));
    let rgb: Vec<u8> = frame.iter().flat_map(|p| [((p >> 16) & 255) as u8, ((p >> 8) & 255) as u8, (p & 255) as u8]).collect();
    tg18::png::write(&path.to_string_lossy(), 128, 128, &rgb, 6).expect("temporary frame");
    json!({"action": action, "stage_raw": read(h, 0xF800D8B6, 1), "view_raw": read(h, 0xF800D804, 1), "mode_raw": read(h, 0xF80178E4, 1), "radio_setup_done": tg_radio_ready(h.0), "asleep": tg_is_asleep(h.0), "dark_return": dark, "call_chain": chain[..count].iter().map(|p| format!("{p:08X}")).collect::<Vec<_>>(), "frame_fnv32": format!("{hash:08X}"), "frame_file": path})
}
fn advance(h: &Device, ticks: usize) -> Result<(), i32> {
    let mut audio = vec![0i16; 44100];
    for _ in 0..ticks {
        let code = tg_tick(h.0, 0.02);
        tg_take_audio(h.0, audio.as_mut_ptr(), audio.len());
        if code != TG_OK { return Err(code); }
    }
    Ok(())
}
fn main() {
    let folder = std::env::var("TAMAIOS_AUDIT_FIRMWARE").expect("firmware directory required");
    let mut files: Vec<PathBuf> = std::fs::read_dir(folder).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|s| s == "bin")).collect();
    files.sort();
    assert_eq!(files.len(), 3, "expected the three bundled firmware files");
    let mut runs = Vec::new();
    for path in files {
        let rom = std::fs::read(&path).unwrap();
        let plans: Vec<(&str, Vec<i32>)> = vec![
            ("confirm", vec![1; 30]),
            ("back_then_confirm", [vec![2; 4], vec![1; 30]].concat()),
            ("cycle_then_confirm", (0..20).flat_map(|_| [0, 1]).collect()),
            ("confirm_name_then_wait", [vec![2; 4], vec![1; 31]].concat()),
        ];
        for (plan, keys) in plans {
            let tag = format!("{}-{plan}", path.file_name().unwrap().to_string_lossy());
            let mut elapsed = 0.0;
            let h = Device(tg_create(rom.as_ptr(), rom.len(), ptr::null(), 0, ptr::null(), 0, ptr::null(), tg_rtc_seconds(2026, 11, 9, 12, 0, 0), &mut elapsed));
            assert!(!h.0.is_null(), "fresh FFI creation failed");
            tg_set_volume(h.0, 0.0);
            assert_eq!(tg_set_param(h.0, c"rewind_gap".as_ptr(), 1.0e12), 1);
            let mut observations = Vec::new();
            let mut stopped_code = None;
            let mut reason = "action_budget_reached";
            match advance(&h, 100) {
                Ok(()) => observations.push(sample(&h, &tag, 0)),
                Err(code) => { stopped_code = Some(code); reason = "startup_non_ok"; }
            }
            if stopped_code.is_none() {
                for (index, key) in keys.iter().enumerate() {
                    if tg_radio_ready(h.0) != 0 { reason = "module_setup_observed_not_connection_verified"; break; }
                    tg_press(h.0, *key, index as f64 + 10.0);
                    let pressed = advance(&h, 8);
                    tg_release(h.0, *key);
                    let result = pressed.and_then(|_| advance(&h, 22));
                    observations.push(sample(&h, &tag, index + 1));
                    if let Err(code) = result { stopped_code = Some(code); reason = "non_ok_tick"; break; }
                }
            }
            tg_release_all(h.0);
            let mut completed_input_free_wait_seconds = 0;
            if plan == "confirm_name_then_wait" && stopped_code.is_none() && reason == "action_budget_reached" {
                match advance(&h, 15000) {
                    Ok(()) => {
                        completed_input_free_wait_seconds = 300;
                        reason = "bounded_post_confirmation_wait_complete_not_setup_proof";
                    }
                    Err(code) => { stopped_code = Some(code); reason = "post_confirmation_wait_non_ok"; }
                }
                observations.push(sample(&h, &tag, keys.len() + 1));
            }
            runs.push(json!({"firmware": path.file_name().unwrap().to_string_lossy(), "plan": plan, "planned_keys": keys, "completed_input_free_wait_seconds": completed_input_free_wait_seconds, "stop_reason": reason, "stopped_code": stopped_code, "observations": observations}));
        }
    }
    let report = json!({"scope": "Exploratory fresh-device inputs and temporary OCR frames; final observation of confirm_name_then_wait follows 300 input-free emulated seconds only when its bounded wait completes. No RAM edits, verified screen semantics, connection or gameplay pass claimed", "runs": runs});
    std::fs::write(std::env::var("TAMAIOS_SURVEY_OUTPUT").expect("output path"), serde_json::to_vec_pretty(&report).unwrap()).unwrap();
}
