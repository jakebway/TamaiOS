import Foundation

@main
struct TransportAudit {
    static func main() {
        var cases: [(String, [[UInt8]], [UInt8]?)] = [
            ("valid three-byte reply", [[0xF0,0x0C,0,0],[0xF0,0x0D,3,0],[1,2,3],[0xF0,0x4D]], [1,2,3]),
            ("valid split payload", [[0xF0,0x0D,3,0],[1],[2,3],[0xF0,0x4D]], [1,2,3]),
            ("valid zero-length reply", [[0xF0,0x0D,0,0],[0xF0,0x4D]], []),
            ("finished acknowledgment only", [[0xF0,0x0C,0,2]], []),
            ("ordinary acknowledgment timeout compatibility", [[0xF0,0x0C,0,0]], []),
            ("payload resembling acknowledgment", [[0xF0,0x0D,2,0],[0xF0,0x0C],[0xF0,0x4D]], [0xF0,0x0C]),
            ("truncated payload must reject", [[0xF0,0x0D,3,0],[1],[0xF0,0x4D]], nil),
            ("non-envelope oversized payload must reject", [[0xF0,0x0D,3,0],[1,2,3,4],[0xF0,0x4D]], nil),
            ("short length header must reject", [[0xF0,0x0D,3],[0xF0,0x4D]], nil),
            ("short acknowledgment must reject", [[0xF0,0x0C,0]], nil),
            ("acknowledged incomplete timeout must reject", [[0xF0,0x0C,0,0],[0xF0,0x0D,3,0],[1]], nil),
            ("missing reply must reject", [], nil),
            ("data after advertised payload must reject", [[0xF0,0x0D,3,0],[1,2,3],[4],[0xF0,0x4D]], nil),
            ("data after zero-length header must reject", [[0xF0,0x0D,0,0],Array(repeating: 0, count: 20),[0xF0,0x4D]], nil),
            ("21-byte oversized chunk must reject", [[0xF0,0x0D,3,0],Array(repeating: 1, count: 21),[0xF0,0x4D]], nil),
            ("final envelope can begin with acknowledgment bytes", [[0xF0,0x0D,2,0],[0xF0,0x0C] + Array(repeating: 0xA5, count: 18),[0xF0,0x4D]], [0xF0,0x0C])
        ]
        for mode: UInt8 in [0x14, 0x17] {
            var payload = [UInt8](repeating: 0, count: 512)
            payload[0x4C] = mode
            var reply: [[UInt8]] = [[0xF0,0x0C,0x02,0x01,0,0,0,0],[0xF0,0x0D,0,2]]
            for offset in stride(from: 0, to: 500, by: 20) { reply.append(Array(payload[offset..<(offset + 20)])) }
            let final = Array(payload[500..<512]) + [UInt8](repeating: 0xA5, count: 8)
            let label = mode == 0x14 ? "Visit" : "Download"
            cases.append((label + " firmware-shaped 512-byte reply with full final notification", reply + [final,[0xF0,0x4D]], payload))
            cases.append((label + " truncated 500-of-512 reply must reject", reply + [[0xF0,0x4D]], nil))
        }
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
        print("Scope: build-patched answer method with synthetic replay; 512-byte cases reproduce reported framing, not captured payload contents or full Visit/Download gameplay; ack-only compatibility does not prove command acceptance")
        if failures > 0 { exit(1) }
    }
}
