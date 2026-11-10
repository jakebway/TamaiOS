import Foundation

struct SceneReleasePolicy {
    private var deviceID = ""
    private var observedDeadline = 0.0
    private var firstRoomAt = 0.0
    private var lastRoomAt: Double? = nil
    private var samples = 0

    mutating func observe(now: Double, deadline: Double, deviceID: String,
                          operationBusy: Bool, room: Bool, waiting: Bool) -> String? {
        guard now.isFinite, deadline.isFinite, !operationBusy, deadline > 0 else {
            self = Self(); return nil
        }
        if now >= deadline { self = Self(); return "fallback deadline" }
        guard room, !waiting, !deviceID.isEmpty else { self = Self(); return nil }
        if self.deviceID != deviceID || observedDeadline != deadline || lastRoomAt == nil
            || now < lastRoomAt! || now - lastRoomAt! > 0.75 {
            self = Self()
            self.deviceID = deviceID; observedDeadline = deadline; firstRoomAt = now
        }
        lastRoomAt = now; samples += 1
        guard samples >= 3, now - firstRoomAt >= 0.5 else { return nil }
        self = Self()
        return "confirmed room"
    }
}
