import Foundation
import QuartzCore
import UIKit

/// Infrared between two of your own devices. When the device you're playing reaches the
/// "WAITING…" screen of Connection › Tamagotchi (PLAYDATE, GIFT or MARRY), another device of
/// yours is woken from its save, taken to the same screen by itself, and the two are joined:
/// what one sends the other receives, with real data on both sides. Afterwards the visitor is
/// saved and put back to sleep; its clock catches up when you next switch to it.
final class IRLink {
    static let shared = IRLink()
    fileprivate(set) var active = false
    fileprivate var starting = false
    /// A link is being set up or running: nothing may change the toy's clock or state meanwhile.
    var busy: Bool { active || starting || CACurrentMediaTime() < quietUntil }
    fileprivate var quietUntil = 0.0      // the visit scene keeps playing after the infrared stops: no background reading then
    private var cooldownUntil = 0.0
    private var lastEnd = 0.0

    /// The device's infrared is on (its serial speed was set for infrared).
    static func waiting(_ h: OpaquePointer) -> Bool {
        var b = [UInt8](repeating: 0, count: 2)
        guard tg_peek(h, 0xC006000C, &b, 2) == 1,
              UInt16(b[0]) | UInt16(b[1]) << 8 == 0x341 else { return false }
        // The serial speed stays set after leaving the screen (and in saves), so also require the
        // infrared transceiver to be switched on (GPIO 0x24 bit 15, active low).
        var g: UInt8 = 0xFF
        guard tg_peek(h, 0xC0000025, &g, 1) == 1 else { return false }
        return g & 0x80 == 0
    }

    /// Which entry of the PLAYDATE / GIFT / MARRY / TRAVEL list is chosen (Wonder Garden EN; others: PLAYDATE).
    static func mode(_ h: OpaquePointer, deviceID: String) -> Int {
        guard deviceID.contains("wondergarden") else { return 0 }
        var b = [UInt8](repeating: 0, count: 1)
        guard tg_peek(h, 0xF80178E4, &b, 1) == 1, b[0] <= 3 else { return 0 }
        return Int(b[0])
    }

    /// For GIFT: 0 = this device chose GIVE, 1 = RECEIVE (Wonder Garden EN; others: unknown = -1).
    static func role(_ h: OpaquePointer, deviceID: String) -> Int {
        guard deviceID.contains("wondergarden") else { return -1 }
        var b = [UInt8](repeating: 0, count: 1)
        guard tg_peek(h, 0xF80178BC, &b, 1) == 1, b[0] <= 1 else { return -1 }
        return Int(b[0])
    }

    /// A saved device's life stage (read from its save, without running it). TRAVEL needs stage 2 or later.
    static func stage(of toy: Toy) -> Int {
        guard let v = Emulator.makeHandle(toy).0 else { return -1 }
        defer { tg_destroy(v) }
        var b: UInt8 = 0
        return tg_peek(v, 0xF800D8B6, &b, 1) == 1 ? Int(b) : -1
    }
    static let travelMinStage = 2

    /// Called from the run loop (core locked) whenever the radio state is polled.
    func watch(emu: Emulator, handle h: OpaquePointer, deviceID: String, now: Double) {
        guard !active, !starting else { return }
        guard IRLink.waiting(h) else {
            // you backed out of the WAITING screen: the next time you open it, try again right away
            if now >= lastEnd + 3 { cooldownUntil = 0 }
            return
        }
        guard now >= cooldownUntil, !emu.holdForApp, !emu.appWaiting else { return }
        guard let model = AppModel.current, let me = emu.toy else { return }
        let others = model.toys.filter { $0.id != me.id && !Town.shared.state($0).away }.sorted(by: { a, b in
            let last = Prefs.d.string(forKey: "ir.lastPartner")
            return (a.id == last ? 0 : 1, a.romName == me.romName ? 0 : 1, a.name) < (b.id == last ? 0 : 1, b.romName == me.romName ? 0 : 1, b.name)
        })
        guard !others.isEmpty else {
            cooldownUntil = now + 30
            if model.toys.count > 1 { emu.say("Your other device is out in Tamatown. Bring it home first, then connect.", seconds: 6) }
            return
        }
        starting = true
        let mode = IRLink.mode(h, deviceID: deviceID)
        if mode == 3 { emu.linkFreezeUntil = now + 60 }
        // GIFT: GIVE / RECEIVE. TRAVEL: 0 = this device chose VISIT, 1 = INVITE (Wonder Garden EN)
        var role = IRLink.role(h, deviceID: deviceID)
        if mode == 3 {
            var tb: UInt8 = 9
            role = tg_peek(h, 0xF80178C4, &tb, 1) == 1 && tb <= 1 ? Int(tb) : -1
        }
        let begin: (Toy) -> Void = { [self] partner in
            let t = Thread { [self] in
                run(emu: emu, me: me, partner: partner, mode: mode, role: role)
                emu.linkFreezeUntil = 0
                starting = false
                cooldownUntil = max(cooldownUntil, CACurrentMediaTime() + 1.5)
                lastEnd = CACurrentMediaTime()
            }
            t.name = "TamaiOS infrared link"
            t.qualityOfService = .userInitiated
            t.start()
        }
        let choose: ([Toy], [String: String]) -> Void = { _, blocked in
            DispatchQueue.main.async {
                model.irChoice = IRChoice(candidates: others, blocked: blocked, pick: begin, cancel: { [self] in
                    emu.linkFreezeUntil = 0
                    starting = false
                    cooldownUntil = CACurrentMediaTime() + 20
                })
            }
        }
        if mode == 3 {
            // TRAVEL: every device taking part has to be old enough, or the toy refuses and the link would fail
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var blocked: [String: String] = [:]
                for t in others where IRLink.stage(of: t) < IRLink.travelMinStage { blocked[t.id] = "Too young to travel" }
                let eligible = others.filter { blocked[$0.id] == nil }
                if eligible.isEmpty {
                    cooldownUntil = CACurrentMediaTime() + 30
                    emu.linkFreezeUntil = 0
                    starting = false
                    emu.say("None of your other devices can travel yet. They need to grow up a bit first.", seconds: 7)
                    return
                }
                if eligible.count == 1 { begin(eligible[0]) } else { choose(eligible, blocked) }
            }
            return
        }
        if others.count == 1 { begin(others[0]); return }
        choose(others, [:])
    }

    // MARK: bringing the visitor home

    /// One short radio write to the visitor's built-in app module, ticking it until it takes it.
    fileprivate func radioWrite(_ p: OpaquePointer, _ d: [UInt8], _ audio: UnsafeMutablePointer<Int16>) -> Bool {
        for _ in 0..<500 {
            if d.withUnsafeBufferPointer({ tg_radio_write(p, $0.baseAddress, $0.count) }) == 1 { return true }
            tickAll(p, 1, audio)
        }
        return false
    }

    fileprivate func radioSend(_ p: OpaquePointer, _ pkt: [UInt8], _ audio: UnsafeMutablePointer<Int16>) -> Bool {
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

    fileprivate func radioRead(_ p: OpaquePointer) -> [UInt8]? {
        var q: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        guard tg_radio_read(p, &q, &n) == 1, let q else { return nil }
        defer { tg_free(q, n) }
        return Array(UnsafeBufferPointer(start: q, count: n))
    }

    /// The same listening the app does for a toy's answer (see TamaLink.answer), timed in toy ticks.
    fileprivate func radioAnswer(_ p: OpaquePointer, _ audio: UnsafeMutablePointer<Int16>, firstTicks: Int = 200, idleTicks: Int = 200) -> [UInt8]? {
        var gotAny = false, acked = false
        var buffer: [UInt8] = [], expected = -1
        var waited = 0
        while true {
            if let n = radioRead(p) {
                gotAny = true; waited = 0
                let tag = n.count >= 2 ? UInt16(n[0]) | UInt16(n[1]) << 8 : 0
                if expected >= 0 && buffer.count < expected && tag != 0x4DF0 { buffer += n }
                else if tag == 0x0CF0 {
                    acked = true
                    let status = n.count >= 4 ? UInt16(n[2]) | UInt16(n[3]) << 8 : 0
                    if status == 0x0200 { return buffer }
                    _ = radioWrite(p, [0xF0, 0x8E, 0x0D], audio)
                } else if tag == 0x0DF0 {
                    expected = n.count >= 4 ? Int(UInt16(n[2]) | UInt16(n[3]) << 8) : 0
                    buffer = []
                } else if tag == 0x4DF0 || tag == 0x5CF0 { return buffer }
                else if expected >= 0 { buffer += n }
                continue
            }
            tickAll(p, 1, audio)
            waited += 1
            if !gotAny && waited > firstTicks { return nil }
            if gotAny && waited > idleTicks { return acked ? buffer : nil }
        }
    }

    enum Homecoming { case home(name: String), notOut, stuck }

    /// If the visitor came back from the link "out" (I'M OUT), take it through GO BACK? › YES and the
    /// app's ordinary come-home exchange so it is home and ready for another connection.
    /// It is still playing its receiving animation for a while, so the keys are tried every few
    /// seconds. At home the same keys only open and close a menu, which the C presses undo.
    private func bringHome(_ p: OpaquePointer, _ audio: UnsafeMutablePointer<Int16>, rounds: Int = 8) -> Homecoming {
        var ready = false
        for round in 0..<rounds {
            tickAll(p, round == 0 ? 100 : 150, audio)
            for k in [TGKey.b, .a, .b] {
                tg_press(p, k.rawValue, CACurrentMediaTime())
                tickAll(p, 8, audio)
                tg_release(p, k.rawValue)
                tickAll(p, 30, audio)
            }
            for _ in 0..<60 where tg_radio_ready(p) == 0 { tickAll(p, 1, audio) }
            if tg_radio_ready(p) != 0 { ready = true; break }
            for _ in 0..<3 {
                tg_press(p, TGKey.c.rawValue, CACurrentMediaTime()); tickAll(p, 8, audio)
                tg_release(p, TGKey.c.rawValue); tickAll(p, 30, audio)
            }
        }
        guard ready else { return .notOut }
        tg_radio_connect(p, 1)
        defer { tickAll(p, 5, audio); tg_radio_connect(p, 0) }
        guard radioSend(p, TamaLink.packet(op: 0x15, cmd: 0), audio), let hello = radioAnswer(p, audio) else { return .stuck }
        let name = Town.decodeName(hello)
        tickAll(p, 3, audio)
        guard radioSend(p, Town.backPacket(nil, points: 0), audio), radioAnswer(p, audio, firstTicks: 400, idleTicks: 200) != nil else {
            return .stuck
        }
        return .home(name: name)
    }

    /// How to call a device's Tama in messages: its read name, else a name the user gave the device.
    static func tamaLabel(_ t: Toy, fallback: String = "your other Tama") -> String {
        if let n = LiveTamaName.savedName(t.id) { return n }
        if let n = Town.shared.state(t).petName, !n.isEmpty { return n }
        if !BundledVariant.all.contains(where: { $0.name == t.name }) { return t.name }
        return fallback
    }

    /// Whatever time the visitor spent being driven (menus, the exchange, coming home) is simulated
    /// faster than real time, so before it is saved its clock is set to the real time again.
    /// That way it never needs a "clock matched" correction when you switch to it.
    private func fixClock(_ p: OpaquePointer, _ toy: Toy, _ audio: UnsafeMutablePointer<Int16>) {
        let target = DaytimeClock.target(toy.id)
        tg_set_wall_clock(p, target)
        for _ in 0..<3 {
            if tg_sync_clock(p, target) == 1 { break }
            tickAll(p, 25, audio)
        }
    }

    private func saveSnapshot(_ p: OpaquePointer, _ toy: Toy) {
        var out: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        if tg_snapshot(p, &out, &n) == 1, let out {
            let d = Data(bytes: out, count: n)
            tg_free(out, n)
            try? d.write(to: ToyStore.snapURL(toy.id), options: .atomic)
        }
    }

    /// A 32×16 text sketch of the screen, for the log.
    fileprivate func asciiScreen(_ h: OpaquePointer) -> String {
        var px = [UInt32](repeating: 0, count: 128 * 128)
        _ = px.withUnsafeMutableBufferPointer { tg_frame(h, $0.baseAddress) }
        var rows: [String] = []
        let lo = px.map { Int(($0 >> 16) & 255) + Int(($0 >> 8) & 255) + Int($0 & 255) }.min() ?? 0
        let hi = px.map { Int(($0 >> 16) & 255) + Int(($0 >> 8) & 255) + Int($0 & 255) }.max() ?? 0
        let mid = (lo + hi) / 2
        var blank = false
        for y in 4..<124 {
            var r = ""
            for x in 4..<124 {
                let c = px[y * 128 + x]
                r += Int((c >> 16) & 255) + Int((c >> 8) & 255) + Int(c & 255) < mid ? "#" : " "
            }
            while r.hasSuffix(" ") { r.removeLast() }
            if r.isEmpty { if !blank { rows.append("") }; blank = true } else { rows.append(r); blank = false }
        }
        return rows.joined(separator: "\n")
    }

    fileprivate func tickAll(_ p: OpaquePointer, _ n: Int, _ audio: UnsafeMutablePointer<Int16>) {
        for _ in 0..<n {
            _ = tg_tick(p, 0.02); _ = tg_take_audio(p, audio, 44100)
            // let the device you're playing take its turn: the cores share one lock while ticking, and a
            // tight loop here would otherwise make its frames wait (visible as stutter during a link)
            usleep(600)
        }
    }

    private func run(emu: Emulator, me: Toy, partner: Toy, mode: Int, role: Int) {
        emu.say("Getting \(IRLink.tamaLabel(partner)) ready for \(IRLink.tamaLabel(me, fallback: "your Tama"))…", seconds: 4)
        let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 44100)
        var visitor: OpaquePointer?
        defer { audio.deallocate(); if let v = visitor { tg_destroy(v) } }
        // C backs out to the home screen; A opens the menu (PROFILE) and walks to Connection;
        // B, B enters Connection › Tamagotchi; A picks the mode. Devices differ in what comes
        // after choosing GIFT (GIVE / RECEIVE), so try the likely endings until one reaches WAITING.
        let head: [TGKey] = [.c, .c, .c, .c, .a, .a, .a, .a, .a, .b, .b] + Array(repeating: .a, count: mode)
        var tails: [[TGKey]] = [[.b]]
        // TRAVEL: you INVITE (and pick the place) → the other device VISITs. You VISIT → the other device
        // INVITEs and picks a random place from the 8 in the list; locked ones refuse, so try them in
        // random order until one accepts (every unlocked place is equally likely).
        let inviteScan = mode == 3 && role == 0
        if mode == 3 {
            // each place in random order, until one that this device has unlocked accepts
            tails = inviteScan ? (0..<8).shuffled().map { [TGKey.b, .a, .b] + Array(repeating: TGKey.a, count: $0) + [.b] } : [[.b, .b]]
        }
        if mode == 1 {
            // the visitor takes the opposite of what you chose (RECEIVE when you give or when unsure)
            tails = role == 1 ? [[.b, .b, .b], [.b, .b]] : [[.b, .a, .b], [.b, .b], [.b, .a, .a, .b]]
        }
        func reach() -> Bool {
            for tail in tails {
                if let v = visitor { tg_destroy(v); visitor = nil }
                guard let v = Emulator.makeHandle(partner).0 else { return false }
                visitor = v
                tg_set_volume(v, 0)
                tg_set_never_sleep(v, 0)
                tg_wake(v)
                tickAll(v, 25, audio)
                for k in head + tail {
                    tg_press(v, k.rawValue, CACurrentMediaTime())
                    tickAll(v, 8, audio)
                    tg_release(v, k.rawValue)
                    tickAll(v, 22, audio)
                }
                if inviteScan { tickAll(v, 70, audio) }      // the CONNECTING screen takes a moment
                tickAll(v, 25, audio)
                if IRLink.waiting(v) { return true }
                emu.note("infrared link: \(partner.name) didn't reach the waiting screen with ending \(tail.map { "\($0)" })")
            }
            return false
        }
        var reached = reach()
        if !reached, let v = visitor {
            // maybe it is still out from an earlier visit: send it home, then try again
            if case .home = bringHome(v, audio, rounds: 3) {
                emu.note("infrared link: \(partner.name) was out and is home now")
                fixClock(v, partner, audio)
                saveSnapshot(v, partner)
                reached = reach()
            }
        }
        guard let p = visitor, IRLink.waiting(p) else {
            emu.say("The other device couldn't get ready (is its Tama home and awake?). Nothing was changed.", seconds: 6)
            cooldownUntil = CACurrentMediaTime() + 60
            return
        }
        guard emu.withCore({ h -> Bool in
            guard IRLink.waiting(h) else { return false }
            tg_ir_link(h, 1)
            emu.linkFreezeUntil = 0
            return true
        }) == true else { return }
        tg_ir_link(p, 1)
        active = true
        emu.note("infrared link: \(me.name) ⇄ \(partner.name) (mode \(mode))")
        emu.say("\(IRLink.tamaLabel(me, fallback: "Your Tama")) ⇄ \(IRLink.tamaLabel(partner)) are linked. \(mode == 3 ? "Starting the trip… ✈️" : "Press B to start. 📡")", seconds: 6)

        var buf = [UInt8](repeating: 0, count: 1024)
        var last = CACurrentMediaTime()
        let began = last
        var idleSince: Double? = nil
        var sawTraffic = false
        var bytes = 0
        var sawDisc = false
        var trace: [String] = []
        var lastTraffic = CACurrentMediaTime()
        // TRAVEL: a toy on CONNECTING first tries a few times on its own, gives up (FAIL) after about 3 s, and
        // then B starts the real connection. The app presses that B, so nobody has to catch the moment.
        var pClock = 1.9                  // the invited partner has already been on CONNECTING this long
        var autoB = !(mode == 3)
        var myClock = 0.0
        while true {
            let now = CACurrentMediaTime()
            let dt = min(now - last, 0.1)
            last = now
            // the visitor waits on its WAITING screen, frozen, until your device first speaks, so it
            // can't time out while you get ready to press B
            if dt > 0 && (sawTraffic || inviteScan) { _ = tg_tick(p, dt); _ = tg_take_audio(p, audio, 44100) }
            if mode == 3 && !autoB {
                if inviteScan {
                    pClock += dt
                    if pClock > 3.8 {
                        autoB = true
                        tg_press(p, TGKey.b.rawValue, CACurrentMediaTime()); tickAll(p, 8, audio); tg_release(p, TGKey.b.rawValue)
                        emu.note("infrared link: partner pressed B to start the trip")
                    }
                } else if role == 1 {
                    myClock += dt
                    if myClock > 3.8 {
                        autoB = true
                        emu.press(.b)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { emu.release(.b) }
                        emu.note("infrared link: pressed B to start the trip")
                    }
                } else { autoB = true }
            }
            // frames from the visitor go to the toy you're playing, and back; your toy's core is
            // locked once per pass (not per frame) so this doesn't get in the way of its own loop
            var toYou: [[UInt8]] = []
            while true {
                let n = tg_ir_take(p, &buf, buf.count)
                if n <= 0 { break }
                toYou.append(Array(buf[0..<n]))
            }
            var toVisitor: [[UInt8]] = []
            let ran: Bool? = emu.withCore { h -> Bool in
                for f in toYou { f.withUnsafeBufferPointer { tg_ir_deliver(h, $0.baseAddress, f.count) } }
                while true {
                    let m = tg_ir_take(h, &buf, buf.count)
                    if m <= 0 { break }
                    toVisitor.append(Array(buf[0..<m]))
                }
                return true
            }
            if ran == nil { break }
            for f in toVisitor { f.withUnsafeBufferPointer { tg_ir_deliver(p, $0.baseAddress, f.count) } }
            for f in toYou {
                bytes += f.count; trace.append("visitor→you \(f.count)B " + f.prefix(6).map { String(format: "%02x", $0) }.joined())
            }
            for f in toVisitor {
                if f.count == 2 && f[1] == 0x53 { sawDisc = true }
                bytes += f.count; trace.append("you→visitor \(f.count)B " + f.prefix(6).map { String(format: "%02x", $0) }.joined())
            }
            let moved = !toYou.isEmpty || !toVisitor.isEmpty
            if moved { sawTraffic = true; lastTraffic = CACurrentMediaTime() }
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
            Thread.sleep(forTimeInterval: moved ? 0.002 : 0.004)
        }
        _ = emu.withCore { tg_ir_link($0, 0) }
        tg_ir_link(p, 0)
        active = false
        quietUntil = CACurrentMediaTime() + 32
        Emulator.clockHoldUntil = CACurrentMediaTime() + 60
        // let the visitor settle (it shows its result), then save it where it was kept
        // let it finish whatever it was doing (a half-finished connection times out), show the
        // result, then press C until it is back on its home screen, so it is saved at home
        let finished = sawDisc && bytes > 3000
        var outcome = Homecoming.notOut
        if finished {
            outcome = bringHome(p, audio)
            if case .home(let n) = outcome, !n.isEmpty { Prefs.d.set(n, forKey: "tamaName.v1." + partner.id) }
            emu.note("infrared link: \(partner.name) \(outcome)")
        }
        for _ in 0..<6 {
            tg_press(p, TGKey.c.rawValue, CACurrentMediaTime())
            tickAll(p, 8, audio)
            tg_release(p, TGKey.c.rawValue)
            tickAll(p, 25, audio)
        }
        tickAll(p, 50, audio)
        // only keep the visitor's new state if the exchange really finished; otherwise it stays as it was
        if finished {
            fixClock(p, partner, audio)
            saveSnapshot(p, partner)
        }
        emu.note("infrared link: \(trace.count) frames, \(bytes) bytes; last frames:\n" + trace.suffix(30).joined(separator: "\n"))
        let who = IRLink.tamaLabel(partner)
        if finished {
            switch outcome {
            case .stuck:
                emu.say("Done, but \(who) didn't make it home. On that device choose GO BACK › YES.", seconds: 8)
            default:
                // Your device is still playing the visit scene (about 25 s: the guest plays, says
                // goodbye and leaves). Say it when that's over, not when the infrared stops.
                let text = mode == 1 ? "Gift delivered! \(who) is back home. 💕" : (mode == 3 ? "Travel is over. \(who) is heading home. ✈️" : "\(who) is heading home. 💕")
                emu.note("infrared link: message due when the visit scene ends")
                // counted from the last infrared traffic (not from when the link thread finished, which is
                // some 10 s later: it waits out 8 s of silence first)
                let wait = max(0.5, lastTraffic + 33 - CACurrentMediaTime())
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    guard emu.toy?.id == me.id, !emu.loading else { return }
                    emu.say(text, seconds: 5)
                }
            }
        } else if sawTraffic {
            emu.say("The infrared link stopped early, so nothing was exchanged. \(who) is unchanged. Try again.", seconds: 7)
        }
        emu.note("infrared link ended")
    }
}

// MARK: reading a Tama's name from any device

extension IRLink {
    private static let nameQueue = DispatchQueue(label: "TamaiOS name probe", qos: .utility)
    private static var probing = false

    /// Find out the names of Tamas whose name isn't known yet (the on-screen reader only knows Wonder
    /// Garden). Each device is started from its save as a disposable copy, taken to Connection › App,
    /// and asked hello like the phone app does; the answer carries the Tama's name. Nothing is saved
    /// back, so the real device isn't touched and its clock isn't moved.
    private static var activeNameLoop = UUID()
    /// Names for the device you're playing when it isn't the one with the live name sync (the same
    /// PROFILE-page reading, on a hidden copy): a first check soon after it opens, then every few minutes.
    /// Background name work waits for a quiet moment so it never competes with play.
    fileprivate static func waitForQuiet(_ emu: Emulator, maxWait: Double = 60) {
        let end = CACurrentMediaTime() + maxWait
        while CACurrentMediaTime() < end, CACurrentMediaTime() - emu.lastKeyTime < 1.5 || shared.busy {
            Thread.sleep(forTimeInterval: 1)
        }
    }
    private static var identityChangedAt = 0.0
    static func watchActiveName() {
        let token = UUID(); activeNameLoop = token
        var lastIdentity = ""
        var polls = 0
        func identity() -> String {
            AppModel.current?.emu.withCore { h -> String in
                var stage: UInt8 = 0
                var ch = [UInt8](repeating: 0, count: 4), sig = [UInt8](repeating: 0, count: 4)
                guard tg_peek(h, 0xF800_D8B6, &stage, 1) == 1,
                      ch.withUnsafeMutableBufferPointer({ tg_peek(h, 0xF800_D8C4, $0.baseAddress, 4) }) == 1,
                      sig.withUnsafeMutableBufferPointer({ tg_peek(h, 0xF800_D8B0, $0.baseAddress, 4) }) == 1 else { return "" }
                return "\(sig.map { String(format: "%02X", $0) }.joined()).\(stage).\(ch.map { String($0) }.joined(separator: "-"))"
            } ?? ""
        }
        // A name can only change when the Tama does: a new egg hatching, a new game, growing up.
        // So the Tama's identity (id, life stage, look) is checked every few seconds (a few bytes of
        // memory, off the main thread) and the name is read when that changes. A device whose name is
        // already known and whose identity hasn't changed since is left alone.
        func poll() {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                guard activeNameLoop == token else { return }
                polls += 1
                let now = identity()
                let toyID = AppModel.current?.emu.toy?.id ?? ""
                let known = Prefs.d.string(forKey: "tamaIdentity.v1." + toyID)
                if !now.isEmpty, now != lastIdentity {
                    lastIdentity = now
                    identityChangedAt = CACurrentMediaTime()
                    if known != now || LiveTamaName.savedName(toyID) == nil || !FileManager.default.fileExists(atPath: ToyStore.spriteURL(toyID).path) {
                        // read when it has settled; try again a little later only if there was no name yet
                        // A growth animation keeps the old picture on screen for a while, so a read soon after a change is
                        // only provisional: it is repeated once things have settled (the identity is only marked as
                        // "done" by a read taken at least 12 s after the change).
                        for (i, d) in [0.4, 5.0, 13.0, 40.0, 90.0].enumerated() {
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + d) {
                                guard activeNameLoop == token, identity() == now else { return }
                                if i > 0, Prefs.d.string(forKey: "tamaIdentity.v1." + toyID) == now { return }
                                refreshActiveName(identity: now)
                            }
                        }
                    }
                } else if polls % 200 == 0 {      // about every five minutes as a safety net
                    refreshActiveName(identity: now)
                }
                poll()
            }
        }
        poll()
    }
    static func refreshActiveName(identity: String = "") {
        if let m = AppModel.current {
            let id = m.emu.toy?.id ?? ""
            let haveAll = LiveTamaName.savedName(id) != nil && FileManager.default.fileExists(atPath: ToyStore.spriteURL(id).path)
            if haveAll { waitForQuiet(m.emu, maxWait: 4) }     // only an update waits for a pause; a first fill goes straight away
        }
        DispatchQueue.main.async { startActiveNameRead(identity: identity) }
    }
    private static func startActiveNameRead(identity: String) {
        guard let model = AppModel.current, let toy = model.emu.toy,
              !model.emu.loading, !shared.busy, !model.emu.holdForApp, !model.emu.appWaiting,
              UIApplication.shared.applicationState == .active else { return }
        ProfileNameReader.shared.read(emu: model.emu, key: nil, spriteURL: ToyStore.spriteURL(toy.id)) { r in
            guard model.emu.toy?.id == toy.id else { return }
            if let n = r.name, !n.isEmpty {
                if !identity.isEmpty, CACurrentMediaTime() - identityChangedAt >= 12 { Prefs.d.set(identity, forKey: "tamaIdentity.v1." + toy.id) }
                if LiveTamaName.savedName(toy.id) != n {
                    Prefs.d.set(n, forKey: "tamaName.v1." + toy.id)
                    model.emu.note("name sync: \(toy.name) is \(n)")
                    model.objectWillChange.send()
                }
            }
        }
    }
    private static var namesChecked = Set<String>()
    static func refreshNames(note: ((String) -> Void)? = nil, recheck: Bool = true) {
        guard let model = AppModel.current else { return }
        let current = model.emu.toy?.id
        func missing(_ t: Toy) -> Bool {
            LiveTamaName.savedName(t.id) == nil || !FileManager.default.fileExists(atPath: ToyStore.spriteURL(t.id).path)
        }
        // Devices with no name or picture yet are read right away, side by side, without waiting for a quiet
        // moment (you're usually looking at them). Known ones are re-checked once per launch, politely
        // (a Tama may have hatched or been renamed while you played another device).
        let todo = model.toys.filter { !Town.shared.state($0).away && ($0.id != current || LiveTamaName.savedName($0.id) == nil) }
        let urgent = todo.filter { missing($0) }
        let later = recheck ? todo.filter { !missing($0) && !namesChecked.contains($0.id) } : []
        guard !urgent.isEmpty || !later.isEmpty else { return }
        func read(_ t: Toy) {
            namesChecked.insert(t.id)
            let log: (String) -> Void = { m in
                let line = "name reader: \(t.name): \(m)"
                if let note = note { note(line) } else { DispatchQueue.main.async { AppModel.current?.emu.note(line) } }
            }
            if let n = shared.readName(t, log: log) {
                log("found \(n)")
                Prefs.d.set(n, forKey: "tamaName.v1." + t.id)
                DispatchQueue.main.async { AppModel.current?.objectWillChange.send() }
            }
        }
        if !urgent.isEmpty && !shared.active && !shared.starting {
            let group = DispatchGroup()
            for t in urgent {
                nameLock.lock(); let fresh = reading.insert(t.id).inserted; nameLock.unlock()
                if !fresh { continue }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    read(t)
                    nameLock.lock(); reading.remove(t.id); nameLock.unlock()
                    group.leave()
                }
            }
        }
        if !later.isEmpty {
            nameQueue.async {
                guard !probing, !shared.active, !shared.starting else { return }
                probing = true
                defer { probing = false }
                for t in later {
                    if let m = AppModel.current { waitForQuiet(m.emu) }
                    if shared.active || shared.starting { break }
                    read(t)
                }
            }
        }
    }
    private static var reading = Set<String>()
    private static let nameLock = NSLock()

    fileprivate func readName(_ toy: Toy, log: (String) -> Void) -> String? {
        let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 44100)
        defer { audio.deallocate() }
        // Connection › (the APP entry, tried at the third and then second place) — or, if the Tama is
        // out in town, GO BACK? › YES leads to the same app screen
        // First choice: the PROFILE page, read like the app-wide name sync does
        if let v = Emulator.makeHandle(toy).0 {
            tg_set_volume(v, 0)
            tg_set_never_sleep(v, 0)
            tg_wake(v)
            tickAll(v, 40, audio)
            let r = ProfileNameReader.shared.readNow(handle: v, spriteURL: ToyStore.spriteURL(toy.id))
            tg_destroy(v)
            for t in r.trace { log("profile: " + t) }
            if let n = r.name { log("name from the PROFILE page"); return n }
            log("profile page: \(r.detail)")
        }
        let endings: [[TGKey]] = [[.a, .a, .b], [.a, .b], [.a, .a, .a, .b], [.a, .a, .a, .a, .b], [.a, .a, .b, .b], []]
        var found: OpaquePointer?
        for (i, ending) in endings.enumerated() {
            guard let v = Emulator.makeHandle(toy).0 else { log("could not start"); return nil }
            tg_set_volume(v, 0)
            tg_set_never_sleep(v, 0)
            tg_wake(v)
            tickAll(v, 25, audio)
            if ending.isEmpty {
                if case .home(let n) = bringHome(v, audio, rounds: 3), (1...12).contains(n.filter { $0.isLetter }.count) {
                    tg_destroy(v)
                    log("name came from the come-home hello")
                    return n
                }
                tg_destroy(v)
                break
            }
            let keys: [TGKey] = [.c, .c, .c, .c, .a, .a, .a, .a, .a, .b] + ending
            for k in keys {
                tg_press(v, k.rawValue, CACurrentMediaTime())
                tickAll(v, 8, audio)
                tg_release(v, k.rawValue)
                tickAll(v, 22, audio)
            }
            for _ in 0..<100 where tg_radio_ready(v) == 0 { tickAll(v, 1, audio) }
            if tg_radio_ready(v) != 0 { found = v; log("reached the app screen with ending \(i)"); break }
            log("ending \(i): asleep=\(tg_is_asleep(v)), screen:\n" + asciiScreen(v))
            tg_destroy(v)
        }
        guard let p = found else { log("never reached WAITING FOR APP"); return nil }
        defer { tg_destroy(p) }
        tg_radio_connect(p, 1)
        defer { tickAll(p, 5, audio); tg_radio_connect(p, 0) }
        guard radioSend(p, TamaLink.packet(op: 0x17, cmd: 0), audio), let hello = radioAnswer(p, audio) else { log("no answer to hello"); return nil }
        let name = Town.decodeName(hello)
        log("hello \(hello.count) bytes, name '\(name)'")
        let letters = name.filter { $0.isLetter }
        guard (1...12).contains(letters.count), letters.count == name.filter({ !$0.isWhitespace }).count else { log("no usable name yet (egg?)"); return nil }
        return name
    }
}
