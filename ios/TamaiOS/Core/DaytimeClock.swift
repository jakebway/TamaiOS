import Foundation

/// A per-device offset: time advances normally, rather than freezing at noon.
enum DaytimeClock {
    private static func key(_ id: String) -> String { "daytime.offset." + id }
    static func enabled(_ id: String?) -> Bool {
        guard let id else { return false }
        return UserDefaults.standard.object(forKey: key(id)) != nil
    }
    static func enable(_ id: String) {
        let now = Date()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        UserDefaults.standard.set(noon.timeIntervalSince(now), forKey: key(id))
    }
    static func disable(_ id: String) { UserDefaults.standard.removeObject(forKey: key(id)) }
    static func target(_ id: String?) -> Double {
        guard let id, enabled(id) else { return rtcNow() }
        return rtcNow() + UserDefaults.standard.double(forKey: key(id))
    }
}
