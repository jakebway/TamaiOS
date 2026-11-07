import Foundation
import UIKit

/// Text commands for troubleshooting without rebuilding. Paste one command or
/// many (one per line, `#` starts a comment). Settings changed here persist.
final class Console: ObservableObject {
    static let shared = Console()
    @Published var output: String = "TamaiOS console. Type \"help\" for commands.\n"

    func append(_ s: String) {
        output += s.hasSuffix("\n") ? s : s + "\n"
        if output.count > 200_000 { output = String(output.suffix(150_000)) }
    }

    /// Run pasted text (several lines allowed).
    func runScript(_ text: String, emu: Emulator) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            append("> \(line)")
            append(run(line, emu: emu))
        }
    }

    static let appKeys: [String: String] = [
        "tick_ms": "p.tick_ms", "audio_min_ms": "p.audio_min_ms", "audio_max_ms": "p.audio_max_ms",
        "gap_s": "p.gap_s", "autosave_s": "p.autosave_s", "fps": "p.fps", "call_gap_s": "p.call_gap_s",
        "volume": "volume",
    ]
    static let coreKeys = ["max_step", "max_behind", "max_catchup", "min_hold", "rewind_gap",
                           "idle_skip", "never_sleep", "stop_on_bluetooth"]
    static let flagKeys = ["soundOn", "haptics", "liveInBackground", "callAlerts", "keepAwake", "neverSleep", "showHints"]

    func run(_ line: String, emu: Emulator) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return "" }
        let args = Array(parts.dropFirst())
        let noToy = "No device is running."
        switch cmd {
        case "help", "?":
            return Console.help

        case "status":
            return emu.coreText { tg_status($0, $1, $2) } ?? noToy

        case "log":
            let fw = emu.coreText { tg_log($0, $1, $2) } ?? noToy
            let n = Int(args.first ?? "") ?? 60
            return fw.split(separator: "\n").suffix(n).joined(separator: "\n")

        case "applog":
            return emu.appLog.suffix(Int(args.first ?? "") ?? 60).joined(separator: "\n")

        case "arcadeperf":
            return ArcadeDiagnostics.shared.report()

        case "linklog":
            return LinkDiagnostics.shared.report()

        case "carelog":
            return CareAlerts.shared.diagnostics()
        case "namelog":
            return LiveTamaName.shared.diagnostics()
        case "names":
            IRLink.refreshNames(note: { emu.note($0) })
            return "Reading Tama names from your other devices. Run applog in about 20 seconds."
        case "namecheck":
            LiveTamaName.shared.requestCheck()
            return "Scheduled a disposable-copy name check; no live menu presses. Run namelog after it finishes."
        case "diag":
            let s = diagnostics(emu, full: args.first?.lowercased() == "full")
            UIPasteboard.general.string = s
            return s + "\n(copied to clipboard — paste it into this chat)"

        case "devices":
            return devicesReport(emu)

        case "screen":
            return emu.withCore { h in
                "waiting for infrared: \(IRLink.waiting(h))  asleep: \(tg_is_asleep(h))  radio: \(tg_radio_ready(h))\n" + IRLink.shared.picture(h)
            } ?? noToy

        case "ram":
            return ramReport(emu) ?? noToy

        case "linkstate":
            return linkReport(emu)

        case "daytime":
            switch args.first?.lowercased() ?? "" {
            case "on": emu.setDaytimeMode(true); return "turning Daytime Mode on for all devices"
            case "off": emu.setDaytimeMode(false); return "turning Daytime Mode off for all devices"
            default: return daytimeReport()
            }

        case "partner":
            // partner <part of a device name or id> — wake that device headlessly and report its state
            guard let q = args.first?.lowercased(), let t = AppModel.current?.toys.first(where: { $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) || $0.romName.lowercased().contains(q) }) else { return "usage: partner <name or id part>  (see devices)" }
            return partnerReport(t)

        case "clear":
            DispatchQueue.main.async { self.output = "" }
            return ""

        case "press", "tap":
            guard let k = args.first.flatMap(key) else { return "usage: press A|B|C [hold_ms]" }
            let ms = Double(args.dropFirst().first ?? "") ?? 120
            emu.press(k)
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { emu.release(k) }
            return "pressed \(args[0].uppercased()) for \(Int(ms)) ms"

        case "keys":
            // keys ABBC [gap_ms] — scripted presses inside the toy's own time
            guard let seq = args.first else { return "usage: keys ABC... [gap_ms]" }
            let gap = (Double(args.dropFirst().first ?? "") ?? 400) / 1000
            var i = 0.0
            for ch in seq {
                guard let k = key(String(ch)) else { return "unknown key \(ch)" }
                emu.withCore { tg_script_press($0, k.rawValue, i * gap + 0.05) }
                i += 1
            }
            return "queued \(Int(i)) presses"

        case "release":
            emu.withCore { tg_release_all($0) }
            return "released all buttons"

        case "wake":
            emu.withCore { tg_wake($0) }
            return "woke"

        case "sleep":
            emu.sleepNow()
            return "asked to sleep"

        case "restart":
            emu.restart()
            return "restarted"

        case "reload":
            emu.reload()
            return "reloading from saves"

        case "sync", "syncclock":
            emu.syncClock()
            return "syncing clock"

        case "advance":
            guard let s = args.first.flatMap(seconds) else { return "usage: advance 90 | 30m | 2h | 1d" }
            let r = emu.withCore { tg_advance_clock($0, s) }
            return r == 1 ? "clock advanced \(describeDuration(s))" : "device refused (busy) — clock will catch up later"

        case "unstop":
            emu.withCore { h in "unstop".withCString { tg_set_param(h, $0, 1) } }
            DispatchQueue.main.async { emu.stopped = nil }
            return "cleared stopped state"

        case "set":
            guard args.count >= 2 else { return "usage: set <name> <value>  (see \"params\")" }
            return set(args[0], args[1], emu: emu)

        case "unset":
            guard let k = args.first else { return "usage: unset <name>" }
            var p = Prefs.coreParams; p.removeValue(forKey: k); Prefs.coreParams = p
            if let ak = Console.appKeys[k] { Prefs.d.removeObject(forKey: ak) }
            return "\(k) back to default (core values apply after \"reload\")"

        case "params":
            var out = ["app:"]
            for (k, ak) in Console.appKeys.sorted(by: { $0.key < $1.key }) { out.append("  \(k) = \(Prefs.num(ak))") }
            out.append("flags:")
            for k in Console.flagKeys { out.append("  \(k) = \(Prefs.flag(k))") }
            out.append("core overrides (persisted):")
            for (k, v) in Prefs.coreParams.sorted(by: { $0.key < $1.key }) { out.append("  \(k) = \(v)") }
            out.append("core keys: " + Console.coreKeys.joined(separator: ", "))
            return out.joined(separator: "\n")

        case "reset":
            for ak in Console.appKeys.values { Prefs.d.removeObject(forKey: ak) }
            Prefs.coreParams = [:]
            Prefs.autorun = []
            emu.applySettings()
            return "all console tweaks and autorun cleared; run \"reload\" to apply core defaults"

        case "peek":
            guard let a = args.first.flatMap(hex) else { return "usage: peek <hexaddr> [len]" }
            let n = min(Int(args.dropFirst().first ?? "") ?? 64, 4096)
            var buf = [UInt8](repeating: 0, count: n)
            guard emu.withCore({ h in buf.withUnsafeMutableBufferPointer { tg_peek(h, a, $0.baseAddress, n) } }) != nil else { return noToy }
            return hexdump(buf, base: a)

        case "poke":
            guard args.count >= 2, let a = hex(args[0]) else { return "usage: poke <hexaddr> <hexbytes>" }
            let bytes = hexBytes(args.dropFirst().joined())
            guard !bytes.isEmpty else { return "no bytes given" }
            emu.withCore { h in bytes.withUnsafeBufferPointer { _ = tg_poke(h, a, $0.baseAddress, $0.count) } }
            return "wrote \(bytes.count) byte(s) at \(String(format: "%08X", a))"

        case "str":
            guard let a = args.first.flatMap(hex) else { return "usage: str <hexaddr>" }
            return emu.coreText { tg_read_cstr($0, a, $1, $2) } ?? noToy

        case "save":
            emu.saveNow()
            return "saved"

        case "files":
            guard let t = emu.toy else { return noToy }
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(at: ToyStore.dir(t.id), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            return items.map { u in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return "\(u.lastPathComponent)  \(ToyStore.sizeText(v?.fileSize ?? 0))  \(v?.contentModificationDate.map { "\($0)" } ?? "")"
            }.joined(separator: "\n")

        case "rm":
            guard let t = emu.toy, let name = args.first else { return "usage: rm <file>  (rom.bin can't be removed here)" }
            guard name != "rom.bin", name != "toy.json", !name.contains("/") else { return "not allowed" }
            do { try FileManager.default.removeItem(at: ToyStore.dir(t.id).appendingPathComponent(name)); return "removed \(name)" }
            catch { return "\(error.localizedDescription)" }

        case "restorebak":
            guard let t = emu.toy else { return noToy }
            let fm = FileManager.default
            var done: [String] = []
            for u in [ToyStore.snapURL(t.id), ToyStore.flashURL(t.id), ToyStore.flashMetaURL(t.id)] {
                let b = u.appendingPathExtension("bak")
                if fm.fileExists(atPath: b.path) {
                    try? fm.removeItem(at: u)
                    try? fm.moveItem(at: b, to: u)
                    done.append(u.lastPathComponent)
                }
            }
            if done.isEmpty { return "no .bak files" }
            emu.reload()
            return "restored \(done.joined(separator: ", ")) and reloaded"

        case "flag":
            guard args.count >= 2, Console.flagKeys.contains(args[0]) else { return "usage: flag <name> on|off   names: " + Console.flagKeys.joined(separator: ", ") }
            let on = ["on", "1", "true", "yes"].contains(args[1].lowercased())
            Prefs.d.set(on, forKey: args[0])
            if args[0] == "callAlerts" || args[0] == "liveInBackground" {
                if on { CareAlerts.shared.prepare() } else { CareAlerts.shared.cancelAll() }
            }
            emu.applySettings()
            return "\(args[0]) = \(on)"

        case "autorun":
            let sub = args.first?.lowercased() ?? "list"
            switch sub {
            case "add":
                let c = args.dropFirst().joined(separator: " ")
                guard !c.isEmpty else { return "usage: autorun add <command>" }
                Prefs.autorun.append(c)
                return "will run after every boot: \(c)"
            case "clear":
                Prefs.autorun = []
                return "autorun cleared"
            default:
                let a = Prefs.autorun
                return a.isEmpty ? "(autorun empty)" : a.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            }

        case "radio":
            let sub = args.first ?? "status"
            if sub == "log" {
                emu.withCore { tg_radio_enable($0, 2) }
                return (emu.coreText { tg_radio_trace($0, $1, $2) } ?? noToy) + "\n(logging on)"
            }
            if sub == "off" { emu.withCore { tg_radio_enable($0, 0) }; return "Bluetooth module removed (app connections blocked)" }
            if sub == "on" { emu.withCore { tg_radio_enable($0, 1) }; return "Bluetooth module on" }
            let r = emu.withCore { tg_radio_ready($0) } ?? 0
            return "waiting for app: \(r == 1)  (radio log | on | off)"

        case "town":
            guard let t = emu.toy else { return noToy }
            let town = Town.shared
            var x = town.state(t)
            switch args.first ?? "" {
            case "home": x.away = false; x.pending = .none; x.suitor = nil
            case "away": x.away = true; x.pending = .none
            case "reset": x = Town.State()
            default: break
            }
            DispatchQueue.main.async { town.save(x, t) }
            let v = town.visitData(t)
            return "pack: \(town.pack)  characters: \(town.ids.count)\naway: \(x.away)  pending: \(x.pending.rawValue)  partner: \(x.suitor?.name ?? "-")\nvisit data: \(v.count) bytes  weddings: \(x.married.count)"

        case "beep":
            emu.audio.beep()
            return "beep (audio running: \(emu.audio.isRunning), queued: \(emu.audio.queued))"

        case "audio":
            emu.audio.restart()
            return "audio restarted (running: \(emu.audio.isRunning), underruns: \(emu.audio.underruns))"

        case "notify":
            guard Prefs.flag("callAlerts"), Prefs.flag("liveInBackground") else { return "Notifications are disabled or Background Mode is off." }
            CareAlerts.shared.testBanner()
            return "Notification test requested; leave the app within 5 seconds."

        case "perf":
            let s = emu.stats
            return "ticks: \(s.ticks)  last tick: \(String(format: "%.2f", s.lastTickMs)) ms  frames published: \(s.frames)  audio queued: \(emu.audio.queued)  underruns: \(emu.audio.underruns)  stalls >50ms: \(emu.stalls.count) (worst \(Int(emu.stalls.maxMs)) ms)"
                + "\nemulation used \(Int(emu.perf.tickMs / max(emu.perf.dtMs, 1) * 100))% of real time (tick avg \(String(format: "%.1f", emu.perf.tickMs / Double(max(s.ticks, 1)))) ms, worst \(Int(emu.perf.maxTickMs)) ms, slow ticks >40ms: \(emu.perf.slow))"
                + "\nside polls: avg \(String(format: "%.2f", emu.perf.pollMs / Double(max(s.ticks, 1)))) ms, worst \(String(format: "%.1f", emu.perf.maxPollMs)) ms  frame publish: worst \(String(format: "%.1f", emu.perf.maxPublishMs)) ms"

        case "redraw":
            emu.forceRedraw()
            return "redrawn"

        default:
            return "unknown command \"\(cmd)\" — type help"
        }
    }

    private func set(_ name: String, _ value: String, emu: Emulator) -> String {
        let lower = value.lowercased()
        var parsed: Double? = Double(value)
        if parsed == nil && ["on", "true", "yes"].contains(lower) { parsed = 1 }
        if parsed == nil && ["off", "false", "no"].contains(lower) { parsed = 0 }
        guard let v = parsed else { return "value must be a number or on/off" }
        if let ak = Console.appKeys[name] {
            Prefs.d.set(v, forKey: ak)
            emu.applySettings()
            return "\(name) = \(v)"
        }
        if Console.coreKeys.contains(name) {
            let ok = emu.withCore { h in name.withCString { tg_set_param(h, $0, v) } } ?? 1
            guard ok == 1 else { return "core rejected \(name)" }
            var p = Prefs.coreParams; p[name] = v; Prefs.coreParams = p
            return "\(name) = \(v) (saved, re-applied at every boot)"
        }
        return "unknown parameter \(name) — type \"params\""
    }

    private func key(_ s: String) -> TGKey? {
        switch s.uppercased() { case "A": return .a; case "B": return .b; case "C": return .c; default: return nil }
    }

    private func hex(_ s: String) -> UInt32? {
        UInt32(s.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    private func hexBytes(_ s: String) -> [UInt8] {
        let clean = s.lowercased().replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit }
        var out: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex, let j = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) {
            if let b = UInt8(clean[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }

    private func seconds(_ s: String) -> Double? {
        let l = s.lowercased()
        let mult: [(String, Double)] = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
        for (suf, m) in mult where l.hasSuffix(suf) {
            if let v = Double(l.dropLast()) { return v * m }
        }
        return Double(l)
    }

    private func hexdump(_ b: [UInt8], base: UInt32) -> String {
        stride(from: 0, to: b.count, by: 16).map { o in
            let row = b[o..<min(o + 16, b.count)]
            let hx = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let asc = String(row.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08X  ", base &+ UInt32(o)) + hx + "  " + asc
        }.joined(separator: "\n")
    }

    private func daytimeReport() -> String {
        let shift = (DaytimeClock.target() - rtcNow()) / 3600
        return "Daytime Mode: \(DaytimeClock.enabled() ? "ON" : "off")  clock shift vs iPhone: \(String(format: "%+.1f", shift)) h  (one setting for all devices)"
    }

    private func devicesReport(_ emu: Emulator) -> String {
        guard let model = AppModel.current else { return "no app model" }
        var rows: [String] = []
        for t in model.toys {
            let st = Town.shared.state(t)
            let active = t.id == emu.toy?.id
            let snap = (try? FileManager.default.attributesOfItem(atPath: ToyStore.snapURL(t.id).path)) ?? [:]
            let mod = (snap[.modificationDate] as? Date).map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "no save"
            let stage = active ? (emu.withCore { h -> Int in var b: UInt8 = 0; return tg_peek(h, 0xF800D8B6, &b, 1) == 1 ? Int(b) : -1 } ?? -1) : IRLink.stage(of: t)
            rows.append("\(active ? "*" : " ") \(IRLink.tamaLabel(t, fallback: t.name)) | \(t.romName) | id \(t.id) | stage \(stage) | away \(st.away) | saved \(mod)")
        }
        return rows.joined(separator: "\n")
    }

    private func ramReport(_ emu: Emulator) -> String? {
        emu.withCore { h -> String in
            func b(_ a: UInt32) -> String { var x: UInt8 = 0; return tg_peek(h, a, &x, 1) == 1 ? String(x) : "?" }
            var nm = [UInt8](repeating: 0, count: 48)
            let nameHex = tg_peek(h, 0xF800DC30, &nm, 48) == 1 ? nm.map { String(format: "%02x", $0) }.joined() : "?"
            var kb = [UInt8](repeating: 0, count: 2)
            let keyTxt = tg_peek(h, 0xF800D864, &kb, 2) == 1 ? String(Int(kb[0]) | Int(kb[1]) << 8) : "?"
            var ram = [UInt8](repeating: 0, count: 0x18000)
            var runs: [String] = []
            if tg_peek(h, 0xF800_0000, &ram, ram.count) == 1 {
                var i = 0
                while i + 6 <= ram.count, runs.count < 40 {
                    var n = 0
                    while i + 2 * n + 2 <= ram.count, ram[i + 2 * n] == 0x08, ram[i + 2 * n + 1] >= 0x80 || ram[i + 2 * n + 1] == 0x5c { n += 1 }
                    if n >= 3 {
                        runs.append(String(format: "%08X", 0xF800_0000 + i) + " " + ram[i..<(i + 2 * n)].map { String(format: "%02x", $0) }.joined())
                        i += 2 * n
                    } else { i += 2 }
                }
            }
            var care = [UInt8](repeating: 0, count: 0x40)
            let careHex = tg_peek(h, 0xF800_D864, &care, care.count) == 1 ? care.map { String(format: "%02x", $0) }.joined() : "?"
            let careLine = "care block @F800D864 (+0x0C = attention bits): \(careHex)\n"
            let textRuns = careLine + "text-like runs in RAM (glyph codes):\n" + runs.joined(separator: "\n") + "\n"
            return textRuns + "name memory @F800DC30: \(nameHex)\nname key @F800D864: \(keyTxt) (table: 0 first Tama … Wonder Garden 2 = Clubutchi, Magic/Fairy 1 = Marupitchi)\n" + "stage \(b(0xF800D8B6))  character \(b(0xF800D8C4))  bathroom \(b(0xF800D888))  link mode \(b(0xF80178E4)) (0 playdate,1 gift,2 marry,3 travel)  gift role \(b(0xF80178BC))  travel role \(b(0xF80178C4)) (0 visit,1 invite)  clock drift \(tg_clock_drift(h)) s  asleep \(tg_is_asleep(h))"
        }
    }

    private func linkReport(_ emu: Emulator) -> String {
        "IRLink: \(IRLink.shared.stateText)\nemulator: linkBusy=\(emu.linkBusy) appWaiting=\(emu.appWaiting) holdForApp=\(emu.holdForApp) frozen=\(emu.linkFreezeUntil > CACurrentMediaTime()) loading=\(emu.loading) ticks=\(emu.stats.ticks)\nclock hold: \(String(format: "%.0f", max(0, Emulator.clockHoldUntil - CACurrentMediaTime()))) s"
    }

    /// Wake a saved device without touching it, and say what shape it is in (the way a link would find it).
    private func partnerReport(_ t: Toy) -> String {
        guard let v = Emulator.makeHandle(t).0 else { return "could not open \(t.name)" }
        defer { tg_destroy(v) }
        tg_set_volume(v, 0)
        tg_wake(v)
        for _ in 0..<60 { _ = tg_tick(v, 0.02) }
        var st: UInt8 = 0
        _ = tg_peek(v, 0xF800D8B6, &st, 1)
        return "\(t.name): stage \(st)  asleep \(tg_is_asleep(v))  drift \(tg_clock_drift(v)) s  waiting-for-infrared \(IRLink.waiting(v))\n" + IRLink.shared.picture(v)
    }

    /// The firmware log without its constant main-loop chatter.
    private func quietLog(_ emu: Emulator, _ n: Int) -> String {
        let fw = emu.coreText { tg_log($0, $1, $2) } ?? "(none)"
        let keep = fw.split(separator: "\n").filter { l in
            !(l.contains("main2()") || l.contains("TamaHotel_Azukeru") || l.contains("DispYobidashi") || l.contains("SleepOutCPU") || l.contains("KekkonUp"))
        }
        return keep.suffix(n).joined(separator: "\n")
    }

    /// Everything useful, nothing noisy. `diag full` adds the long reference blocks.
    func diagnostics(_ emu: Emulator, full: Bool = false) -> String {
        let info = Bundle.main.infoDictionary
        var lines = [
            "== TamaiOS diagnostics ==",
            "app: \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))  iOS: \(UIDevice.current.systemVersion)  \(deviceModel())  tz: \(TimeZone.current.identifier)",
            "date: \(Date())",
            "active: \(emu.toy.map { "\($0.name) / \($0.romName) / \($0.id)" } ?? "none")  stopped: \(emu.stopped.map { "\($0.code)" } ?? "no")  loading: \(emu.loading)  dark: \(emu.dark)",
            "-- daytime --", daytimeReport(),
            "-- devices --", devicesReport(emu),
            "-- link --", linkReport(emu),
            "-- active toy --", ramReport(emu) ?? "no device",
            run("screen", emu: emu),
            "-- perf --", run("perf", emu: emu),
            "-- settings --", run("params", emu: emu),
            "-- core status --", run("status", emu: emu),
            "-- firmware log (quiet, last 15) --", quietLog(emu, 15),
            "-- app log (last 150) --", run("applog 150", emu: emu),
            "-- town --", run("town", emu: emu),
        ]
        let link = LinkDiagnostics.shared.report().split(separator: "\n").dropFirst(2)
        if !link.isEmpty { lines += ["-- connection trace --"] + link.suffix(60).map(String.init) }
        if full {
            lines += ["-- files --", run("files", emu: emu),
                      "-- autorun --", run("autorun", emu: emu),
                      "-- care notifications --", CareAlerts.shared.diagnostics(),
                      "-- names --", LiveTamaName.shared.diagnostics(),
                      "-- arcade --", ArcadeDiagnostics.shared.report(),
                      "-- firmware log (last 40, raw) --", run("log 40", emu: emu)]
        }
        lines.append("== end ==")
        return lines.joined(separator: "\n")
    }

    private func deviceModel() -> String {
        var s = utsname(); uname(&s)
        return withUnsafeBytes(of: &s.machine) { raw -> String in
            let bytes = raw.prefix { b in b != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static let help = """
    Paste one command per line (# for comments). Changes persist.
    INFO
      diag [full]          what matters (devices, daytime, link, screen, logs), copied to clipboard
      devices | screen | ram | linkstate | daytime [on|off] | partner <name>
      carelog | namelog | namecheck   notification and disposable-reader diagnostics
      status | perf | params | files
      log [n]  applog [n]  firmware / app log
    TOY
      press A|B|C [ms]     keys ABBC [gap_ms]   release
      wake  sleep  restart  reload  sync  advance 2h  unstop  save
      restorebak           undo the last backup restore
      rm <file>            delete a save file (autosave.t18s, game.flash…)
    TUNING (persisted)
      set <name> <value>   unset <name>   reset
        app:  tick_ms audio_min_ms audio_max_ms gap_s autosave_s fps call_gap_s volume
        core: max_step max_behind max_catchup min_hold rewind_gap idle_skip never_sleep stop_on_bluetooth
      flag <name> on|off   soundOn haptics liveInBackground callAlerts keepAwake neverSleep showHints
      autorun add <cmd> | autorun list | autorun clear   (runs after every boot)
    MEMORY
      peek <hexaddr> [len]   poke <hexaddr> <hexbytes>   str <hexaddr>
    OTHER
      town [home|away|reset]  Town state (away/pending)
      radio [log|on|off]   beep  audio  notify  redraw  clear
    """
}