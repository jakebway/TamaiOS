import Foundation

/// Which screen the toy is on, read from the firmware's own call stack (every screen runs its own loop).
/// Same layout on all three firmwares, only shifted: the addresses below were found in the test harness.
enum ToyScreen {
    private struct Map { let main: UInt32; let grid: UInt32; let item0: UInt32 }
    private static let maps: [String: Map] = [
        "wondergarden": Map(main: 0x2014_2EB1, grid: 0x2014_5F91, item0: 0x2014_60D1),
        "magic": Map(main: 0x2014_3B99, grid: 0x2014_6CF1, item0: 0x2014_6E31),
        "fairy": Map(main: 0x2014_2187, grid: 0x2014_52E1, item0: 0x2014_5421),
    ]
    /// Menu items in grid order, as offsets from the first item's call.
    private static let items: [(UInt32, String)] = [
        (0x000, "Profile"), (0x02C, "Meal & Snack"), (0x070, "Bathroom"), (0x0DC, "Connection"),
        (0x0FA, "Family"), (0x12C, "Explore My Town"), (0x162, "Travel"), (0x222, "Item Box"), (0x240, "Notebook"),
    ]

    /// Deeper screens inside Connection: (connection list, Tamagotchi list, mode list, playdate). Gift, Marry and
    /// Travel sit at fixed distances from Playdate on every firmware.
    private static let link: [String: (UInt32, UInt32, UInt32, UInt32)] = [
        "wondergarden": (0x2017_BCEB, 0x2017_BD7F, 0x2017_9CBB, 0x2017_A739),
        "magic": (0x2017_B57F, 0x2017_B613, 0x2017_958B, 0x2017_9FCD),
        "fairy": (0x2017_9B3F, 0x2017_9BD3, 0x2017_7B4B, 0x2017_858D),
    ]

    static func chain(core h: OpaquePointer) -> [UInt32] {
        var buf = [UInt32](repeating: 0, count: 16)
        let n = Int(tg_call_chain(h, &buf, 16))
        return Array(buf.prefix(max(0, n)))
    }

    /// A short name for the screen, or nil when the firmware isn't one we have mapped.
    static func name(chain c: [UInt32], deviceID: String) -> String? {
        guard let m = maps.first(where: { deviceID.contains($0.key) })?.value else { return nil }
        guard let i = c.firstIndex(of: m.main) else { return c.isEmpty ? nil : "room" }
        guard i + 1 < c.count else { return "menu" }
        if let l = link.first(where: { deviceID.contains($0.key) })?.value {
            let named: [UInt32: String] = [l.3: "Playdate", l.3 + 0xE4C: "Gift", l.3 + 0x768: "Marry", l.3 + 0x87C: "Travel",
                                           l.2: "Connection › choosing", l.1: "Connection › Tamagotchi", l.0: "Connection"]
            if let hit = c.reversed().first(where: { named[$0] != nil }) { return named[hit] }
        }
        let d = c[i + 1]
        if d == m.grid { return "menu" }
        if let item = items.first(where: { m.item0 + $0.0 == d }) { return item.1 }
        return "menu"                                           // the cursor is moving between items
    }
}
