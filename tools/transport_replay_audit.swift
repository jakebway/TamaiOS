import Foundation

@main
struct TransportAudit {
    static func main() {
        let cases: [(String, [[UInt8]], [UInt8]?)] = [
            ("valid three-byte reply", [[0xF0,0x0C,0,0],[0xF0,0x0D,3,0],[1,2,3],[0xF0,0x4D]], [1,2,3]),
            ("valid split payload", [[0xF0,0x0D,3,0],[1],[2,3],[0xF0,0x4D]], [1,2,3]),
            ("valid zero-length reply", [[0xF0,0x0D,0,0],[0xF0,0x4D]], []),
            ("truncated payload must reject", [[0xF0,0x0D,3,0],[1],[0xF0,0x4D]], nil),
            ("oversized payload must reject", [[0xF0,0x0D,3,0],[1,2,3,4],[0xF0,0x4D]], nil),
            ("short length header must reject", [[0xF0,0x0D,3],[0xF0,0x4D]], nil),
            ("acknowledged incomplete timeout must reject", [[0xF0,0x0C,0,0],[0xF0,0x0D,3,0],[1]], nil),
            ("missing reply must reject", [], nil)
        ]
        var failures = 0
        for (name, input, expected) in cases {
            let replay = TransportReplay(input)
            do {
                let result = try replay.answer(firstTimeout: 0.001, idleTimeout: 0.001)
                let passed = expected.map { $0 == result } ?? false
                print("TRANSPORT \(passed ? "PASS" : "FAIL"): \(name); returned bytes=\(result.count)")
                if !passed { failures += 1 }
            } catch {
                let passed = expected == nil
                print("TRANSPORT \(passed ? "PASS" : "FAIL"): \(name); rejected")
                if !passed { failures += 1 }
            }
        }
        print("TRANSPORT SUMMARY: \(cases.count - failures) passed; \(failures) failed")
        print("Scope: actual answer method with synthetic message replay; not firmware transport validation")
        if failures > 0 { exit(1) }
    }
}
