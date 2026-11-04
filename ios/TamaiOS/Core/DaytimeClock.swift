import Foundation

/// Daytime Mode: one setting for every device. The clock is offset so the day starts at noon; time still
/// advances normally, rather than freezing at noon. (Older versions kept one offset per device: any of those
/// is treated as the global setting.)
enum DaytimeClock {
    private static let globalKey = "daytime.offset.all"
    private static func legacyKey(_ id: String) -> String { "daytime.offset." + id }

    private static func offset() -> Double? {
        let d = UserDefaults.standard
        if let v = d.object(forKey: globalKey) as? Double { return v }
        // migrate: the first device that had it on decides
        for (k, v) in d.dictionaryRepresentation() where k.hasPrefix("daytime.offset.") && k != globalKey {
            if let off = v as? Double {
                d.set(off, forKey: globalKey)
                return off
            }
        }
        return nil
    }
    static func enabled(_ id: String? = nil) -> Bool { offset() != nil }
    static func enable(_ id: String? = nil) {
        let now = Date()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        UserDefaults.standard.set(noon.timeIntervalSince(now), forKey: globalKey)
    }
    static func disable(_ id: String? = nil) {
        let d = UserDefaults.standard
        d.removeObject(forKey: globalKey)
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("daytime.offset.") { d.removeObject(forKey: k) }
    }
    static func target(_ id: String? = nil) -> Double {
        guard let off = offset() else { return rtcNow() }
        return rtcNow() + off
    }
}
