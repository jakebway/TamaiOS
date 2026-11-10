import Foundation

@main
struct PolicyAudit {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("POLICY FAILURE: \(message)") }
    }
    static func main() {
        for variant in BundledVariant.all {
            let id = variant.filename
            check(CareSupport.supports(id), "bundled firmware support")
            var care = CareEventPolicy()
            check(care.blockReason(mask: 1, deviceID: id, source: .poll, now: 0) == nil, "initial care")
            care.accepted(mask: 1, deviceID: id, at: 0)
            check(care.blockReason(mask: 1, deviceID: id, source: .poll, now: 10) != nil, "same episode suppression")
            care.observe(mask: 0, deviceID: id)
            check(care.blockReason(mask: 1, deviceID: id, source: .poll, now: 10) == nil, "care rearm")
            check(care.blockReason(mask: 0, deviceID: id, source: .sound, now: 1) != nil, "burst suppression")
            check(care.blockReason(mask: 0, deviceID: id, source: .sound, now: 3) == nil, "later sound")
            var bathroom = BathroomEventPolicy()
            check(bathroom.observe(raw: 1, deviceID: id) == nil, "bathroom debounce")
            check(bathroom.observe(raw: 1, deviceID: id) == .appeared, "bathroom appearance")
            check(bathroom.observe(raw: 1, deviceID: id) == nil, "no bathroom repeat")
            check(bathroom.isCurrent(deviceID: id, episode: 1), "bathroom episode")
            check(bathroom.observe(raw: 0, deviceID: id) == nil, "clear debounce")
            check(bathroom.observe(raw: 0, deviceID: id) == .cleared, "bathroom clear")
            check(!bathroom.isCurrent(deviceID: id, episode: 1), "stale bathroom episode")
            var sick = SicknessEventPolicy()
            check(sick.observe(mask: 8, deviceID: id) == nil, "illness debounce")
            check(sick.observe(mask: 8, deviceID: id) == .becameSick, "illness confirmation")
            check(SicknessEventPolicy.careMask(mask: 10, deviceID: id) == 2, "mixed illness/care mask")
            check(sick.observe(mask: 0, deviceID: id) == nil, "illness clear debounce")
            check(sick.observe(mask: 0, deviceID: id) == .cleared, "illness clear")
            var hatch = HatchEventPolicy()
            check(!hatch.observe(stage: 0, deviceID: id, now: 0), "egg baseline")
            check(!hatch.observe(stage: 1, deviceID: id, now: 1), "transient zero not hatch")
            check(!hatch.observe(stage: 0, deviceID: id, now: 2), "egg arm")
            check(hatch.observe(stage: 1, deviceID: id, now: 32), "30 second egg transition")
            check(hatch.shouldMergeCare(deviceID: id, now: 33), "hatch merge")
            check(!hatch.shouldMergeCare(deviceID: id, now: 35), "hatch merge expiry")
            check(!hatch.observe(stage: 1, deviceID: id, now: 36), "no hatch replay")
            var growth = GrowthEventPolicy()
            check(growth.observe(stage: 1, deviceID: id) == nil, "growth baseline sample")
            check(growth.observe(stage: 1, deviceID: id) == nil, "growth baseline confirmation")
            check(growth.observe(stage: 2, deviceID: id) == nil, "growth debounce")
            check(growth.observe(stage: 2, deviceID: id) == 1, "growth transition")
            check(growth.isCurrent(deviceID: id, stage: 2, episode: 1), "growth identity")
            growth.reset(deviceID: id)
            check(!growth.isCurrent(deviceID: id, stage: 2, episode: 1), "growth reset")
            let first = LiveNamePolicy.key(deviceID: id, stage: 1, character: 4, signature: "generation-a")
            let second = LiveNamePolicy.key(deviceID: id, stage: 1, character: 4, signature: "generation-b")
            check(first != nil && first != second, "generation name isolation")
            check(LiveNamePolicy.key(deviceID: id, stage: 0, character: 4, signature: "a") == nil, "no egg name identity")
        }
        check(!CareSupport.supports("unknown"), "unknown firmware unsupported")
        check(SicknessEventPolicy.careMask(mask: 8, deviceID: "unknown") == 8, "unknown mask preserved")
        check(!ForegroundPlaybackPolicy.allowed(soundEnabled: true, foreground: false), "background muted")
        check(!ForegroundPlaybackPolicy.allowed(soundEnabled: false, foreground: true), "sound disabled")
        check(ForegroundPlaybackPolicy.allowed(soundEnabled: true, foreground: true), "foreground sound")
        check(LiveNamePolicy.clean("  Motchi\n") == "Motchi", "name cleaning")
        print("POLICY CHECKS PASSED: \(checks)")
        print("Scope: actual policy source; not firmware-bit validation or iOS notification delivery")
    }
}
