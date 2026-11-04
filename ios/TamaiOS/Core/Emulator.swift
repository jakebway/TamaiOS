import Foundation
import UIKit
import QuartzCore
import UserNotifications

enum Prefs {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: [
            "soundOn": true, "volume": 0.6, "haptics": true, "liveInBackground": true,
            "callAlerts": true, "keepAwake": true, "neverSleep": true, "showHints": true,
            "p.tick_ms": 4.0, "p.sleep_tick_ms": 40.0, "p.audio_min_ms": 30.0, "p.audio_max_ms": 80.0,
            "p.gap_s": 2.0, "p.autosave_s": 180.0, "p.fps": 60.0, "p.call_gap_s": 600.0,
        ])
    }
    static func num(_ k: String) -> Double { d.double(forKey: k) }
    static func flag(_ k: String) -> Bool { d.bool(forKey: k) }
    /// Emulator-core tunables set from the console, re-applied at every boot.
    static var coreParams: [String: Double] {
        get { d.dictionary(forKey: "core.params") as? [String: Double] ?? [:] }
        set { d.set(newValue, forKey: "core.params") }
    }
    /// Console commands run after every boot.
    static var autorun: [String] {
        get { d.stringArray(forKey: "autorun") ?? [] }
        set { d.set(newValue, forKey: "autorun") }
    }
}

enum TGKey: Int32 { case a = 0, b = 1, c = 2 }

struct StopInfo: Equatable {
    let code: Int32
    var title: String {
        switch code {
        case 4: return "Your device crashed"
        case 5: return "Your device froze"
        default: return "The emulator hit a problem"
        }
    }
}

/// Owns the running toy: a background thread runs the emulator core and
/// publishes the screen; everything that touches the core holds `lock`.
final class Emulator: ObservableObject {
    /// The latest screen image, read straight by the LCD layer (no SwiftUI redraw per frame).
    let frames = FrameSink()
    @Published var dark = false
    @Published var toast: String?
    /// The screen is hidden behind "Connecting…" while a link is set up (the menu would otherwise be seen going back and forth).
    @Published var linkCover = false
    /// Beeps off for a moment (the app pressing buttons by itself).
    var muteUntil = 0.0
    func setLinkCover(_ on: Bool) { DispatchQueue.main.async { if self.linkCover != on { self.linkCover = on } } }
    @Published var stopped: StopInfo?
    @Published var loading = false
    @Published var toy: Toy?
    @Published var calling = false
    /// The toy is on "WAITING FOR APP CONNECT" (Connection › App).
    @Published var appWaiting = false
    /// Setting the toy's clock while it is playing a long sound or scene can leave the buzzer stuck, so the automatic
    /// clock fix stays off briefly (about a minute) after a link or an app session.
    static var clockHoldUntil = 0.0

    let audio = AudioOut()
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var currentID: String?
    private var thread: Thread?
    private var stopFlag = false
    private var paused = false
    /// The Tama App screen is open: while the toy waits for the app, hold its
    /// time still so it doesn't give up waiting while you look around.
    var holdForApp = false
    /// A Bluetooth exchange is running (the toy must keep running then).
    var linkBusy = false
    /// While a TRAVEL link is being set up (the other device has to be woken and driven to its screen, which takes
    /// a while) the toy's own time stands still, or its CONNECTING / WAITING screen would give up and fail first.
    var linkFreezeUntil = 0.0
    /// Set once the toy was seen waiting while the app is open; cleared when the
    /// app hangs up. Keeps the hold on even while connected.
    var holdLatch = false
    /// The app just hung up: ignore the last "waiting" reading until it's polled again.
    var radioStale = false
    /// Run this many seconds of toy time as fast as possible (skips animations
    /// you aren't watching), then optionally press B.
    private var ffSeconds: Double = 0
    private var ffKeys: [TGKey] = []
    private var ffUntilWaiting = false

    /// Run `seconds` of device time at full speed, then press `keys` one by one
    /// (a second of device time apart, like a person would).
    func fastForward(_ seconds: Double, keys: [TGKey] = []) {
        ffSeconds = max(ffSeconds, seconds)
        ffKeys += keys
        wake.signal()
    }

    /// Let device time run ahead (e.g. past a FAIL message) without it being seen or heard: the screen is held on
    /// its last picture meanwhile.
    func quietSkip(_ seconds: Double) {
        muteUntil = CACurrentMediaTime() + seconds + 1.5
        setLinkCover(true)
        fastForward(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.setLinkCover(false) }
    }

    /// Hide and mute everything the toy does until `endQuiet()` (the screen stays on its last picture).
    func beginQuiet() {
        muteUntil = CACurrentMediaTime() + 30
        setLinkCover(true)
    }

    func endQuiet() {
        muteUntil = CACurrentMediaTime() + 0.4
        setLinkCover(false)
    }

    /// Answer the device's "GO BACK?" with YES: press B, A, B (a second apart) and
    /// stop as soon as the device is waiting for the app; if a press was missed
    /// (e.g. the device was busy), try the whole sequence again, up to 3 times.
    func answerGoBack() {
        ffSeconds = max(ffSeconds, 1)
        ffKeys = [.b, .a, .b]
        ffUntilWaiting = true
        wake.signal()
    }
    @Published private(set) var clockChanging = false
    var daytimeMode: Bool { DaytimeClock.enabled(toy?.id) }

    func setDaytimeMode(_ enabled: Bool) {
        guard let toy, !clockChanging, !loading, !linkBusy, !appWaiting else {
            say("Please wait a moment, then try again.")
            return
        }
        if enabled { DaytimeClock.enable(toy.id) } else { DaytimeClock.disable(toy.id) }
        clockChanging = true
        objectWillChange.send()
        let target = DaytimeClock.target(toy.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.withCore { h -> Int32 in
                tg_set_wall_clock(h, target)
                return tg_sync_clock(h, target)
            } ?? 0
            // the other devices change too, without having to be opened: each one is woken quietly from its
            // save, put on the new clock and saved again
            for other in ToyStore.list() where other.id != toy.id {
                guard let v = Emulator.makeHandle(other).0 else { continue }
                let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 44100)
                tg_set_volume(v, 0)
                let t = DaytimeClock.target(other.id)
                tg_set_wall_clock(v, t)
                for _ in 0..<4 {
                    if tg_sync_clock(v, t) == 1 { break }
                    for _ in 0..<25 { _ = tg_tick(v, 0.02); _ = tg_take_audio(v, audio, 44100) }
                }
                var out: UnsafeMutablePointer<UInt8>? = nil
                var n = 0
                if tg_snapshot(v, &out, &n) == 1, let out {
                    try? Data(bytes: out, count: n).write(to: ToyStore.snapURL(other.id), options: .atomic)
                    tg_free(out, n)
                }
                audio.deallocate()
                tg_destroy(v)
            }
            DispatchQueue.main.async {
                self.clockChanging = false
                self.saveNow()
                self.say(ok == 1
                    ? (enabled ? "Daytime Mode on for all devices. ☀️" : "Daytime Mode off. 🕒")
                    : "Clock change pending. Will retry.")
            }
        }
    }

    private var visible = true
    private var backgroundAt: Date?
    private var lastCall = Date.distantPast
    private var lastCode: Int32 = 0
    private let wake = DispatchSemaphore(value: 0)
    private let inputLock = NSLock()
    private var inputQ: [(Int32, Bool, Double)] = []
    private var toastWork: DispatchWorkItem?
    private var lastDark = false
    private var syncAnnounced = false
    private(set) var stats = (ticks: 0, lastTickMs: 0.0, frames: 0)
    /// Loop gaps over 50 ms while on screen (what a dropped frame looks like from inside).
    var stalls = (count: 0, maxMs: 0.0, notes: 0)
    private let saveQueue = DispatchQueue(label: "TamaiOS autosave", qos: .utility)
    var appLog: [String] = []

    // MARK: core access

    /// Run `body` with the core locked. Returns nil if no toy is running.
    @discardableResult
    func withCore<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return nil }
        return body(h)
    }

    func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) \(s)"
        DispatchQueue.main.async {
            self.appLog.append(line)
            if self.appLog.count > 300 { self.appLog.removeFirst(self.appLog.count - 300) }
        }
    }

    func say(_ text: String, seconds: Double = 4) {
        DispatchQueue.main.async {
            self.toastWork?.cancel()
            self.toast = text
            let w = DispatchWorkItem { [weak self] in self?.toast = nil }
            self.toastWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
        note("toast: \(text)")
    }

    // MARK: loading

    func load(_ toy: Toy, completion: ((Bool) -> Void)? = nil) {
        unload()
        holdRestoredUntil = FileManager.default.fileExists(atPath: ToyStore.lastFrameURL(toy.id).path) ? CACurrentMediaTime() + 4 : 0
        // paint the toy's own last picture straight away (before the first screen is drawn), not a black screen
        if Thread.isMainThread { self.frames.put(UIImage(contentsOfFile: ToyStore.lastFrameURL(toy.id).path)?.cgImage) }
        DispatchQueue.main.async { self.loading = true; self.toy = toy; self.stopped = nil; self.dark = false; self.lastDark = false
            // show the toy's own last picture while it wakes up (not a black screen)
            self.frames.put(UIImage(contentsOfFile: ToyStore.lastFrameURL(toy.id).path)?.cgImage) }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.boot(toy)
            DispatchQueue.main.async {
                self.loading = false
                completion?(ok)
            }
        }
    }

    /// Start a core for `toy` from its newest save (also used for the visiting device in an infrared link).
    static func makeHandle(_ toy: Toy) -> (OpaquePointer?, Double) {
        guard let rom = try? Data(contentsOf: ToyStore.romURL(toy.id)) else { return (nil, 0) }
        let snap = try? Data(contentsOf: ToyStore.snapURL(toy.id))
        let flash = try? Data(contentsOf: ToyStore.flashURL(toy.id))
        let meta = (try? String(contentsOf: ToyStore.flashMetaURL(toy.id), encoding: .utf8)) ?? ""
        var elapsed = 0.0
        let empty = Data()
        let h: OpaquePointer? = rom.withUnsafeBytes { r in
            (snap ?? empty).withUnsafeBytes { s in
                (flash ?? empty).withUnsafeBytes { f in
                    meta.withCString { m in
                        tg_create(r.bindMemory(to: UInt8.self).baseAddress, r.count,
                                  s.bindMemory(to: UInt8.self).baseAddress, s.count,
                                  f.bindMemory(to: UInt8.self).baseAddress, f.count,
                                  meta.isEmpty ? nil : m, DaytimeClock.target(toy.id), &elapsed)
                    }
                }
            }
        }
        return (h, elapsed)
    }

    private func boot(_ toy: Toy) -> Bool {
        guard (try? Data(contentsOf: ToyStore.romURL(toy.id))) != nil else {
            say("Couldn't open this device.")
            return false
        }
        let (h, elapsed) = Emulator.makeHandle(toy)
        guard let h else {
            say("This device couldn't start.", seconds: 8)
            note("tg_create returned null for \(toy.id)")
            return false
        }
        lock.lock()
        handle = h
        currentID = toy.id
        lastCode = 0
        lock.unlock()
        applySettings()
        for (k, v) in Prefs.coreParams { _ = withCore { h in k.withCString { tg_set_param(h, $0, v) } } }
        let status = coreText { tg_status($0, $1, $2) } ?? ""
        note("booted \(toy.id): \(status.split(separator: "\n").first ?? "")")
        // Daytime Mode applies to every device: put this one on the selected clock as soon as it opens,
        // not only after a few quiet seconds (switching Tamas quickly used to skip it)
        _ = withCore { h in
            let target = DaytimeClock.target(toy.id)
            tg_set_wall_clock(h, target)
            let off = tg_clock_drift(h)
            if abs(off) > 60, tg_sync_clock(h, target) == 1 {
                discardAudio(h)
                self.note("clock matched to selected time mode at start (was off by \(Int(off)) s)")
            }
        }
        DispatchQueue.main.async {
            for line in Prefs.autorun { _ = Console.shared.run(line, emu: self) }
        }
        startThread()
        return true
    }

    func unload() {
        stopThread()
        lock.lock()
        if let h = handle {
            saveLocked(h, snapshot: true)
            tg_destroy(h)
            handle = nil
        }
        lock.unlock()
    }

    func reload() {
        if let t = toy { load(t) }
    }

    func applySettings() {
        audio.muted = !Prefs.flag("soundOn")
        audio.minFill = Prefs.num("p.audio_min_ms") / 1000
        audio.maxFill = max(audio.minFill + 0.02, Prefs.num("p.audio_max_ms") / 1000)
        audio.backgroundMode = Prefs.flag("liveInBackground")
        let vol = Prefs.num("volume"), never = Prefs.flag("neverSleep")
        withCore { h in
            tg_set_volume(h, vol)
            tg_set_never_sleep(h, never ? 1 : 0)
        }
    }

    // MARK: the run loop

    private func startThread() {
        stopFlag = false
        paused = false
        audio.start()
        let t = Thread { [weak self] in self?.loop() }
        t.name = "TamaiOS emulator"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func stopThread() {
        stopFlag = true
        wake.signal()
        while let t = thread, t.isExecuting { Thread.sleep(forTimeInterval: 0.005) }
        thread = nil
    }

    /// Settings the loop reads, refreshed once a second instead of every tick.
    private struct LoopPrefs {
        var tick = 0.004, sleepTick = 0.02, gap = 2.0, autosave = 180.0, fps = 60.0
        static func read() -> LoopPrefs {
            var p = readRaw()
            // Low Power Mode: half the frame rate and fewer wake-ups
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                p.fps = min(p.fps, 30); p.tick = max(p.tick, 0.016); p.sleepTick = max(p.sleepTick, 0.08)
            }
            return p
        }
        private static func readRaw() -> LoopPrefs {
            LoopPrefs(tick: max(1, Prefs.num("p.tick_ms")) / 1000,
                      sleepTick: max(1, Prefs.num("p.sleep_tick_ms")) / 1000,
                      gap: max(0.5, Prefs.num("p.gap_s")),
                      autosave: max(30, Prefs.num("p.autosave_s")),
                      fps: max(5, Prefs.num("p.fps")))
        }
    }

    private func loop() {
        var last = CACurrentMediaTime()
        var lp = LoopPrefs.read()
        var nextPrefs = last + 1
        var nextAutosave = last + lp.autosave
        var nextWall = last
        var lastInput = last
        var nextClockFix = last + 3          // give the toy a moment after loading
        let audioBuf = UnsafeMutablePointer<Int16>.allocate(capacity: 44100)
        defer { audioBuf.deallocate() }
        var pixels = [UInt32](repeating: 0, count: 128 * 128)
        var lastPixels = [UInt32](repeating: 1, count: 128 * 128)
        var needFrame = true
        var lastPublish = 0.0
        var asleep = false
        var nextCarePoll = last
        var nextRadio = last
        var radioReady = false
        while !stopFlag {
            if holdForApp && radioReady && !radioStale { holdLatch = true }
            if !holdForApp { holdLatch = false }
            if paused || CACurrentMediaTime() < linkFreezeUntil || (holdForApp && holdLatch && !linkBusy) {
                if CACurrentMediaTime() < linkFreezeUntil {
                    // while the link is being set up, A and B presses must not pile up and fire all at once later
                    inputLock.lock(); inputQ.removeAll { $0.0 != TGKey.c.rawValue }; inputLock.unlock()
                }
                _ = wake.wait(timeout: .now() + (paused ? 0.1 : 0.03))
                last = CACurrentMediaTime()
                continue
            }
            if ffSeconds > 0 || !ffKeys.isEmpty {
                let ff = ffSeconds, keys = ffKeys, untilWaiting = ffUntilWaiting
                ffSeconds = 0
                ffKeys = []
                ffUntilWaiting = false
                lock.lock()
                if let h = handle {
                    let start = CACurrentMediaTime()
                    var t = 0.0
                    while t < ff && CACurrentMediaTime() - start < 4 {
                        _ = tg_tick(h, 0.02)
                        _ = tg_take_audio(h, audioBuf, 44100)
                        t += 0.02
                    }
                    var pressed = 0
                    var reached = false
                    attempts: for _ in 0..<(untilWaiting ? 3 : 1) {
                        for k in keys {
                            tg_press(h, k.rawValue, CACurrentMediaTime())
                            for _ in 0..<8 { _ = tg_tick(h, 0.02); _ = tg_take_audio(h, audioBuf, 44100) }
                            tg_release(h, k.rawValue)
                            pressed += 1
                            for _ in 0..<60 {
                                _ = tg_tick(h, 0.02); _ = tg_take_audio(h, audioBuf, 44100)
                                if untilWaiting && tg_radio_ready(h) != 0 { reached = true; break attempts }
                            }
                        }
                        if !untilWaiting { break }
                        // give the device a moment, then check again before retrying
                        for _ in 0..<75 {
                            _ = tg_tick(h, 0.02); _ = tg_take_audio(h, audioBuf, 44100)
                            if tg_radio_ready(h) != 0 { reached = true; break attempts }
                        }
                    }
                    note("fast-forwarded \(Int(t)) s, pressed \(pressed) keys\(untilWaiting ? (reached ? " — device is waiting" : " — device didn't answer") : "")")
                }
                lock.unlock()
                needFrame = true
                last = CACurrentMediaTime()
                continue
            }
            let now = CACurrentMediaTime()
            if now >= nextPrefs { lp = LoopPrefs.read(); nextPrefs = now + 1 }
            var dt = now - last
            last = now
            if dt > 0.05 && dt < lp.gap && visible {
                stalls.count += 1; stalls.maxMs = max(stalls.maxMs, dt * 1000)
                if stalls.notes < 12 {
                    stalls.notes += 1
                    note("stall \(Int(dt * 1000)) ms (link \(IRLink.shared.active))")
                }
            }
            inputLock.lock()
            let inputs = inputQ
            inputQ.removeAll(keepingCapacity: true)
            inputLock.unlock()
            let wallNow: Double? = now >= nextWall ? DaytimeClock.target(currentID) : nil
            if wallNow != nil { nextWall = now + 1 }

            var code: Int32 = 0, flags: UInt32 = 0, n = 0, isDark = false, published = false
            lock.lock()
            guard let h = handle else { lock.unlock(); break }
            for (key, down, wall) in inputs {
                if down { tg_press(h, key, wall) } else { tg_release(h, key) }
            }
            if let w = wallNow { tg_set_wall_clock(h, w) }
            if !inputs.isEmpty { lastInput = now }
            // Keep the toy on iPhone time even when it never sleeps: if it is more
            // than a minute off, re-set it while nobody is pressing buttons.
            if let w = wallNow, now >= nextClockFix, now - lastInput > 5, now >= Emulator.clockHoldUntil, !radioReady, !IRLink.shared.busy, !IRLink.waiting(h), tg_is_asleep(h) == 0,
               abs(tg_clock_drift(h)) > 60 {
                nextClockFix = now + 4
                let off = tg_clock_drift(h)
                if tg_sync_clock(h, w) == 1 {
                    discardAudio(h)
                    note("clock matched to selected time mode (was off by \(Int(off)) s)")
                }
            }
            if dt > lp.gap {
                // iOS paused the app: move the toy's clock on like the real one
                tg_advance_clock(h, dt)
                discardAudio(h)
                note("gap of \(String(format: "%.1f", dt)) s, clock advanced")
                dt = 0
            }
            let t0 = CACurrentMediaTime()
            // during a Bluetooth transfer the device runs 3x faster, so it's over sooner
            code = tg_tick(h, dt)   // normal speed: transfers are already instant, and turbo made animations jerky
            stats.lastTickMs = (CACurrentMediaTime() - t0) * 1000
            stats.ticks += 1
            flags = tg_take_flags(h)
            n = tg_take_audio(h, audioBuf, 44100)
            asleep = tg_is_asleep(h) != 0
            var radioChanged = false
            if now >= nextRadio {
                nextRadio = now + 0.25
                radioStale = false
                let r = tg_radio_ready(h) != 0
                if r != radioReady { radioReady = r; radioChanged = true }
                if let id = toyID { IRLink.shared.watch(emu: self, handle: h, deviceID: id, now: now) }
            }
            if flags & 1 != 0 { needFrame = true }
            // while a link is set up the screen stays on the firmware's own CONNECTING picture
            if needFrame && visible && !linkCover && now - lastPublish >= 0.7 / lp.fps {
                isDark = pixels.withUnsafeMutableBufferPointer { tg_frame(h, $0.baseAddress) } != 0
                needFrame = false
                published = true
                lastPublish = now
            }
            if flags & 4 != 0, let toy = toyID {
                // it just went to sleep and saved itself, like the real toy
                tg_flash_save(h, ToyStore.flashURL(toy).path)
            }
            if now >= nextAutosave {
                nextAutosave = now + lp.autosave
                saveLocked(h, snapshot: true, later: true)
            }
            lock.unlock()

            if now >= nextCarePoll {
                nextCarePoll = now + 1
                let sample = careSample(), bathroomRaw = bathroomSample()
                let observedAt = ProcessInfo.processInfo.systemUptime, expectedID = toyID
                DispatchQueue.main.async {
                    guard let toy = self.toy, toy.id == expectedID else { return }
                    CareAlerts.shared.observe(mask: sample.mask, deviceID: toy.id, name: toy.name,
                        source: .poll, observedAt: observedAt, raw: sample.raw, stage: sample.stage,
                        character: sample.character, signature: sample.signature)
                    CareAlerts.shared.observeBathroom(raw: bathroomRaw, deviceID: toy.id, observedAt: observedAt)
                }
            }
            if !linkCover && CACurrentMediaTime() >= muteUntil { audio.push(audioBuf, n) }      // no beeps while a link is set up
            // skip frames identical to the one on screen: saves an image allocation per redraw
            if published, isDark == lastDark, pixels == lastPixels { published = false }
            if published { lastPixels = pixels; publish(pixels, dark: isDark) }
            if radioChanged {
                let r = radioReady
                note(r ? "device is waiting for the app" : "device stopped waiting for the app")
                if !r { Emulator.clockHoldUntil = CACurrentMediaTime() + 45 }      // an app session just ended (unboxing, sounds, scenes)
                DispatchQueue.main.async { self.appWaiting = r }
            }
            if flags & 2 != 0 { careCall() }
            if flags & 16 != 0 {
                note("clock synced to selected time mode")
            }
            if code != 0 && code != lastCode { report(code) }
            lastCode = code
            // a button press wakes the loop at once; otherwise run at the tick
            // rate (slower while the toy sleeps, to save battery)
            _ = wake.wait(timeout: .now() + (asleep && !needFrame ? lp.sleepTick : lp.tick))
            // a burst of button presses leaves many wake-ups queued: take them all at once
            // instead of spinning the loop once per press
            while wake.wait(timeout: .now()) == .success {}
        }
    }

    private var toyID: String? { currentID }

    /// After opening a toy its last picture stays up until the firmware has drawn its first real picture
    /// (its first frames are blank), so there is no black flash.
    private var holdRestoredUntil: Double = 0

    private func publish(_ px: [UInt32], dark: Bool) {
        if holdRestoredUntil > 0 {
            if !dark, CACurrentMediaTime() < holdRestoredUntil, !px.contains(where: { $0 & 0xFFFFFF != 0 }) { return }
            holdRestoredUntil = 0
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: data as CFData),
              let img = CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        stats.frames += 1
        frames.put(img)
        if dark != lastDark {
            lastDark = dark
            DispatchQueue.main.async { self.dark = dark }
        }
    }

    private func report(_ code: Int32) {
        switch code {
        case 1:
            say("Bluetooth isn't supported. Nothing was changed.", seconds: 7)
        case 2:
            say("Use LINK WITH to connect. Nothing was changed.", seconds: 7)
        case 3:
            say("Bluetooth isn't supported, so the device restarted. Choose CONTINUE.", seconds: 8)
        default:
            note("core stopped with code \(code)")
            DispatchQueue.main.async { self.stopped = StopInfo(code: code) }
        }
    }

    private func careSample() -> (mask: Int, raw: Int, stage: Int, character: Int, signature: String) {
        let sample = withCore { h -> (Int, Int, Int, Int, String) in
            let mask = Int(tg_profile_attention(h))
            guard mask >= 0 else { return (mask, -1, -1, -1, "") }
            var raw: UInt8 = 0, stage: UInt8 = 0
            var character = [UInt8](repeating: 0, count: 4), signature = [UInt8](repeating: 0, count: 4)
            let rawOK = tg_peek(h, 0xF800_D870, &raw, 1), stageOK = tg_peek(h, 0xF800_D8B6, &stage, 1)
            let charOK = character.withUnsafeMutableBufferPointer { tg_peek(h, 0xF800_D8C4, $0.baseAddress, 4) }
            let sigOK = signature.withUnsafeMutableBufferPointer { tg_peek(h, 0xF800_D8B0, $0.baseAddress, 4) }
            let id = Int(UInt32(character[0]) | UInt32(character[1]) << 8 | UInt32(character[2]) << 16 | UInt32(character[3]) << 24)
            return (mask, rawOK == 1 ? Int(raw) : -1, stageOK == 1 ? Int(stage) : -1,
                    charOK == 1 ? id : -1, sigOK == 1 ? signature.map { String(format: "%02X", $0) }.joined() : "")
        }
        return (sample?.0 ?? -1, sample?.1 ?? -1, sample?.2 ?? -1, sample?.3 ?? -1, sample?.4 ?? "")
    }
    private func bathroomSample() -> Int {
        guard CareSupport.supports(toyID ?? "") else { return -1 }
        return withCore { h -> Int in
            guard tg_profile_attention(h) >= 0 else { return -1 }
            var raw: UInt8 = 0
            return tg_peek(h, 0xF800_D888, &raw, 1) == 1 ? Int(raw) : -1
        } ?? -1
    }
    private func careCall() {
        let sample = careSample(), observedAt = ProcessInfo.processInfo.systemUptime, expectedID = toyID
        note("care call detector matched; captured mask=\(sample.mask) raw=\(sample.raw) stage=\(sample.stage)")
        DispatchQueue.main.async {
            self.calling = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.calling = false }
            guard let toy = self.toy, toy.id == expectedID else { return }
            CareAlerts.shared.observe(mask: sample.mask, deviceID: toy.id, name: toy.name,
                source: .sound, observedAt: observedAt, raw: sample.raw, stage: sample.stage,
                character: sample.character, signature: sample.signature)
        }
    }

    // MARK: input

    /// Button presses never wait for the emulator: they're queued and the
    /// emulator thread is woken to handle them straight away.
    func press(_ k: TGKey) { queue(k, down: true) }
    func release(_ k: TGKey) { queue(k, down: false) }

    /// When a button was last pressed (background work waits until you pause).
    var lastKeyTime = 0.0
    private func queue(_ k: TGKey, down: Bool) {
        lastKeyTime = CACurrentMediaTime()
        inputLock.lock()
        inputQ.append((k.rawValue, down, CACurrentMediaTime()))
        inputLock.unlock()
        wake.signal()
    }

    // MARK: saving

    private func saveLocked(_ h: OpaquePointer, snapshot: Bool, later: Bool = false) {
        guard let id = toyID else { return }
        if snapshot, !linkCover, let img = frames.current(), let png = UIImage(cgImage: img).pngData() {
            try? png.write(to: ToyStore.lastFrameURL(id), options: .atomic)
        }
        if snapshot {
            var p: UnsafeMutablePointer<UInt8>? = nil
            var n = 0
            if tg_snapshot(h, &p, &n) == 1, let p {
                let d = Data(bytes: p, count: n)
                tg_free(p, n)
                let url = ToyStore.snapURL(id)
                // the periodic autosave writes the file after letting go of the core, so a frame never waits for the disk
                let write = { [weak self] in
                    do { try d.write(to: url, options: .atomic) } catch { self?.note("autosave failed: \(error)") }
                }
                if later { saveQueue.async(execute: write) } else { write() }
            }
        }
        if tg_is_asleep(h) != 0 { tg_flash_save(h, ToyStore.flashURL(id).path) }
    }

    func saveNow() {
        withCore { saveLocked($0, snapshot: true) }
    }

    /// Make a backup file of the whole toy state to share.
    func backupFile() -> URL? {
        guard let toy else { return nil }
        var url: URL?
        withCore { h in
            var p: UnsafeMutablePointer<UInt8>? = nil
            var n = 0
            if tg_snapshot(h, &p, &n) == 1, let p {
                let d = Data(bytes: p, count: n)
                tg_free(p, n)
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
                let safe = toy.name.replacingOccurrences(of: "/", with: "-")
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe) \(f.string(from: Date())).tamaios")
                try? d.write(to: u, options: .atomic)
                url = u
            }
        }
        return url
    }

    /// Restore a backup (.tamaios); false if it doesn't fit this toy's ROM.
    func restoreBackup(_ data: Data) -> Bool {
        guard let toy, let rom = try? Data(contentsOf: ToyStore.romURL(toy.id)) else { return false }
        let ok = rom.withUnsafeBytes { r in data.withUnsafeBytes { s in
            tg_check_snapshot(r.bindMemory(to: UInt8.self).baseAddress, r.count, s.bindMemory(to: UInt8.self).baseAddress, s.count)
        } } == 1
        guard ok else { return false }
        stopThread()
        lock.lock()
        if let h = handle { tg_destroy(h); handle = nil }
        lock.unlock()
        let snap = ToyStore.snapURL(toy.id)
        try? FileManager.default.removeItem(at: snap.appendingPathExtension("bak"))
        try? FileManager.default.copyItem(at: snap, to: snap.appendingPathExtension("bak"))
        try? data.write(to: snap, options: .atomic)
        // the flash save is older than the backup's own state: set it aside
        for u in [ToyStore.flashURL(toy.id), ToyStore.flashMetaURL(toy.id)] {
            try? FileManager.default.removeItem(at: u.appendingPathExtension("bak"))
            try? FileManager.default.moveItem(at: u, to: u.appendingPathExtension("bak"))
        }
        load(toy)
        return true
    }

    // MARK: toy actions

    /// Set the toy to iPhone time now. Returns whether it worked.
    @discardableResult
    func syncClock() -> Bool {
        if let id = toy?.id { DaytimeClock.disable(id) }
        objectWillChange.send()
        let now = rtcNow()
        let ok = withCore { tg_sync_clock($0, now) } ?? 0
        say(ok == 1 ? "Clock synced. 🕒" : "Couldn't set the clock now. Will retry.")
        return ok == 1
    }

    func sleepNow() {
        let ok = withCore { tg_force_sleep($0) } ?? 0
        say(ok == 1 ? "Asleep. Press any button to wake." : "Can't sleep right now.")
        saveNow()
    }

    func restart() {
        withCore { tg_restart($0) }
        DispatchQueue.main.async { self.stopped = nil }
        say("Restarted. Your Tama is kept.")
    }

    // MARK: app lifecycle

    func enterBackground() {
        visible = false
        backgroundAt = Date()
        guard handle != nil else { return }
        if Prefs.flag("liveInBackground") {
            // keep living (the audio session keeps us running); save in case iOS ends us
            saveNow()
            note("background: staying alive")
        } else {
            paused = true
            withCore { h in
                tg_force_sleep(h)
                saveLocked(h, snapshot: true)
            }
            audio.stop()
            note("background: asleep and saved")
        }
    }

    /// Throw away any sound the toy produced while its clock was being moved (a fast-forward through sleep
    /// otherwise comes out as one long beep when the app is opened again).
    private func discardAudio(_ h: OpaquePointer) {
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: 44100)
        defer { buf.deallocate() }
        for _ in 0..<20 { if tg_take_audio(h, buf, 44100) == 0 { break } }
        audio.flush()
    }

    func enterForeground() {
        visible = true
        CareAlerts.shared.cancelAll()
        CareAlerts.shared.prepare()
        guard handle != nil else { return }
        if paused {
            let away = backgroundAt.map { Date().timeIntervalSince($0) } ?? 0
            if away > 30 {
                withCore { h in tg_advance_clock(h, away); discardAudio(h) }
            } else {
                withCore { tg_wake($0) }
            }
            paused = false
        }
        audio.start()
        DispatchQueue.main.async { self.forceRedraw() }
    }

    func forceRedraw() {
        var px = [UInt32](repeating: 0, count: 128 * 128)
        let d = withCore { h in px.withUnsafeMutableBufferPointer { tg_frame(h, $0.baseAddress) } }
        if let d { publish(px, dark: d != 0) }
    }

    func willTerminate() {
        withCore { saveLocked($0, snapshot: true) }
    }

    // MARK: text from the core

    func coreText(_ f: (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Void) -> String? {
        withCore { h in
            var p: UnsafeMutablePointer<UInt8>? = nil
            var n = 0
            f(h, &p, &n)
            guard let p else { return "" }
            let s = String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
            tg_free(p, n)
            return s
        }
    }

    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return handle != nil }
}

enum Notifier {
    static func ask(_ done: ((Bool) -> Void)? = nil) { CareAlerts.shared.ask(done) }
    static func postCall(name: String) {
        guard let id = AppModel.current?.emu.toy?.id else { return }
        CareAlerts.shared.observe(mask: 16, deviceID: id, name: name)
    }
}
