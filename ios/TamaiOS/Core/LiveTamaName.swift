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
            if self.running || emu.linkBusy || emu.holdForApp || emu.appWaiting || ArcadeDiagnostics.shared.report().contains("state: active") {
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
        if !probeName.isEmpty { next = probeName; detail = "Two agreeing profile OCR reads on a disposable emulator copy" }
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