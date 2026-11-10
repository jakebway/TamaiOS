import Foundation
import UIKit
import UserNotifications
import Combine
import SwiftUI

final class CareAlerts: ObservableObject {
    static let shared = CareAlerts()
    static let revision = "care-alert-events-v1 / bathroom-candidate-v1 / hatch-events-v1 / notification-names-v1 / hidden-profile-name-v1 / sickness-alerts-v1 / growth-alerts-v1 / all-notifications-v1"
    typealias Source = CareEventPolicy.Source
    @Published private(set) var status = "Checking notification settings…"
    @Published private(set) var lastError: String?
    @Published private(set) var permissionNotRequested = false
    @Published private(set) var canShowAlerts = false
    @Published private(set) var permissionTitle = "Checking permissions"
    @Published private(set) var permissionDetail = "Reading your notification preferences."
    @Published private(set) var permissionSymbol = "bell"
    var permissionColor: Color { canShowAlerts ? .green : .secondary }
    private let prefix = "tamaios-care-"
    private var generation = 0
    private var policy = CareEventPolicy()
    private var bathroomPolicy = BathroomEventPolicy()
    private var sicknessPolicy = SicknessEventPolicy()
    private var growthPolicy = GrowthEventPolicy()
    private var growthNames: [String: String] = [:]
    private var growthProfiles: [String: String] = [:]
    private var growthIdentities: [String: String] = [:]
    private var sicknessRequests: [String: String] = [:]
    private var hatchPolicy = HatchEventPolicy(lastStages: Prefs.d.dictionary(forKey: "care.hatch.lastStages.v1") as? [String: Int] ?? [:])
    private var hatchTokens: [String: String] = [:]
    private var deathTokens: [String: String] = [:]
    private var hatchAcceptedAt: [String: Double] = [:]
    private var hatchMasks: [String: Int] = [:]
    private var inFlight: Set<String> = []
    private var lastPollAttempt: [String: Double] = [:]
    private var lastMask: [String: Int] = [:]
    private var bathroomRaw: [String: Int] = [:]
    private var bathroomRequests: [String: String] = [:]
    private var samples: [String: String] = [:]
    private var counters: [String: Int] = [:]
    private var history: [String] = []
    private var permissionSummary = "not checked"
    private var pendingCount = -1
    private var deliveredCount = -1
    private var systemSnapshotAt: Date?
    private var enabled: Bool { Prefs.flag("callAlerts") && Prefs.flag("liveInBackground") }
    private struct Event {
        let id: String
        let deviceID: String
        var name: String
        let source: Source
        let mask: Int
        let raw: Int
        let stage: Int
        let observedAt: Double
        let generation: Int
        let episode: Int
        var key: String {
            if source == .bathroom { return deviceID + ".bathroom." + String(episode) }
            if source == .sickness { return deviceID + ".sickness." + String(episode) }
            if source == .growth { return deviceID + ".growth." + String(episode) }
            return deviceID
        }
    }
    private func count(_ key: String) { counters[key, default: 0] += 1 }
    private func record(_ text: String) {
        history.append(String(format: "%.3f", ProcessInfo.processInfo.systemUptime) + " " + text)
        if history.count > 240 { history.removeFirst(history.count - 240) }
    }
    private func appState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
    func refresh() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.permissionNotRequested = settings.authorizationStatus == .notDetermined
                self.canShowAlerts = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .ephemeral)
                    && settings.alertSetting == .enabled && settings.alertStyle != .none
                self.permissionTitle = self.permissionNotRequested ? "Permission needed" : (self.canShowAlerts ? "Notifications allowed" : "Review notification settings")
                self.permissionDetail = self.permissionNotRequested ? "Allow notifications to receive all Tama alerts." : (self.canShowAlerts ? "Notifications are enabled in iPhone Settings." : "Check permissions and banners in iPhone Settings.")
                self.permissionSymbol = self.canShowAlerts ? "checkmark.circle.fill" : "bell.slash"
                self.permissionSummary = "authorization=\(settings.authorizationStatus.rawValue) alerts=\(settings.alertSetting.rawValue) style=\(settings.alertStyle.rawValue) sound=\(settings.soundSetting.rawValue)"
                self.status = self.permissionTitle; self.systemSnapshotAt = Date()
            }
        }
        center.getPendingNotificationRequests { requests in
            let total = requests.filter { $0.identifier.hasPrefix(self.prefix) }.count
            DispatchQueue.main.async { self.pendingCount = total }
        }
        center.getDeliveredNotifications { notifications in
            let total = notifications.filter { $0.request.identifier.hasPrefix(self.prefix) }.count
            DispatchQueue.main.async { self.deliveredCount = total }
        }
    }
    func prepare() {
        refresh()
        guard enabled else { cancelAll(); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            DispatchQueue.main.async {
                guard UIApplication.shared.applicationState == .active else { return }
                self.ask()
            }
        }
    }
    func ask(_ done: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if let error { self.lastError = error.localizedDescription; self.record("PERMISSION error=\(error.localizedDescription)") }
                self.refresh(); done?(granted)
            }
        }
    }
    func cancelAll() {
        generation += 1; policy.foregroundReset(); lastPollAttempt.removeAll(); inFlight.removeAll(); growthIdentities.removeAll()
        record("CLEAR requests: foreground entry or alerts disabled; state=\(appState())")
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.filter { $0.identifier.hasPrefix(self.prefix) }.map(\.identifier))
        }
        center.getDeliveredNotifications { notifications in
            center.removeDeliveredNotifications(withIdentifiers: notifications.filter { $0.request.identifier.hasPrefix(self.prefix) }.map { $0.request.identifier })
        }
    }
    func observe(mask: Int, deviceID: String, name: String, source: Source = .poll,
                 observedAt: Double = ProcessInfo.processInfo.systemUptime, raw: Int = -1, stage: Int = -1,
                 character: Int = -1, signature: String = "") {
        DispatchQueue.main.async {
            guard AppModel.current?.emu.toy?.id == deviceID else {
                self.count("skipped: stale observation device")
                self.record("SKIP observation: device changed before processing")
                return
            }
            let previousIdentity = LiveTamaName.shared.identity
            let previousVerifiedName = previousIdentity?.hasPrefix(deviceID + "." + signature + ".") == true ? LiveTamaName.shared.verifiedName : nil
            LiveTamaName.shared.observe(deviceID: deviceID, stage: stage, character: character, signature: signature)
            if source == .poll, previousIdentity != LiveTamaName.shared.identity, let previousVerifiedName {
                self.growthNames[deviceID] = previousVerifiedName
            }
            if source == .poll { self.observeGrowth(stage: stage, deviceID: deviceID, signature: signature, previousName: previousVerifiedName, observedAt: observedAt) }
            self.observeHatch(stage: stage, mask: mask, raw: raw, deviceID: deviceID, observedAt: observedAt)
            let previous = self.lastMask[deviceID]; self.lastMask[deviceID] = mask
            self.samples[deviceID] = "observed=\(String(format: "%.3f", observedAt)) source=\(source.rawValue) raw=\(raw) mask=\(mask) stage=\(stage) character=\(character) app=\(self.appState())"
            self.count(source == .sound ? "detector events" : "poll samples")
            if previous != mask { self.record("STATE mask=\(previous.map { String($0) } ?? "unknown")->\(mask) raw=\(raw) stage=\(stage)") }
            if source == .poll {
                self.observeSickness(mask: mask, raw: raw, stage: stage, deviceID: deviceID, observedAt: observedAt)
            }
            let careMask = SicknessEventPolicy.careMask(mask: mask, deviceID: deviceID)
            // Route an illness-only sound to the independently debounced sickness channel.
            // Mixed masks still retain their OTHER generic-care bits (e.g. 0x0A -> 0x02).
            if CareSupport.supports(deviceID), mask >= 0,
               mask & SicknessEventPolicy.illnessBit != 0, careMask == 0, source == .sound {
                self.count("illness sound merged into sickness")
                self.record("DETECTED illness-only sound; routed to sickness channel")
                return
            }
            self.policy.observe(mask: careMask, deviceID: deviceID)
            if source == .poll {
                guard careMask > 0 else { return }
                if self.policy.blockReason(mask: careMask, deviceID: deviceID, source: .poll, now: observedAt) == "poll same episode" {
                    self.count("poll same episode"); return
                }
                if let attempt = self.lastPollAttempt[deviceID], observedAt - attempt < 15 { return }
            } else { self.record("DETECTED raw=\(raw) careMask=\(careMask) stage=\(stage); care reason unclassified") }
            let now = ProcessInfo.processInfo.systemUptime
            if self.hatchPolicy.shouldMergeCare(deviceID: deviceID, now: now) {
                if careMask > 0 {
                    self.hatchMasks[deviceID] = careMask
                    if let accepted = self.hatchAcceptedAt[deviceID] { self.policy.accepted(mask: careMask, deviceID: deviceID, at: accepted) }
                }
                self.count("care merged into hatch"); self.record("MERGE care source=\(source.rawValue) into hatch"); return
            }
            guard self.enabled else { self.count("skipped: settings disabled"); return }
            guard UIApplication.shared.applicationState != .active else {
                self.count("skipped: foreground")
                if source == .sound { self.record("SKIP foreground; no banner expected") }; return
            }
            guard !self.inFlight.contains(deviceID) else { self.count("skipped: request in progress"); return }
            if let reason = self.policy.blockReason(mask: careMask, deviceID: deviceID, source: source, now: now) {
                self.count("skipped: " + reason)
                if source == .sound { self.record("SKIP " + reason) }; return
            }
            self.lastPollAttempt[deviceID] = now
            let event = Event(id: UUID().uuidString, deviceID: deviceID, name: LiveTamaName.shared.name,
                              source: source, mask: careMask, raw: raw, stage: stage, observedAt: observedAt,
                              generation: self.generation, episode: 0)
            self.inFlight.insert(event.key); self.attempt(event, pass: 0)
        }
    }
    private func observeHatch(stage: Int, mask: Int, raw: Int, deviceID: String, observedAt: Double) {
        guard CareSupport.supports(deviceID), (0...255).contains(stage) else { return }
        let previous = hatchPolicy.lastStages[deviceID]
        let hatched = hatchPolicy.observe(stage: stage, deviceID: deviceID, now: ProcessInfo.processInfo.systemUptime)
        if previous != stage {
            Prefs.d.set(hatchPolicy.lastStages, forKey: "care.hatch.lastStages.v1")
            record("LIFE STAGE \(previous.map { String($0) } ?? "unknown")->\(stage)")
            if stage == 0 {
                hatchTokens.removeValue(forKey: deviceID); hatchAcceptedAt.removeValue(forKey: deviceID); hatchMasks.removeValue(forKey: deviceID)
                record("HATCH ARMED next observed 0->1")
            }
        }
        guard hatched else { return }
        count("hatch transitions")
        let token = UUID().uuidString
        hatchTokens[deviceID] = token; hatchMasks[deviceID] = max(0, mask)
        record("HATCH DETECTED 0->1; consumed once; merge immediate care for 2.5s")
        guard enabled else { count("hatch skipped: settings disabled"); return }
        guard UIApplication.shared.applicationState != .active else { count("hatch skipped: foreground"); record("HATCH SKIP foreground; no later replay"); return }
        let event = Event(id: token, deviceID: deviceID, name: LiveTamaName.shared.name, source: .hatch,
                          mask: mask, raw: raw, stage: stage, observedAt: observedAt, generation: generation, episode: 0)
        guard !inFlight.contains(event.key) else { count("hatch skipped: care request in progress"); return }
        inFlight.insert(event.key); waitForHatchName(event, passes: 0)
    }
    /// The name isn't known the instant the egg hatches; the profile reader finds it a few seconds
    /// later (it runs in the background too). Hold the notification up to ~45 s so it says the name.
    private func waitForHatchName(_ event: Event, passes: Int) {
        guard event.generation == generation, enabled, isCurrent(event) else { skip(event, "hatch superseded while waiting for the name"); return }
        if let n = LiveTamaName.shared.verifiedName, !n.isEmpty {
            var e = event; e.name = n
            record("HATCH name known: \(n)")
            attempt(e, pass: 0); return
        }
        if passes >= 30 { record("HATCH name still unknown; sending without it"); attempt(event, pass: 0); return }
        if passes % 5 == 4 { LiveTamaName.shared.requestCheck() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.waitForHatchName(event, passes: passes + 1) }
    }
    /// The Tama has been gone (stage 0 while the toy is awake) for a full minute after being alive.
    func observeDeath(deviceID: String, observedAt: Double) {
        DispatchQueue.main.async {
            guard CareSupport.supports(deviceID) else { return }
            let token = UUID().uuidString
            self.deathTokens[deviceID] = token
            self.record("DEATH DETECTED stage 0 for 60 s after being alive")
            guard self.enabled else { self.count("death skipped: settings disabled"); return }
            guard UIApplication.shared.applicationState != .active else { self.count("death skipped: foreground"); return }
            let event = Event(id: token, deviceID: deviceID, name: LiveTamaName.shared.name, source: .death,
                              mask: 0, raw: -1, stage: 0, observedAt: observedAt, generation: self.generation, episode: 0)
            guard !self.inFlight.contains(event.key) else { return }
            self.inFlight.insert(event.key); self.attempt(event, pass: 0)
        }
    }
    func clearDeath(deviceID: String) { DispatchQueue.main.async { self.deathTokens.removeValue(forKey: deviceID) } }
    func observeBathroom(raw: Int, deviceID: String, observedAt: Double) {
        DispatchQueue.main.async {
            guard CareSupport.supports(deviceID) else { return }
            self.count("bathroom samples")
            let previous = self.bathroomRaw[deviceID]; self.bathroomRaw[deviceID] = raw
            self.samples[deviceID + ".bathroom"] = "observed=\(String(format: "%.3f", observedAt)) address=F800D888 raw=\(raw) app=\(self.appState())"
            if previous != raw { self.record("BATHROOM RAW \(previous.map { String($0) } ?? "unknown")->\(raw); candidate mapping") }
            guard let transition = self.bathroomPolicy.observe(raw: raw, deviceID: deviceID) else { return }
            self.record("BATHROOM CONFIRMED \(transition == .appeared ? "present" : "clean") after two matching samples")
            if transition == .cleared {
                if let identifier = self.bathroomRequests.removeValue(forKey: deviceID) { self.removeRequest(identifier) }; return
            }
            self.count("bathroom candidate episodes")
            guard self.enabled else { self.count("bathroom skipped: settings disabled"); return }
            guard UIApplication.shared.applicationState != .active else {
                self.count("bathroom skipped: foreground"); self.record("BATHROOM SKIP foreground; no later replay"); return
            }
            let event = Event(id: UUID().uuidString, deviceID: deviceID, name: LiveTamaName.shared.name,
                              source: .bathroom, mask: 0, raw: raw, stage: -1, observedAt: observedAt,
                              generation: self.generation, episode: self.bathroomPolicy.episodes[deviceID] ?? 0)
            guard !self.inFlight.contains(event.key) else { return }
            self.inFlight.insert(event.key); self.attempt(event, pass: 0)
        }
    }
    private func observeSickness(mask: Int, raw: Int, stage: Int, deviceID: String, observedAt: Double) {
        guard CareSupport.supports(deviceID) else { return }
        count("sickness samples")
        samples[deviceID + ".sickness"] = "observed=\(String(format: "%.3f", observedAt)) attention=\(mask) bit08=\(mask >= 0 && mask & 8 != 0) app=\(appState())"
        guard let transition = sicknessPolicy.observe(mask: mask, deviceID: deviceID) else { return }
        if transition == .cleared {
            record("SICKNESS CONFIRMED not sick after two poll samples; episode rearmed")
            if let identifier = sicknessRequests.removeValue(forKey: deviceID) { removeRequest(identifier) }
            return
        }
        count("sickness episodes")
        record("SICKNESS CONFIRMED attention bit 0x08 after two poll samples; independent of bathroom/generic care")
        guard enabled else { count("sickness skipped: settings disabled"); record("SICKNESS SKIP settings disabled"); return }
        guard UIApplication.shared.applicationState != .active else {
            count("sickness skipped: foreground"); record("SICKNESS SKIP foreground; no later replay for same episode"); return
        }
        let event = Event(id: UUID().uuidString, deviceID: deviceID, name: LiveTamaName.shared.name,
                          source: .sickness, mask: mask, raw: raw, stage: stage, observedAt: observedAt,
                          generation: generation, episode: sicknessPolicy.episodes[deviceID] ?? 0)
        guard !inFlight.contains(event.key) else { return }
        inFlight.insert(event.key); attempt(event, pass: 0)
    }

    private func observeGrowth(stage: Int, deviceID: String, signature: String, previousName: String?, observedAt: Double) {
        guard CareSupport.supports(deviceID), !signature.isEmpty else { return }
        if growthProfiles[deviceID] != signature {
            growthProfiles[deviceID] = signature; growthPolicy.reset(deviceID: deviceID)
            growthNames.removeValue(forKey: deviceID)
        }
        if stage == 0 { growthNames.removeValue(forKey: deviceID) }
        let oldStage = growthPolicy.stages[deviceID]
        if oldStage == stage, let previousName { growthNames[deviceID] = previousName }
        let oldName = growthNames[deviceID] ?? previousName ?? "Your Tama"
        guard let from = growthPolicy.observe(stage: stage, deviceID: deviceID), let identity = LiveTamaName.shared.identity else { return }
        let seenKey = "notification.growthSeen.v1." + identity
        guard !Prefs.d.bool(forKey: seenKey) else { return }
        Prefs.d.set(true, forKey: seenKey)
        count("growth transitions"); record("GROWTH CONFIRMED \(from)->\(stage); previous name=\(oldName)")
        guard enabled else { count("growth skipped: notifications disabled"); return }
        guard UIApplication.shared.applicationState != .active else { count("growth skipped: foreground"); record("GROWTH SKIP foreground; no delayed replay"); return }
        let eventID = UUID().uuidString
        growthIdentities[eventID] = identity
        let event = Event(id: eventID, deviceID: deviceID, name: oldName, source: .growth,
                          mask: 0, raw: -1, stage: stage, observedAt: observedAt, generation: generation,
                          episode: growthPolicy.episodes[deviceID] ?? 0)
        inFlight.insert(event.key)
        waitForGrowthName(event, passes: 0)
    }
    private func waitForGrowthName(_ event: Event, passes: Int) {
        guard event.generation == generation else { skip(event, "growth lifecycle generation changed"); return }
        guard enabled else { skip(event, "growth notifications disabled"); return }
        guard isCurrent(event) else { skip(event, "growth stage or profile identity changed"); return }
        guard UIApplication.shared.applicationState != .active else { skip(event, "growth foreground; no replay"); return }
        record("GROWTH scheduling notification; stage change confirmed")
        attempt(event, pass: 0)
    }

    private func isCurrent(_ event: Event) -> Bool {
        if event.source == .growth {
            return growthPolicy.isCurrent(deviceID: event.deviceID, stage: event.stage, episode: event.episode)
                && growthIdentities[event.id] == LiveTamaName.shared.identity
        }
        if event.source == .sickness { return sicknessPolicy.isCurrent(deviceID: event.deviceID, episode: event.episode) }
        if event.source == .bathroom { return bathroomPolicy.isCurrent(deviceID: event.deviceID, episode: event.episode) }
        if event.source == .hatch { return hatchTokens[event.deviceID] == event.id }
        if event.source == .death { return deathTokens[event.deviceID] == event.id }
        return true
    }
    private func removeRequest(_ identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier]); center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    private func skip(_ event: Event, _ reason: String) {
        if event.source == .growth { growthIdentities.removeValue(forKey: event.id) }
        if event.generation == generation { inFlight.remove(event.key) }
        count("skipped: " + reason); record("SKIP event=\(event.id) source=\(event.source.rawValue) reason=\(reason)")
    }
    private func attempt(_ event: Event, pass: Int) {
        guard event.generation == generation, enabled, isCurrent(event), AppModel.current?.emu.toy?.id == event.deviceID else {
            skip(event, "superseded, disabled, or device changed"); return
        }
        let state = UIApplication.shared.applicationState
        if state == .inactive && pass < 6 {
            if pass == 0 { record("DEFER event=\(event.id) waiting for background transition") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.attempt(event, pass: pass + 1) }; return
        }
        guard state == .background else { skip(event, "not in background"); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                guard event.generation == self.generation, self.enabled, self.isCurrent(event),
                      UIApplication.shared.applicationState == .background, AppModel.current?.emu.toy?.id == event.deviceID else {
                    self.skip(event, "state changed before scheduling"); return
                }
                let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .ephemeral || settings.authorizationStatus == .provisional
                guard allowed else { self.skip(event, "notification permission unavailable"); self.refresh(); return }
                let content = UNMutableNotificationContent()
                switch event.source {
                case .growth:
                    content.title = "\(event.name) grew up!"
                    content.body = LiveTamaName.shared.verifiedName.map { "Meet " + $0 + "." } ?? "Open TamaiOS to see your Tama’s new look."
                case .sickness: content.title = event.raw >= 0 && event.raw & 0x100 != 0 ? "\(event.name) has a toothache" : "\(event.name) is sick"; content.body = "Open TamaiOS to check on them."
                case .bathroom: content.title = "\(event.name) went to the bathroom"; content.body = "Open TamaiOS to help them clean up."
                case .death: content.title = "\(event.name) passed away"; content.body = "Open TamaiOS to start a new egg."
                case .hatch: content.title = "\(event.name) is hatching!"; content.body = "Open TamaiOS to meet your new Tama."
                default:
                    // seen on real Tamas: attention bit 1 = hungry, bit 2 = unhappy (both at once, or unknown, stays generic)
                    switch event.mask & 3 {
                    case 1: content.title = "\(event.name) is hungry!"
                    case 2: content.title = "\(event.name) is unhappy"
                    default: content.title = "\(event.name) needs you!"
                    }
                    content.body = "Open TamaiOS to check on them."
                }
                content.sound = .default; content.threadIdentifier = self.prefix + event.deviceID
                content.categoryIdentifier = event.source == .growth ? "TAMAIOS_GROWTH" : (event.source == .sickness ? "TAMAIOS_SICKNESS" : (event.source == .bathroom ? "TAMAIOS_BATHROOM" : (event.source == .hatch ? "TAMAIOS_HATCH" : "TAMAIOS_CARE")))
                content.userInfo = ["deviceID": event.deviceID, "careEventID": event.id, "careSource": event.source.rawValue]
                let request = UNNotificationRequest(identifier: self.prefix + event.deviceID + "-" + event.id, content: content, trigger: nil)
                self.record("REQUEST event=\(event.id) source=\(event.source.rawValue) name=\(event.name) raw=\(event.raw) mask=\(event.mask)")
                if event.source == .bathroom { self.bathroomRequests[event.deviceID] = request.identifier }
                if event.source == .sickness { self.sicknessRequests[event.deviceID] = request.identifier }
                UNUserNotificationCenter.current().add(request) { error in
                    DispatchQueue.main.async {
                        if event.generation == self.generation { self.inFlight.remove(event.key) }
                        if let error {
                            self.lastError = error.localizedDescription; self.count("request failed"); self.record("ERROR event=\(event.id) \(error.localizedDescription)")
                        } else if event.generation != self.generation || !self.enabled || !self.isCurrent(event) || UIApplication.shared.applicationState != .background || AppModel.current?.emu.toy?.id != event.deviceID {
                            self.removeRequest(request.identifier); self.count("cleared: state changed"); self.record("CLEAR event=\(event.id) state changed")
                        } else {
                            self.lastError = nil
                            if event.source == .hatch {
                                let now = ProcessInfo.processInfo.systemUptime; self.hatchAcceptedAt[event.deviceID] = now
                                self.policy.accepted(mask: self.hatchMasks[event.deviceID] ?? event.mask, deviceID: event.deviceID, at: now)
                                self.count("hatch request accepted")
                            } else if event.source == .bathroom { self.count("bathroom request accepted") }
                            else if event.source == .sickness { self.count("sickness request accepted") }
                            else if event.source == .growth { self.count("growth request accepted"); self.growthIdentities.removeValue(forKey: event.id) }
                            else { self.policy.accepted(mask: event.mask, deviceID: event.deviceID, at: ProcessInfo.processInfo.systemUptime) }
                            self.count("request accepted"); self.record("ACCEPTED event=\(event.id); not proof of visible banner")
                            AppModel.current?.emu.note("care notification request accepted (\(event.source.rawValue))")
                        }
                        self.refresh()
                    }
                }
            }
        }
    }
    func testBanner() {
        guard enabled else { lastError = "Enable Background Mode and Notifications first."; return }
        ask { granted in
            guard granted else { self.lastError = "Allow notifications in iPhone Settings first."; return }
            guard self.enabled else { return }
            let content = UNMutableNotificationContent()
            content.title = "TamaiOS notification test"; content.body = "Test notification. Real alerts use the currently resolved Tama name."; content.sound = .default
            let request = UNNotificationRequest(identifier: self.prefix + "test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
            UNUserNotificationCenter.current().add(request) { error in
                DispatchQueue.main.async {
                    if error == nil && !self.enabled { self.removeRequest(request.identifier) }
                    self.lastError = error?.localizedDescription; self.record(error.map { "TEST failed: " + $0.localizedDescription } ?? "TEST accepted; leave app within 5 seconds")
                    self.status = error == nil ? "Test scheduled: leave TamaiOS within 5 seconds" : "Test could not be scheduled"
                }
            }
        }
    }
    func diagnostics() -> String {
        refresh()
        var lines = [Self.revision, "settings: care=\(Prefs.flag("callAlerts")) background=\(Prefs.flag("liveInBackground")) app=\(appState())",
                     "burst filter: 2.5s; generic care, bathroom, and sickness have independent episode keys",
                     "sickness: observed Wonder Garden EN v063 attention bit 0x08; two consecutive poll samples; one alert per confirmed episode; screen dark/asleep is not used",
                     "bathroom: F800D888=1; two consecutive 1-second samples; rearm on confirmed zero",
                     "hatch: observed 0->1 once per egg; persisted stage; 2.5-second immediate-care merge",
                     "growth: two matching forward stage samples; hatching, reload baseline, age-day ticks, and resets excluded; one notification per state; wait up to 20s for new name",
                     "one Notifications switch gates every category",
                     "permission snapshot: \(permissionSummary)",
                     "system snapshot: \(systemSnapshotAt.map { String(describing: $0) } ?? "not captured") pending=\(pendingCount) delivered=\(deliveredCount)",
                     LiveTamaName.shared.diagnostics(), "Request acceptance does not prove a visible banner."]
        for key in counters.keys.sorted() { lines.append("\(key): \(counters[key] ?? 0)") }
        for key in samples.keys.sorted() { lines.append("last sample \(key): \(samples[key] ?? "")") }
        if let lastError { lines.append("last error: \(lastError)") }
        lines.append("-- recent care events (monotonic seconds) --"); lines += history
        return lines.joined(separator: "\n")
    }
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}