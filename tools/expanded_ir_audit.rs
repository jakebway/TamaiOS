use tg18::sys::{IrCtx, ir_ctx_swap};

fn same(a: &IrCtx, b: &IrCtx) {
    assert_eq!(a.rx, b.rx);
    assert_eq!(a.react_out, b.react_out);
    assert_eq!(a.deframe, b.deframe);
    assert_eq!(a.outbox, b.outbox);
    assert_eq!(a.bridge, b.bridge);
}
fn seeded(marker: u8) -> IrCtx {
    let mut c = IrCtx::default();
    c.rx.push_back(marker);
    c.react_out.push_back((1.25, vec![marker, 0xC0]));
    c.deframe = (true, false, vec![marker, 0x7D]);
    c.outbox.push_back(vec![marker, 0xC1]);
    c.bridge = marker == 1;
    c
}
struct GlobalReset(IrCtx);
impl Drop for GlobalReset {
    fn drop(&mut self) { ir_ctx_swap(&mut self.0); }
}
#[test]
fn repeated_context_swaps_preserve_each_queue_and_flag() {
    let mut reset = GlobalReset(IrCtx::default());
    ir_ctx_swap(&mut reset.0);
    let mut a = seeded(1);
    let mut b = seeded(2);
    for _ in 0..100 {
        for (context, marker) in [(&mut a, 1), (&mut b, 2)] {
            ir_ctx_swap(context);
            let mut observed = IrCtx::default();
            ir_ctx_swap(&mut observed);
            same(&observed, &seeded(marker));
            ir_ctx_swap(&mut observed);
            ir_ctx_swap(context);
            same(context, &seeded(marker));
        }
    }
}
#[test]
fn scheduled_frame_delivery_is_local_and_deterministic() {
    let mut a = IrCtx::default();
    let mut b = IrCtx::default();
    let body = [0xFF, 0xC0, 0xC1, 0x7D, 0, 0xFF];
    a.deliver(&body, 2.5);
    assert!(b.rx.is_empty() && b.react_out.is_empty() && b.outbox.is_empty());
    b.deliver(&body, 2.5);
    assert_eq!(a.react_out, b.react_out);
    let (due, frame) = a.react_out.pop_front().unwrap();
    assert_eq!(due, 2.5);
    assert!(!frame.is_empty());
    assert_eq!(b.react_out.len(), 1);
    assert!(a.react_out.is_empty());
}
