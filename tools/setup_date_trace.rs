fn main() {
    let folder = std::env::var("TAMAIOS_AUDIT_FIRMWARE").expect("firmware directory required");
    let mut files: Vec<PathBuf> = std::fs::read_dir(folder).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|s| s == "bin")).collect();
    files.sort();
    assert_eq!(files.len(), 3);
    let keys: Vec<i32> = [vec![2; 4], vec![1; 8]].concat();
    let mut runs = Vec::new();
    for path in files {
        let rom = std::fs::read(&path).unwrap();
        let tag = format!("{}-setup-date-trace", path.file_name().unwrap().to_string_lossy());
        let mut elapsed = 0.0;
        let h = Device(tg_create(rom.as_ptr(), rom.len(), ptr::null(), 0, ptr::null(), 0, ptr::null(), tg_rtc_seconds(2026, 11, 9, 12, 0, 0), &mut elapsed));
        assert!(!h.0.is_null());
        tg_set_volume(h.0, 0.0);
        assert_eq!(tg_set_param(h.0, c"rewind_gap".as_ptr(), 1.0e12), 1);
        let mut stopped_code = advance(&h, 100).err();
        let mut initial = sample(&h, &tag, 0);
        initial["phase"] = json!("setup_date_trace");
        let mut observations = vec![initial];
        if stopped_code.is_none() {
            for (index, key) in keys.iter().enumerate() {
                tg_press(h.0, *key, index as f64 + 10.0);
                let pressed = advance(&h, 8);
                tg_release(h.0, *key);
                let result = pressed.and_then(|_| advance(&h, 22));
                let mut observation = sample(&h, &tag, index + 1);
                observation["phase"] = json!("setup_date_trace");
                observation["input_key"] = json!(key);
                observations.push(observation);
                if let Err(code) = result { stopped_code = Some(code); break; }
            }
        }
        tg_release_all(h.0);
        runs.push(json!({"firmware": path.file_name().unwrap().to_string_lossy(), "plan": "setup_date_trace", "planned_keys": keys, "stopped_code": stopped_code, "observations": observations}));
    }
    let report = json!({"scope": "Every-step trace of the unchanged four-C/eight-B setup prefix. No long wait, wake, date mutation, RAM edit or setup-success claim.", "runs": runs});
    std::fs::write(std::env::var("TAMAIOS_SURVEY_OUTPUT").expect("output path"), serde_json::to_vec_pretty(&report).unwrap()).unwrap();
}
