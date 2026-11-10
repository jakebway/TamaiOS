import Foundation

@main
struct SceneReleaseAudit {
    static var checks = 0
    static func expect(_ ok: Bool, _ label: String) {
        checks += 1
        guard ok else { fatalError("SCENE RELEASE FAIL: " + label) }
    }
    static func main() {
        var p = SceneReleasePolicy()
        func sample(_ time: Double, _ room: Bool = true, _ waiting: Bool = false,
                    _ busy: Bool = false, _ id: String = "a", _ deadline: Double = 132) -> String? {
            p.observe(now: time, deadline: deadline, deviceID: id, operationBusy: busy, room: room, waiting: waiting)
        }
        expect(sample(110) == nil, "first room sample stays locked")
        expect(sample(110.25) == nil, "second room sample stays locked")
        expect(sample(110.5) == "confirmed room", "stable room releases early")
        p = SceneReleasePolicy()
        expect(sample(110) == nil && sample(110.25, false) == nil, "non-room resets confirmation")
        expect(sample(110.5) == nil && sample(110.75) == nil && sample(111) == "confirmed room", "room must settle again")
        p = SceneReleasePolicy()
        expect(sample(110) == nil && sample(110.25, true, true) == nil, "radio waiting resets confirmation")
        expect(sample(110.5) == nil && sample(110.75) == nil && sample(111) == "confirmed room", "waiting did not unlock")
        p = SceneReleasePolicy()
        expect(sample(110) == nil && sample(110.25, true, false, true) == nil, "active operation resets confirmation")
        expect(sample(110.5) == nil && sample(110.75) == nil && sample(111) == "confirmed room", "cleanup must finish before confirmation")
        p = SceneReleasePolicy()
        expect(sample(110) == nil && sample(110.25, true, false, false, "b") == nil, "device change restarts confirmation")
        expect(sample(110.5, true, false, false, "b") == nil && sample(110.75, true, false, false, "b") == "confirmed room", "new device needs own stable room")
        p = SceneReleasePolicy()
        expect(sample(110) == nil && sample(110.25) == nil && sample(112) == nil, "long gap restarts confirmation")
        expect(sample(112.25) == nil && sample(112.5) == "confirmed room", "fresh samples after gap")
        p = SceneReleasePolicy()
        expect(sample(110) == nil && sample(110.125) == nil && sample(110.25) == nil, "fast samples do not bypass half-second minimum")
        expect(sample(110.5) == "confirmed room", "minimum duration reached")
        p = SceneReleasePolicy()
        expect(sample(110) == nil && sample(110.25, true, false, false, "a", 140) == nil, "new scene deadline resets confirmation")
        expect(sample(110.5, true, false, false, "a", 140) == nil && sample(110.75, true, false, false, "a", 140) == "confirmed room", "new scene settles independently")
        p = SceneReleasePolicy()
        expect(sample(110) == nil && sample(109) == nil, "backwards time restarts confirmation")
        expect(sample(109.25) == nil && sample(109.5) == "confirmed room", "new monotonic streak required")
        p = SceneReleasePolicy()
        expect(sample(132, false) == "fallback deadline", "unknown screen retains bounded fallback")
        expect(sample(133, true, false, true) == nil, "deadline cannot override active operation")
        expect(sample(110, true, false, false, "a", 0) == nil, "no quiet hold means no release")
        expect(sample(110, true, false, false, "") == nil, "empty device cannot confirm room")
        print("SCENE RELEASE CHECKS PASSED: " + String(checks))
        print("Scope: actual release policy with synthetic observations; not firmware room-map validation, worker concurrency, save success or phone timing")
    }
}
