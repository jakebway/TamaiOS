import Foundation

struct CareEventPolicy {
    enum Source: String { case poll, sound, bathroom, hatch, sickness, growth }
    static let burstWindow = 2.5
    private(set) var notifiedEpisodes: Set<String> = []
    private var lastScheduled: [String: Double] = [:]
    mutating func observe(mask: Int, deviceID: String) { if mask == 0 { notifiedEpisodes.remove(deviceID) } }
    func blockReason(mask: Int, deviceID: String, source: Source, now: Double) -> String? {
        if source == .poll {
            if mask <= 0 { return "no positive attention state" }
            if notifiedEpisodes.contains(deviceID) { return "poll same episode" }
        }
        if let last = lastScheduled[deviceID], now - last < Self.burstWindow { return "same short burst" }
        return nil
    }
    mutating func accepted(mask: Int, deviceID: String, at: Double) {
        lastScheduled[deviceID] = at
        if mask > 0 { notifiedEpisodes.insert(deviceID) }
    }
    mutating func foregroundReset() { notifiedEpisodes.removeAll() }
}
/// The three English firmwares (Fairy v057, Magic v058, Wonder Garden v063) keep the Tama's state in the
/// same memory layout (checked against the firmware code: same base, same field offsets), so the care,
/// bathroom, sickness, hatch and growth alerts and the live name read work the same on all of them.
enum CareSupport {
    static func supports(_ deviceID: String) -> Bool {
        BundledVariant.all.contains { $0.filename == deviceID }
    }
}
struct BathroomEventPolicy {
    static let supportedDeviceID = "fw_tg18_en_v063_2020-02-13_wondergarden"
    enum Transition: Equatable { case appeared, cleared }
    private var present: [String: Bool] = [:]
    private(set) var episodes: [String: Int] = [:]
    private var candidates: [String: Bool] = [:]
    private var confirmations: [String: Int] = [:]
    mutating func observe(raw: Int, deviceID: String) -> Transition? {
        guard CareSupport.supports(deviceID) else { return nil }
        guard raw == 0 || raw == 1 else { candidates.removeValue(forKey: deviceID); confirmations.removeValue(forKey: deviceID); return nil }
        let next = raw == 1
        if candidates[deviceID] == next { confirmations[deviceID] = min(2, (confirmations[deviceID] ?? 0) + 1) }
        else { candidates[deviceID] = next; confirmations[deviceID] = 1 }
        guard confirmations[deviceID] == 2, present[deviceID] != next else { return nil }
        present[deviceID] = next
        if next { episodes[deviceID, default: 0] += 1; return .appeared }
        return .cleared
    }
    func isCurrent(deviceID: String, episode: Int) -> Bool { present[deviceID] == true && episodes[deviceID] == episode }
}
struct HatchEventPolicy {
    static let supportedDeviceID = BathroomEventPolicy.supportedDeviceID
    static let mergeWindow = 2.5
    private(set) var lastStages: [String: Int]
    private var until: [String: Double] = [:]
    init(lastStages: [String: Int] = [:]) { self.lastStages = lastStages }
    mutating func observe(stage: Int, deviceID: String, now: Double) -> Bool {
        guard CareSupport.supports(deviceID), (0...255).contains(stage) else { return false }
        let previous = lastStages[deviceID]; lastStages[deviceID] = stage
        if stage == 0 { until.removeValue(forKey: deviceID) }
        guard previous == 0, stage == 1 else { return false }
        until[deviceID] = now + Self.mergeWindow
        return true
    }
    func shouldMergeCare(deviceID: String, now: Double) -> Bool { now < (until[deviceID] ?? -.infinity) }
}
struct LiveNamePolicy {
    // Observed screenshot/dump pairing only; NOT a complete firmware character table.
    static func observedName(deviceID: String, stage: Int, character: Int) -> String? {
        deviceID == BathroomEventPolicy.supportedDeviceID && stage == 1 && character == 4 ? "Hosinokotchi" : nil
    }
    static func key(deviceID: String, stage: Int, character: Int, signature: String) -> String? {
        guard stage > 0, character >= 0, !signature.isEmpty else { return nil }
        return deviceID + "." + signature + "." + String(stage) + "." + String(character)
    }
    static func clean(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map { Character(String($0)) }.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
struct ForegroundPlaybackPolicy {
    static func allowed(soundEnabled: Bool, foreground: Bool) -> Bool { soundEnabled && foreground }
}
struct ProbeTextLine {
    let text: String
    let confidence: Double
    let midY: Double
}
struct NameRecognitionPolicy {
    static func normalized(_ value: String) -> String {
        value.uppercased().filter { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }
    }
    static func candidate(lines: [ProbeTextLine], owner: String) -> String? {
        let ownerKey = normalized(owner)
        guard ownerKey.count >= 2 else { return nil }
        let headers = lines.filter {
            let text = normalized($0.text)
            return $0.confidence >= 0.40 && (text.hasPrefix(ownerKey) || text == ownerKey || text == ownerKey + "S")
        }
        var names: Set<String> = []
        for header in headers {
            for line in lines where line.confidence >= 0.50 {
                let distance = header.midY - line.midY
                let text = normalized(line.text)
                guard distance > 0.02, distance < 0.35,
                      (5...32).contains(text.count),
                      text.hasSuffix("TCHI"),
                      text != ownerKey, text != ownerKey + "S",
                      !text.hasPrefix(ownerKey),
                      text.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
                names.insert(text.lowercased().capitalized)
            }
        }
        return names.count == 1 ? names.first : nil
    }
    static func agreed(_ first: String?, _ second: String?) -> String? {
        guard let first, let second, normalized(first) == normalized(second) else { return nil }
        return first
    }
}


// Observed Wonder Garden EN v063 skull/illness state: attention bit 0x08.
// Never infer illness from LCD dark/asleep state. Other firmwares retain generic care handling.
struct SicknessEventPolicy {
    static let supportedDeviceID = BathroomEventPolicy.supportedDeviceID
    static let illnessBit = 0x08
    enum Transition: Equatable { case becameSick, cleared }
    private var confirmed: [String: Bool] = [:]
    private var candidates: [String: Bool] = [:]
    private var confirmations: [String: Int] = [:]
    private(set) var episodes: [String: Int] = [:]
    static func careMask(mask: Int, deviceID: String) -> Int {
        guard CareSupport.supports(deviceID), mask >= 0 else { return mask }
        return mask & ~illnessBit
    }
    mutating func observe(mask: Int, deviceID: String) -> Transition? {
        guard CareSupport.supports(deviceID), mask >= 0 else {
            candidates.removeValue(forKey: deviceID)
            confirmations.removeValue(forKey: deviceID)
            return nil
        }
        let sick = (mask & Self.illnessBit) != 0
        if candidates[deviceID] == sick { confirmations[deviceID] = min(2, (confirmations[deviceID] ?? 0) + 1) }
        else { candidates[deviceID] = sick; confirmations[deviceID] = 1 }
        guard confirmations[deviceID] == 2, confirmed[deviceID] != sick else { return nil }
        confirmed[deviceID] = sick
        if sick { episodes[deviceID, default: 0] += 1; return .becameSick }
        return .cleared
    }
    func isCurrent(deviceID: String, episode: Int) -> Bool {
        confirmed[deviceID] == true && episodes[deviceID] == episode
    }
}


struct GrowthEventPolicy {
    static let supportedDeviceID = BathroomEventPolicy.supportedDeviceID
    private(set) var stages: [String: Int] = [:]
    private var candidates: [String: Int] = [:]
    private var counts: [String: Int] = [:]
    private(set) var episodes: [String: Int] = [:]
    mutating func observe(stage: Int, deviceID: String) -> Int? {
        guard CareSupport.supports(deviceID), (0...4).contains(stage) else {
            candidates.removeValue(forKey: deviceID); counts.removeValue(forKey: deviceID); return nil
        }
        if candidates[deviceID] == stage { counts[deviceID] = min(2, (counts[deviceID] ?? 0) + 1) }
        else { candidates[deviceID] = stage; counts[deviceID] = 1 }
        guard counts[deviceID] == 2, stages[deviceID] != stage else { return nil }
        let previous = stages[deviceID]; stages[deviceID] = stage
        guard let previous, previous > 0, stage > previous else { return nil }
        episodes[deviceID, default: 0] += 1
        return previous
    }
    mutating func reset(deviceID: String) {
        stages.removeValue(forKey: deviceID); candidates.removeValue(forKey: deviceID)
        counts.removeValue(forKey: deviceID); episodes.removeValue(forKey: deviceID)
    }
    func isCurrent(deviceID: String, stage: Int, episode: Int) -> Bool {
        stages[deviceID] == stage && episodes[deviceID] == episode
    }
}