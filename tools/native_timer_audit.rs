use std::sync::Arc;
use tg18::{Machine, Outcome, CPU_HZ, FLASH_SIZE};
use tg18::cpu::Bus;
use tg18::snapshot::Snapshot;

const TIMER: u32 = 0xC0020080;

fn blank() -> Machine {
    let image = Arc::new(vec![0; FLASH_SIZE]);
    Machine::new(image.clone(), &image, 0.0)
}

fn restore(m: &Machine) -> Machine {
    let bytes = Snapshot::capture(m).to_bytes();
    let snap = Snapshot::from_bytes(&bytes).expect("snapshot decode");
    let mut other = Machine::new(m.image.clone(), &m.image, 0.0);
    snap.restore(&mut other).expect("snapshot restore");
    other
}

fn assert_timer_observables(a: &mut Machine, b: &mut Machine) {
    for index in 0..6 {
        let base = 0xC0020000 + index * 0x20;
        assert_eq!(a.sys.read32(base), b.sys.read32(base), "timer control/pending {index}");
        assert_eq!(a.sys.read32(base + 0x10), b.sys.read32(base + 0x10), "timer counter {index}");
    }
    assert_eq!(a.sys.pending_irq(), b.sys.pending_irq(), "pending interrupt line");
}

#[test]
fn timer_boundaries_and_pending_interrupt_survive_restore() {
    for checkpoint in [0.0005, 0.000999, 0.001, 0.001001, 0.0015] {
        let mut original = blank();
        original.sys.write32(TIMER + 8, 65536 - 12000);
        original.sys.write32(TIMER, 0x6000);
        original.sys.advance(checkpoint);
        let expected_pending = original.sys.timers[4].pending;
        let mut restored = restore(&original);
        assert_eq!(restored.sys.timers[4].pending, expected_pending, "pending preserved");
        assert_timer_observables(&mut original, &mut restored);
        for offset in [0.0001, 0.0009, 0.0011, 0.0021] {
            original.sys.advance(checkpoint + offset);
            restored.sys.advance(checkpoint + offset);
            assert_timer_observables(&mut original, &mut restored);
            original.sys.write32(TIMER, 0xE000);
            restored.sys.write32(TIMER, 0xE000);
            assert!(!original.sys.timers[4].pending);
            assert!(!restored.sys.timers[4].pending);
        }
    }
}

#[test]
fn stopped_timer_restart_discards_old_period_count_on_both_sides() {
    let mut original = blank();
    original.sys.write32(TIMER + 8, 65536 - 12000);
    original.sys.write32(TIMER, 0x6000);
    original.sys.advance(0.0025);
    original.sys.write32(TIMER, 0x8000);
    assert!(original.sys.timers[4].periods_seen > 0);
    let mut restored = restore(&original);
    assert_timer_observables(&mut original, &mut restored);
    original.sys.write32(TIMER, 0x6000);
    restored.sys.write32(TIMER, 0x6000);
    assert_eq!(original.sys.timers[4].periods_seen, 0);
    assert_eq!(restored.sys.timers[4].periods_seen, 0);
    for time in [0.0029, 0.0036, 0.0046] {
        original.sys.advance(time);
        restored.sys.advance(time);
        assert_timer_observables(&mut original, &mut restored);
    }
}

#[test]
fn firmware_original_and_restored_continue_from_same_checkpoint() {
    let folder = std::env::var("TAMAIOS_AUDIT_FIRMWARE").expect("firmware folder required");
    let mut paths: Vec<_> = std::fs::read_dir(folder).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "bin")).collect();
    paths.sort();
    assert!(!paths.is_empty(), "no firmware tested");
    for path in paths {
        let bytes = std::fs::read(&path).unwrap();
        assert!(tg18::is_image(&bytes), "invalid firmware");
        let image = Arc::new(bytes);
        let mut original = Machine::new(image.clone(), &image, tg18::rtc_seconds(2026, 11, 9, 12, 0, 0));
        assert_eq!(original.run_with_sleep((10.0 * CPU_HZ) as u64), Outcome::Limit);
        assert!(original.fault().is_none());
        let mut restored = restore(&original);
        let limit = original.executed + CPU_HZ as u64;
        assert_eq!(original.run_with_sleep(limit), Outcome::Limit);
        assert_eq!(restored.run_with_sleep(limit), Outcome::Limit);
        assert!(original.fault().is_none() && restored.fault().is_none());
        assert_eq!(original.cpu.state(), restored.cpu.state(), "CPU divergence");
        assert!(original.sys.ram == restored.sys.ram, "RAM divergence");
        assert!(original.sys.sram == restored.sys.sram, "SRAM divergence");
        assert_eq!(original.executed, restored.executed);
        assert_eq!(original.irqs, restored.irqs);
        assert_eq!(original.sys.now, restored.sys.now);
        assert_eq!(original.sys.game_time, restored.sys.game_time);
        assert_eq!(original.sys.rtc.ticks(original.sys.game_time), restored.sys.rtc.ticks(restored.sys.game_time));
        assert!(original.lcd_rgb() == restored.lcd_rgb(), "LCD divergence");
        assert_timer_observables(&mut original, &mut restored);
        println!("same-checkpoint continuation passed: {}", path.file_name().unwrap().to_string_lossy());
    }
}
