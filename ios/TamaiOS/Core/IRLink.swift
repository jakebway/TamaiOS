import Foundation
import QuartzCore

/// Infrared between two of your own devices. When the device you're playing reaches the
/// "WAITING…" screen of Connection › Tamagotchi (PLAYDATE, GIFT or MARRY), another device of
/// yours is woken from its save, taken to the same screen by itself, and the two are joined:
/// what one sends the other receives, with real data on both sides. Afterwards the visitor is
/// saved and put back to sleep; its clock catches up when you next switch to it.
final class IRLink {
    static let shared = IRLink()
    private(set) var active = false
    private var starting = false
    private var cooldownUntil = 0.0

    /// The device's infrared is on (its serial speed was set for infrared).
    static func waiting(_ h: OpaquePointer) -> Bool {
        var b = [UInt8](repeating: 0, count: 2)
        guard tg_peek(h, 0xC006000C, &b, 2) == 1 else { return false }
        return UInt16(b[0]) | UInt16(b[1]) << 8 == 0x341
    }

    /// Which entry of the PLAYDATE / GIFT / MARRY list is chosen (Wonder Garden EN; others: PLAYDATE).
    static func mode(_ h: OpaquePointer, deviceID: String) -> Int {
        guard deviceID.contains("wondergarden") else { return 0 }
        var b = [UInt8](repeating: 0, count: 1)
        guard tg_peek(h, 0xF80178E4, &b, 1) == 1, b[0] <= 2 else { return 0 }
        return Int(b[0])
    }

    /// For GIFT: 0 = this device chose GIVE, 1 = RECEIVE (Wonder Garden EN; others: unknown = -1).
    static func role(_ h: OpaquePointer, deviceID: String) -> Int {
        guard deviceID.contains("wondergarden") else { return -1 }
        var b = [UInt8](repeating: 0, count: 1)
        guard tg_peek(h, 0xF80178BC, &b, 1) == 1, b[0] <= 1 else { return -1 }
        return Int(b[0])
    }

    /// Called from the run loop (core locked) whenever the radio state is polled.
    func watch(emu: Emulator, handle h: OpaquePointer, deviceID: String, now: Double) {
        guard !active, !starting, now >= cooldownUntil, IRLink.waiting(h),
              !emu.holdForApp, !emu.appWaiting else { return }
        guard let model = AppModel.current, let me = emu.toy else { return }
        let others = model.toys.filter { $0.id != me.id }.sorted(by: { a, b in
            let last = Prefs.d.string(forKey: "ir.lastPartner")
            return (a.id == last ? 0 : 1, a.romName == me.romName ? 0 : 1, a.name) < (b.id == last ? 0 : 1, b.romName == me.romName ? 0 : 1, b.name)
        })
        guard !others.isEmpty else { cooldownUntil = now + 5; return }
        starting = true
        let mode = IRLink.mode(h, deviceID: deviceID)
        let role = IRLink.role(h, deviceID: deviceID)
        let begin: (Toy) -> Void = { [self] partner in
            let t = Thread { [self] in
                run(emu: emu, me: me, partner: partner, mode: mode, role: role)
                starting = false
                cooldownUntil = max(cooldownUntil, CACurrentMediaTime() + 1.5)
            }
            t.name = "TamaiOS infrared link"
            t.qualityOfService = .userInitiated
            t.start()
        }
        if others.count == 1 { begin(others[0]); return }
        // more than one other device: ask which one to link with
        DispatchQueue.main.async {
            model.irChoice = IRChoice(candidates: others, pick: begin, cancel: { [self] in
                starting = false
                cooldownUntil = CACurrentMediaTime() + 20
            })
        }
    }

    // MARK: bringing the visitor home

    /// One short radio write to the visitor's built-in app module, ticking it until it takes it.
    private func radioWrite(_ p: OpaquePointer, _ d: [UInt8], _ audio: UnsafeMutablePointer<Int16>) -> Bool {
        for _ in 0..<500 {
            if d.withUnsafeBufferPointer({ tg_radio_write(p, $0.baseAddress, $0.count) }) == 1 { return true }
            tickAll(p, 1, audio)
        }
        return false
    }

    private func radioSend(_ p: OpaquePointer, _ pkt: [UInt8], _ audio: UnsafeMutablePointer<Int16>) -> Bool {
        tickAll(p, 1, audio)
        guard radioWrite(p, [0xF0, 0x8D], audio) else { return false }
        var i = 0
        while i < pkt.count {
            let j = min(i + 20, pkt.count)
            guard radioWrite(p, Array(pkt[i..<j]), audio) else { return false }
            i = j
        }
        return radioWrite(p, [0xF0, 0xCD], audio)
    }

    private func radioRead(_ p: OpaquePointer) -> [UInt8]? {
        var q: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        guard tg_radio_read(p, &q, &n) == 1, let q else { return nil }
        defer { tg_free(q, n) }
        return Array(UnsafeBufferPointer(start: q, count: n))
    }

    /// The same listening the app does for a toy's answer (see TamaLink.answer), timed in toy ticks.
    private func radioAnswer(_ p: OpaquePointer, _ audio: UnsafeMutablePointer<Int16>, firstTicks: Int = 200, idleTicks: Int = 200) -> Bool {
        var gotAny = false, acked = false
        var buffer = 0, expected = -1
        var waited = 0
        while true {
            if let n = radioRead(p) {
                gotAny = true; waited = 0
                let tag = n.count >= 2 ? UInt16(n[0]) | UInt16(n[1]) << 8 : 0
                if expected >= 0 && buffer < expected && tag != 0x4DF0 { buffer += n.count }
                else if tag == 0x0CF0 {
                    acked = true
                    let status = n.count >= 4 ? UInt16(n[2]) | UInt16(n[3]) << 8 : 0
                    if status == 0x0200 { return true }
                    _ = radioWrite(p, [0xF0, 0x8E, 0x0D], audio)
                } else if tag == 0x0DF0 {
                    expected = n.count >= 4 ? Int(UInt16(n[2]) | UInt16(n[3]) << 8) : 0
                    buffer = 0
                } else if tag == 0x4DF0 || tag == 0x5CF0 { return true }
                else if expected >= 0 { buffer += n.count }
                continue
            }
            tickAll(p, 1, audio)
            waited += 1
            if !gotAny && waited > firstTicks { return false }
            if gotAny && waited > idleTicks { return acked }
        }
    }

    /// If the visitor came back from the link "out" (I'M OUT), take it through GO BACK? › YES and the
    /// app's ordinary come-home exchange so it is home and ready for another connection.
    /// At home the same keys only open and close a menu, which the C presses afterwards undo.
    private func bringHome(_ p: OpaquePointer, _ audio: UnsafeMutablePointer<Int16>) -> Bool {
        for _ in 0..<2 {
            for k in [TGKey.b, .a, .b] {
                tg_press(p, k.rawValue, CACurrentMediaTime())
                tickAll(p, 8, audio)
                tg_release(p, k.rawValue)
                tickAll(p, 30, audio)
            }
            for _ in 0..<60 where tg_radio_ready(p) == 0 { tickAll(p, 1, audio) }
            if tg_radio_ready(p) != 0 { break }
            // not waiting for the app: back out of whatever those keys opened and look again
            for _ in 0..<3 {
                tg_press(p, TGKey.c.rawValue, CACurrentMediaTime()); tickAll(p, 8, audio)
                tg_release(p, TGKey.c.rawValue); tickAll(p, 30, audio)
            }
        }
        guard tg_radio_ready(p) != 0 else { return false }
        tg_radio_connect(p, 1)
        defer { tickAll(p, 5, audio); tg_radio_connect(p, 0) }
        guard radioSend(p, TamaLink.packet(op: 0x15, cmd: 0), audio), radioAnswer(p, audio) else { return false }
        tickAll(p, 3, audio)
        guard radioSend(p, Town.backPacket(nil, points: 0), audio) else { return false }
        return radioAnswer(p, audio, firstTicks: 400, idleTicks: 200)
    }

    private func tickAll(_ p: OpaquePointer, _ n: Int, _ audio: UnsafeMutablePointer<Int16>) {
        for _ in 0..<n { _ = tg_tick(p, 0.02); _ = tg_take_audio(p, audio, 44100) }
    }

    private func run(emu: Emulator, me: Toy, partner: Toy, mode: Int, role: Int) {
        let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 44100)
        var visitor: OpaquePointer?
        defer { audio.deallocate(); if let v = visitor { tg_destroy(v) } }
        // C backs out to the home screen; A opens the menu (PROFILE) and walks to Connection;
        // B, B enters Connection › Tamagotchi; A picks the mode. Devices differ in what comes
        // after choosing GIFT (GIVE / RECEIVE), so try the likely endings until one reaches WAITING.
        let head: [TGKey] = [.c, .c, .c, .c, .a, .a, .a, .a, .a, .b, .b] + Array(repeating: .a, count: mode)
        var tails: [[TGKey]] = [[.b]]
        if mode == 1 {
            // the visitor takes the opposite of what you chose (RECEIVE when you give or when unsure)
            tails = role == 1 ? [[.b, .b, .b], [.b, .b]] : [[.b, .a, .b], [.b, .b], [.b, .a, .a, .b]]
        }
        for tail in tails {
            if let v = visitor { tg_destroy(v); visitor = nil }
            guard let v = Emulator.makeHandle(partner).0 else { return }
            visitor = v
            tg_set_volume(v, 0)
            tg_set_never_sleep(v, 0)
            tg_wake(v)
            tickAll(v, 50, audio)
            for k in head + tail {
                tg_press(v, k.rawValue, CACurrentMediaTime())
                tickAll(v, 8, audio)
                tg_release(v, k.rawValue)
                tickAll(v, 40, audio)
            }
            tickAll(v, 25, audio)
            if IRLink.waiting(v) { break }
            emu.note("infrared link: \(partner.name) didn't reach the waiting screen with ending \(tail.map { "\($0)" })")
        }
        guard let p = visitor, IRLink.waiting(p) else {
            emu.say("The other device couldn't get ready (is its Tama home and awake?). Nothing was changed.", seconds: 6)
            cooldownUntil = CACurrentMediaTime() + 60
            return
        }
        guard emu.withCore({ h -> Bool in
            guard IRLink.waiting(h) else { return false }
            tg_ir_link(h, 1)
            return true
        }) == true else { return }
        tg_ir_link(p, 1)
        active = true
        emu.note("infrared link: \(me.name) ⇄ \(partner.name) (mode \(mode))")
        emu.say("Linked with \(partner.name)'s device — press B to start. 📡", seconds: 6)

        var buf = [UInt8](repeating: 0, count: 1024)
        var last = CACurrentMediaTime()
        let began = last
        var idleSince: Double? = nil
        var sawTraffic = false
        var bytes = 0
        var sawDisc = false
        var trace: [String] = []
        var lastTraffic = CACurrentMediaTime()
        while true {
            let now = CACurrentMediaTime()
            let dt = min(now - last, 0.1)
            last = now
            if dt > 0 { _ = tg_tick(p, dt); _ = tg_take_audio(p, audio, 44100) }
            // frames from the visitor go to the toy you're playing, and back
            var moved = true
            while moved {
                moved = false
                let n = tg_ir_take(p, &buf, buf.count)
                if n > 0 {
                    bytes += n; trace.append("visitor→you \(n)B " + buf[0..<min(n, 6)].map { String(format: "%02x", $0) }.joined())
                    moved = true; sawTraffic = true; lastTraffic = CACurrentMediaTime()
                    buf.withUnsafeBufferPointer { bp in
                        _ = emu.withCore { h in tg_ir_deliver(h, bp.baseAddress, n) }
                    }
                }
                let m: Int = emu.withCore { h -> Int in
                    let n = tg_ir_take(h, &buf, buf.count)
                    return n
                } ?? -1
                if m < 0 { break }
                if m > 0 {
                    if m == 2 && buf[1] == 0x53 { sawDisc = true }
                    bytes += m; trace.append("you→visitor \(m)B " + buf[0..<min(m, 6)].map { String(format: "%02x", $0) }.joined())
                    moved = true; sawTraffic = true; lastTraffic = CACurrentMediaTime()
                    buf.withUnsafeBufferPointer { bp in tg_ir_deliver(p, bp.baseAddress, m) }
                }
            }
            // is it over? Once data has flowed, only silence ends it (the infrared speed changes
            // during a connection, so "waiting" can't be trusted); before that, leaving the screen does.
            guard let stillOn = emu.withCore({ IRLink.waiting($0) }), emu.toy?.id == me.id else { break }
            if sawTraffic {
                if now - lastTraffic > 8 { break }
            } else if !stillOn {
                if idleSince == nil { idleSince = now }
                if now - idleSince! > 20 { break }
            } else { idleSince = nil }
            if !sawTraffic && now - began > 180 { break }
            if now - began > 600 { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        _ = emu.withCore { tg_ir_link($0, 0) }
        tg_ir_link(p, 0)
        active = false
        // let the visitor settle (it shows its result), then save it where it was kept
        // let it finish whatever it was doing (a half-finished connection times out), show the
        // result, then press C until it is back on its home screen, so it is saved at home
        let finished = sawDisc && bytes > 3000
        tickAll(p, 150, audio)
        if finished {
            let home = bringHome(p, audio)
            emu.note("infrared link: \(partner.name) \(home ? "came home" : "was not out (or could not be sent home)")")
        }
        for _ in 0..<6 {
            tg_press(p, TGKey.c.rawValue, CACurrentMediaTime())
            tickAll(p, 8, audio)
            tg_release(p, TGKey.c.rawValue)
            tickAll(p, 25, audio)
        }
        tickAll(p, 50, audio)
        var out: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        // only keep the visitor's new state if the exchange really finished; otherwise it stays as it was
        if finished, tg_snapshot(p, &out, &n) == 1, let out {
            let d = Data(bytes: out, count: n)
            tg_free(out, n)
            try? d.write(to: ToyStore.snapURL(partner.id), options: .atomic)
        }
        emu.note("infrared link: \(trace.count) frames, \(bytes) bytes; last frames:\n" + trace.suffix(30).joined(separator: "\n"))
        if finished {
            let who = LiveTamaName.savedName(partner.id) ?? "Your other Tama"
            emu.say("\(who) has returned home. 💕", seconds: 5)
        } else if sawTraffic {
            emu.say("The infrared link stopped early, so nothing was exchanged. Your other device is unchanged. Try again.", seconds: 7)
        }
        emu.note("infrared link ended")
    }
}
