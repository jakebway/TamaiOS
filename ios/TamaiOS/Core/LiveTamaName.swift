import Foundation
import Combine
import UIKit

final class LiveTamaName: ObservableObject {
    static let shared = LiveTamaName()
    @Published private(set) var name = "Your Tama"
    @Published private(set) var source = "No current character sample"
    @Published private(set) var identity: String? = nil
    @Published private(set) var probeStatus = "Waiting for a stable living Tama"
    private var deviceID = ""
    private var stage = -1
    private var character = -1
    private var signature = ""
    private var probeName = ""
    private var attempts: [String: Int] = [:]
    private var nextCheck: [String: Double] = [:]
    private var lastStart = -Double.infinity
    private var scheduled: UUID?
    private var running = false
    private var captureMS = 0.0
    private var workMS = 0.0
    private var trace: [String] = []
    /// The last verified Tama name seen on a device (also for devices that aren't running now).
    static func savedName(_ deviceID: String) -> String? {
        let n = Prefs.d.string(forKey: "tamaName.v1." + deviceID) ?? ""
        return n.isEmpty ? nil : n
    }
    /// Name table location inside each firmware's flash (file offset; flash maps at 0x20000000).
    private static let tableBase: [String: UInt32] = [
        "wondergarden": 0x1c12fc, "magic": 0x1bd9bc, "fairy": 0x1bbf78]
    /// Reads the Tama's name straight from firmware memory: the key at F800D864 indexes the firmware's own name table.
    /// Returns nil for anything unexpected so the screen reader stays the fallback.
    /// The profile picture decoded from firmware data (built-in Tamas). Transparent PNG, trimmed to the picture.
    static func spritePNG(core h: OpaquePointer, deviceID: String) -> Data? {
        let rom = deviceID.contains("wondergarden") ? 0 : deviceID.contains("magic") ? 1 : deviceID.contains("fairy") ? 2 : -1
        guard rom >= 0 else { return nil }
        var px = [UInt32](repeating: 0, count: 64 * 64)
        let r = tg_profile_sprite(h, Int32(rom), &px)
        guard r > 0 else { return nil }
        let w = Int(r >> 8), hh = Int(r & 255)
        var rows = [UInt32]()
        for y in 0..<hh { rows += px[(y * 64)..<(y * 64 + w)] }
        let data = rows.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: hh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: img).pngData()
    }
    enum Direct: Equatable { case name(String), unnamed, unknown }
    static func directName(core h: OpaquePointer, deviceID: String) -> String? {
        if case .name(let n) = direct(core: h, deviceID: deviceID) { return n }
        return nil
    }
    /// What the firmware says right now. Generation (F800D89E) 1 = built-in Tama (name table), 2+ = a name you typed (F800DADE).
    static func direct(core h: OpaquePointer, deviceID: String) -> Direct {
        guard let base = tableBase.first(where: { deviceID.contains($0.key) })?.value else { return .unknown }
        var st: UInt8 = 0, gen: UInt8 = 0
        guard tg_peek(h, 0xF800D8B6, &st, 1) == 1, tg_peek(h, 0xF800D89E, &gen, 1) == 1 else { return .unknown }
        if st < 1 { return .unknown }                       // still an egg
        if gen >= 2 {
            var cn = [UInt8](repeating: 0, count: 16)
            guard tg_peek(h, 0xF800DADE, &cn, 16) == 1 else { return .unknown }
            if cn[0] == 0 && cn[1] == 0 { return .unnamed }  // hatched but not named yet
            var typed = ""
            for i in stride(from: 0, to: 16, by: 2) {
                let c = Int(cn[i]) << 8 | Int(cn[i + 1])
                if c == 0 { break }
                if c == 0x86c { typed += " "; continue }
                guard (0x8e0...0x8f9).contains(c), let u = UnicodeScalar(c - 0x87f) else { return .unknown }
                typed.unicodeScalars.append(u)
            }
            typed = typed.trimmingCharacters(in: .whitespaces)
            return typed.isEmpty ? .unnamed : .name(typed.prefix(1).uppercased() + typed.dropFirst() + "tchi")
        }
        var kb = [UInt8](repeating: 0, count: 2)
        guard tg_peek(h, 0xF800D864, &kb, 2) == 1 else { return .unknown }
        let key = UInt32(kb[0]) | UInt32(kb[1]) << 8
        guard key < 200 else { return .unknown }
        var ent = [UInt8](repeating: 0, count: 8)
        guard tg_peek(h, 0x2000_0000 + base + key * 8, &ent, 8) == 1 else { return .unknown }
        let k = UInt32(ent[0]) | UInt32(ent[1]) << 8
        let ptr = UInt32(ent[4]) | UInt32(ent[5]) << 8 | UInt32(ent[6]) << 16 | UInt32(ent[7]) << 24
        guard k == key, ptr >= 0x2000_0000, ptr < 0x2100_0000 else { return .unknown }
        var buf = [UInt8](repeating: 0, count: 48)
        guard tg_peek(h, ptr, &buf, 48) == 1 else { return .unknown }
        var out = ""
        for i in stride(from: 0, to: 46, by: 2) {
            let c = Int(buf[i]) << 8 | Int(buf[i + 1])
            if c == 0 { break }
            guard (0x8e0...0x8f9).contains(c), let u = UnicodeScalar(c - 0x87f) else { return .unknown }
            out.unicodeScalars.append(u)
        }
        return out.count >= 3 ? .name(out.prefix(1).uppercased() + out.dropFirst()) : .unknown
    }
    /// Live feed from the emulator loop (several times a second): the name always follows the firmware, never a stale one.
    func applyDirect(_ d: Direct, deviceID: String) {
        guard deviceID == self.deviceID || self.deviceID.isEmpty else { return }
        switch d {
        case .name(let n):
            if directName != n || probeName != n {
                directName = n; probeName = n
                if !deviceID.isEmpty { Prefs.d.set(n, forKey: "tamaName.v1." + deviceID) }
                if let key = identity { Prefs.d.set(n, forKey: "notification.probeName.v1." + key) }
                resolve()
            }
        case .unnamed:
            if directName != "" || !probeName.isEmpty {
                directName = ""; probeName = ""
                if !deviceID.isEmpty { Prefs.d.removeObject(forKey: "tamaName.v1." + deviceID) }
                if let key = identity { Prefs.d.removeObject(forKey: "notification.probeName.v1." + key) }
                resolve()
            }
        case .unknown:
            directName = nil
        }
    }
    private var directName: String? = nil
    var verifiedName: String? { probeName.isEmpty ? nil : probeName }
    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let key = self.identity, ProcessInfo.processInfo.systemUptime - self.lastStart >= 15 else { return }
            self.beginCycle(key: key, delay: 0.8)
        }
    }
    func observe(deviceID: String, stage: Int, character: Int, signature: String) {
        self.deviceID = deviceID; self.stage = stage; self.character = character; self.signature = signature
        let key = LiveNamePolicy.key(deviceID: deviceID, stage: stage, character: character, signature: signature)
        if identity != key {
            identity = key; scheduled = nil
            // Legacy notification.currentName overrides are deliberately ignored.
            probeName = key.flatMap { Prefs.d.string(forKey: "notification.probeName.v1." + $0) } ?? ""
            probeStatus = key == nil ? "Waiting for hatch" : "State changed: verifying the displayed profile name"
            resolve()
            if let key { beginCycle(key: key, delay: 0.8) }
        } else {
            resolve()
            if let key, UIApplication.shared.applicationState == .active,
               ProcessInfo.processInfo.systemUptime >= (nextCheck[key] ?? 0) {
                beginCycle(key: key, delay: 0.8)
            }
        }
    }
    func requestCheck() {
        guard let identity else { return }
        beginCycle(key: identity, delay: 0.8)
    }
    private func beginCycle(key: String, delay: Double) {
        guard identity == key, scheduled == nil, !running,
              CareSupport.supports(deviceID) else { return }
        attempts[key] = 0
        nextCheck[key] = ProcessInfo.processInfo.systemUptime + 60
        schedule(key: key, delay: delay)
    }
    private func schedule(key: String, delay: Double) {
        guard CareSupport.supports(deviceID), identity == key,
              scheduled == nil, (attempts[key] ?? 0) < 3 else { return }
        let token = UUID(); scheduled = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.scheduled == token, self.identity == key else { return }
            self.scheduled = nil
            guard let emu = AppModel.current?.emu, emu.toy?.id == self.deviceID, !emu.loading else {
                self.probeStatus = "Waiting for emulator availability"; self.schedule(key: key, delay: 5); return
            }
            let id = self.deviceID
            if let direct = emu.withCore({ LiveTamaName.directName(core: $0, deviceID: id) }) ?? nil {
                if direct != self.probeName {
                    self.probeName = direct
                    Prefs.d.set(direct, forKey: "notification.probeName.v1." + key)
                    emu.note("name read from firmware memory: " + direct)
                }
                self.probeStatus = "Name read directly from firmware memory"
                self.nextCheck[key] = ProcessInfo.processInfo.systemUptime + 60
                self.resolve()
                return
            }
            if self.directName == "" { self.probeStatus = "Waiting for you to name this Tama"; return }
            if self.running || emu.linkBusy || IRLink.shared.busy || emu.holdForApp || emu.appWaiting || ArcadeDiagnostics.shared.report().contains("state: active") {
                self.probeStatus = "Deferred during a probe, connection, or arcade round"
                self.schedule(key: key, delay: 5); return
            }
            self.running = true; self.lastStart = ProcessInfo.processInfo.systemUptime
            self.attempts[key, default: 0] += 1
            self.probeStatus = "Automatically reading a disposable copy; no live menu presses"
            let expectedDevice = self.deviceID, expectedStage = self.stage, expectedCharacter = self.character
            let expectedSignature = UInt32(self.signature, radix: 16) ?? 0
            ProfileNameReader.shared.read(emu: emu, key: key, spriteURL: ToyStore.spriteURL(self.deviceID)) { result in
                self.running = false
                self.captureMS = result.captureMS; self.workMS = result.workMS; self.trace = result.trace
                let matches = emu.withCore { tg_name_identity_matches($0, Int32(expectedStage), UInt32(clamping: expectedCharacter), expectedSignature) } ?? 0
                guard self.identity == key, emu.toy?.id == expectedDevice, matches == 1 else {
                    self.probeStatus = "Discarded stale name result"
                    if let current = self.identity { self.beginCycle(key: current, delay: 0.8) }; return
                }
                if let value = result.name, !value.isEmpty {
                    self.probeName = value
                    Prefs.d.set(value, forKey: "notification.probeName.v1." + key)
                    self.nextCheck[key] = ProcessInfo.processInfo.systemUptime + 60
                    self.probeStatus = "Profile name verified; automatic foreground revalidation in about 60 seconds"
                    emu.note("automatic profile name verified: " + value)
                    self.resolve()
                } else {
                    self.probeStatus = result.detail + " (attempt \(self.attempts[key] ?? 0)/3)"
                    emu.note("automatic profile name reader: " + result.detail)
                    if (self.attempts[key] ?? 0) < 3 { self.schedule(key: key, delay: (self.attempts[key] ?? 0) == 1 ? 4 : 12) }
                    else { self.nextCheck[key] = ProcessInfo.processInfo.systemUptime + 30 }
                }
            }
        }
    }
    private func resolve() {
        let next: String, detail: String
        if directName == "" { next = "Your Tama"; detail = "Waiting for you to name this Tama" }
        else if !probeName.isEmpty { next = probeName; detail = directName != nil ? "Read live from firmware memory" : "Two agreeing profile OCR reads on a disposable emulator copy" }
        else if let observed = LiveNamePolicy.observedName(deviceID: deviceID, stage: stage, character: character) {
            next = observed; detail = "Observed baby mapping fallback while automatic profile verification is pending"
        } else { next = "Your Tama"; detail = "Waiting for a verified profile name; no owner or old-visitor substitution" }
        if !probeName.isEmpty, !deviceID.isEmpty { Prefs.d.set(probeName, forKey: "tamaName.v1." + deviceID) }
        if name != next { name = next }; if source != detail { source = detail }
    }
    func diagnostics() -> String {
        var lines = ["hidden-profile-name-v1 / automatic-names-v2", "display name: \(name)", "source: \(source)",
                     "stage=\(stage) candidate character=\(character) profile signature=\(signature)",
                     "probe: \(probeStatus)", "last capture ms=\(Int(captureMS)) total work ms=\(Int(workMS))",
                     "Automatic: state changes, uncached startup, app return (15s debounce), and 60s foreground revalidation for custom names with unchanged IDs; failed cycles retry after 120s. No editable override."]
        lines += trace
        return lines.joined(separator: "\n")
    }
}