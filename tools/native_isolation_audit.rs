use std::sync::Arc;
use tg18::{Key, Machine, FLASH_SIZE};
use tg18::radio::Radio;
use tg18::snapshot::Snapshot;
fn blank() -> Machine {
    let image = Arc::new(vec![0; FLASH_SIZE]);
    Machine::new(image.clone(), &image, 0.0)
}
fn receive(r: &mut Radio, n: u8) -> Vec<u8> {
    r.select(true);
    r.xfer(0x60 | n);
    let out = (0..n).map(|_| r.xfer(0)).collect();
    r.select(false);
    out
}
#[test]
fn memory_input_clock_isolation() {
    let mut a = blank();
    let b = blank();
    a.sys.ram[0x800100] = 0xA5;
    a.sys.sram[0x100] = 0x5A;
    a.sys.live_keys[0] = true;
    a.press(2.0, Key::B);
    a.sys.rtc.base_ticks = 123456;
    a.sys.advance(1.0);
    assert_eq!(b.sys.ram[0x800100], 0);
    assert_eq!(b.sys.sram[0x100], 0);
    assert_eq!(b.sys.live_keys, [false; 3]);
    assert!(b.sys.key_script.is_empty());
    assert_eq!(b.sys.now, 0.0);
    assert_eq!(b.sys.game_time, 0.0);
    assert_eq!(b.sys.rtc.ticks(0.0), 0);
}
#[test]
fn radio_queue_isolation() {
    let mut a = Radio::new();
    let mut b = Radio::new();
    assert!(a.from_phone(&[0xA1, 0xA2]));
    assert!(b.from_phone(&[0xB1]));
    assert_eq!(receive(&mut a, 4), vec![0x22, 2, 0xA1, 0xA2]);
    assert_eq!(receive(&mut a, 1), vec![0]);
    assert_eq!(receive(&mut b, 3), vec![0x22, 1, 0xB1]);
    a.connected = true;
    assert!(!b.connected);
    a.to_phone.push_back(vec![0xC1]);
    assert!(b.to_phone.is_empty());
}
#[test]
fn characterization_snapshot_omits_radio_state_not_a_persistence_pass() {
    let mut source = blank();
    let mut r = Radio::new();
    r.connected = true;
    r.setup_done = true;
    assert!(r.from_phone(&[0xD1]));
    r.to_phone.push_back(vec![0xD2]);
    source.sys.radio = Some(r);
    let s = Snapshot::from_bytes(&Snapshot::capture(&source).to_bytes()).unwrap();
    let mut fresh = blank();
    s.restore(&mut fresh).unwrap();
    assert!(fresh.sys.radio.is_none());
    let mut existing = blank();
    let mut stale = Radio::new();
    assert!(stale.from_phone(&[0xE1]));
    existing.sys.radio = Some(stale);
    s.restore(&mut existing).unwrap();
    let target = existing.sys.radio.as_mut().unwrap();
    assert!(!target.connected && !target.setup_done);
    assert!(target.to_phone.is_empty());
    assert_eq!(receive(target, 3), vec![0x22, 1, 0xE1]);
}
