import SwiftUI
import UIKit

/// Things you drew in "Make your own". They stay in TamaDepa until you delete them,
/// so you can send them again, switch food between Snack and Meal, or keep editing.
struct Creation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case wallpaper, snack, meal, item
        var title: String {
            switch self { case .wallpaper: return "Wallpaper"; case .snack: return "Snack"; case .meal: return "Meal"; case .item: return "Item" }
        }
        var isFood: Bool { self == .snack || self == .meal }
        var size: Int { self == .wallpaper ? 128 : self == .item ? 32 : 24 }
        /// What the bag calls it.
        var bagKind: String { self == .wallpaper ? "wallpaper" : self == .item ? "item" : "food" }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var price: Int
    var seed: UInt64
    var made = Date()
    /// Items only: which of the device's built-in animations plays when you use it (see ItemAnimation).
    var anim: Int?

    /// Name the item builder expects ("food" is the snack template, "item:<animation>" an Item Box item).
    var builderKind: String {
        switch kind {
        case .wallpaper: return "wallpaper"
        case .meal: return "meal"
        case .snack: return "food"
        case .item: return "item:\(anim ?? ItemAnimation.all[0].code)"
        }
    }
}

/// The animations an Item Box item can play, found by delivering a real item of each kind to the emulated toy and using
/// it. The device picks the animation from a code in the item's file header, and the item's own pictures are drawn
/// into that scene, so your drawing takes the place of the rocket, bicycle, violin and so on.
struct ItemAnimation: Identifiable, Hashable {
    let code: Int
    let title: String
    let blurb: String
    let symbol: String
    var id: Int { code }

    static let all: [ItemAnimation] = [
        ItemAnimation(code: 4, title: "Cook", blurb: "Whips something up in the room", symbol: "fork.knife"),
        ItemAnimation(code: 5, title: "Blast off", blurb: "Streaks off into the distance", symbol: "airplane"),
        ItemAnimation(code: 6, title: "Glide", blurb: "Rides it along, whooshing by", symbol: "wind"),
        ItemAnimation(code: 9, title: "Party", blurb: "A whole crowd of them appears", symbol: "gift.fill"),
        ItemAnimation(code: 13, title: "Float", blurb: "Sets off for a relaxed ride", symbol: "water.waves"),
        ItemAnimation(code: 20, title: "Throw", blurb: "Flings it at a target", symbol: "scope"),
        ItemAnimation(code: 23, title: "Chat", blurb: "Pops up with speech bubbles", symbol: "bubble.left.and.bubble.right.fill"),
        ItemAnimation(code: 24, title: "Shake", blurb: "Shakes it up and shows it off", symbol: "sparkles"),
        ItemAnimation(code: 26, title: "Play keys", blurb: "Plays a tune, notes floating up", symbol: "music.note.list"),
        ItemAnimation(code: 27, title: "Fanfare", blurb: "Blasts out a cloud of music notes", symbol: "music.note"),
        ItemAnimation(code: 30, title: "Twirl", blurb: "Spins it around with a flourish", symbol: "sparkles"),
        ItemAnimation(code: 31, title: "Parade", blurb: "Rides along in style", symbol: "car.fill"),
        ItemAnimation(code: 34, title: "Ride", blurb: "Pedals off for a spin", symbol: "bicycle"),
        ItemAnimation(code: 37, title: "Serve", blurb: "Dishes out food in the room", symbol: "tray.fill"),
        ItemAnimation(code: 41, title: "Bloom", blurb: "Flowers burst out all around", symbol: "leaf.fill"),
        ItemAnimation(code: 42, title: "Perform", blurb: "Plays a song, notes drifting by", symbol: "music.quarternote.3"),
        ItemAnimation(code: 43, title: "Tinker", blurb: "Fiddles with it on a screen", symbol: "desktopcomputer"),
        ItemAnimation(code: 44, title: "Jingle", blurb: "Hangs it up and it tinkles", symbol: "bell.fill"),
    ]
    static func named(_ code: Int?) -> ItemAnimation? { all.first { $0.code == code } }
}

final class Creations: ObservableObject {
    static let shared = Creations()
    @Published private(set) var list: [Creation] = []

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Creations", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private func pxURL(_ c: Creation) -> URL { dir.appendingPathComponent(c.id.uuidString + ".px") }

    init() {
        if let d = try? Data(contentsOf: indexURL),
           let l = try? JSONDecoder().decode([Creation].self, from: d) { list = l }
    }

    private func saveIndex() {
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: indexURL, options: .atomic) }
    }

    /// 0xAARRGGBB pixels, row by row, as the item builder wants them.
    func pixels(_ c: Creation) -> [UInt32]? {
        guard let d = try? Data(contentsOf: pxURL(c)), d.count == c.kind.size * c.kind.size * 4 else { return nil }
        return d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }

    /// Add a new drawing, or update the one with this id.
    @discardableResult
    func save(_ c: Creation, pixels: [UInt32]) -> Creation {
        var c = c
        c.made = Date()
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: pxURL(c), options: .atomic)
        if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.insert(c, at: 0) }
        saveIndex()
        return c
    }

    func delete(_ c: Creation) {
        try? FileManager.default.removeItem(at: pxURL(c))
        list.removeAll { $0.id == c.id }
        saveIndex()
    }

    /// Snack <-> Meal. The device files an item by its number and type, so it gets a fresh number
    /// rather than clashing with a copy you may already have sent as the other kind.
    func setKind(_ c: Creation, _ kind: Creation.Kind) {
        guard kind.isFood, c.kind.isFood, kind != c.kind, let px = pixels(c) else { return }
        var n = c
        n.kind = kind
        n.seed = UInt64.random(in: 1...UInt64.max)
        save(n, pixels: px)
    }

    /// The delivery packet for this drawing (needs the built-in character pack).
    func packet(_ c: Creation) -> [UInt8]? { Creations.packet(c, pixels: pixels(c)) }

    static func packet(_ c: Creation, pixels: [UInt32]?) -> [UInt8]? {
        guard let px = pixels else { return nil }
        let n = c.kind.size
        guard px.count == n * n else { return nil }
        var p: UnsafeMutablePointer<UInt8>? = nil
        var len = 0
        let ok = px.withUnsafeBufferPointer { buf in
            c.builderKind.withCString { k in
                c.name.withCString { nm in
                    tg_mm_custom_item(k, nm, UInt16(c.kind == .wallpaper ? max(0, min(c.price, 9999)) : 0),
                                      buf.baseAddress, n, n, c.seed, 0, &p, &len)
                }
            }
        }
        guard ok == 1, let p else { return nil }
        defer { tg_free(p, len) }
        return Array(UnsafeBufferPointer(start: p, count: len))
    }

    /// A small picture of the drawing for lists, cropped to what you drew so it sits centred and fills the tile.
    func thumbnail(_ c: Creation) -> UIImage? {
        guard let argb = pixels(c) else { return nil }
        let n = c.kind.size
        var x0 = n, y0 = n, x1 = -1, y1 = -1
        for y in 0..<n { for x in 0..<n where (argb[y * n + x] >> 24) >= 128 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        if c.kind == .wallpaper || x1 < x0 { x0 = 0; y0 = 0; x1 = n - 1; y1 = n - 1 }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var rgba = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let v = argb[(y0 + y) * n + x0 + x]
            rgba[y * w + x] = (v & 0xFF00_0000) | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
        } }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
