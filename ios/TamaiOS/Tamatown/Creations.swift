import SwiftUI
import UIKit

/// Things you drew in "Make your own". They stay in TamaDepa until you delete them,
/// so you can send them again, switch food between Snack and Meal, or keep editing.
struct Creation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case wallpaper, snack, meal
        var title: String { self == .wallpaper ? "Wallpaper" : self == .snack ? "Snack" : "Meal" }
        var isFood: Bool { self != .wallpaper }
        var size: Int { self == .wallpaper ? 128 : 24 }
        /// What the bag and the item builder call it.
        var bagKind: String { self == .wallpaper ? "wallpaper" : "food" }
        /// Name the item builder expects ("food" is the snack template).
        var builderKind: String { self == .wallpaper ? "wallpaper" : self == .meal ? "meal" : "food" }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var price: Int
    var seed: UInt64
    var made = Date()
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
            c.kind.builderKind.withCString { k in
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

    /// A small picture of the drawing for lists.
    func thumbnail(_ c: Creation) -> UIImage? {
        guard let argb = pixels(c) else { return nil }
        let n = c.kind.size
        let rgba = argb.map { v -> UInt32 in
            (v & 0xFF00_0000) | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
