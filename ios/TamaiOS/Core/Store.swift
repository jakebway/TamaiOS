import Foundation
import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// A toy the user has hatched: one ROM plus its saves, in Documents/Toys/<id>/.
struct Toy: Codable, Identifiable, Equatable {
    var id: String          // the ROM's stem, e.g. fw_tg18_en_v063_2020-02-13_wondergarden
    var name: String        // what the user called it
    var romName: String     // "Wonder Garden (EN v063)"
    var color: Int
    var known: Bool
    var created: Date
}

struct RomCheck {
    let image: Data
    let hash: UInt64
    let known: Bool
    let name: String
    let stem: String
    /// The friendly part of the name ("Wonder Garden") for a default toy name.
    var shortName: String {
        if let i = name.firstIndex(of: "(") { return String(name[..<i]).trimmingCharacters(in: .whitespaces) }
        return name
    }
}

enum ImportError: LocalizedError {
    case unreadable(String)
    case tooSmall(Int)
    case notTG18(Int)
    case blank
    case zipNoROM

    var title: String {
        switch self {
        case .unreadable: return "Couldn't open that file"
        case .tooSmall: return "That file is too small"
        case .notTG18: return "That's not a Tamagotchi ON dump"
        case .blank: return "That dump is empty"
        case .zipNoROM: return "No dump inside that zip"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unreadable(let why):
            return "iOS wouldn't let the app read it (\(why)). If it's in iCloud Drive, open the Files app, make sure it has finished downloading, then try again."
        case .tooSmall(let n):
            return "It's \(ToyStore.sizeText(n)). A Tamagotchi ON / Meets flash dump is exactly 8 MB. Pick the full dump of the flash chip, not a save file or part of it."
        case .notTG18(let n):
            return "It's \(ToyStore.sizeText(n)) but doesn't look like a Tamagotchi ON / Meets flash dump. Dumps of other models (P1, Pix, Uni, Paradise, Smart…) won't work here."
        case .blank:
            return "The file is all blank (FF or 00). The chip probably wasn't read correctly — check the clip is seated properly and dump it again."
        case .zipNoROM:
            return "The zip doesn't contain an 8 MB Tamagotchi ON / Meets dump. Unzip it in the Files app and pick the .bin file instead."
        }
    }
}

enum ToyStore {
    static let romSize = 8 * 1024 * 1024

    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let r = docs.appendingPathComponent("Toys", isDirectory: true)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }

    static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func romURL(_ id: String) -> URL { dir(id).appendingPathComponent("rom.bin") }
    static func spriteURL(_ id: String) -> URL { dir(id).appendingPathComponent("sprite.png") }
    /// The last picture of the toy's screen: shown while it wakes up, instead of a black screen.
    static func lastFrameURL(_ id: String) -> URL { dir(id).appendingPathComponent("lastframe.png") }
    static func snapURL(_ id: String) -> URL { dir(id).appendingPathComponent("autosave.t18s") }
    static func flashURL(_ id: String) -> URL { dir(id).appendingPathComponent("game.flash") }
    static func flashMetaURL(_ id: String) -> URL { dir(id).appendingPathComponent("game.flash.json") }
    static func infoURL(_ id: String) -> URL { dir(id).appendingPathComponent("toy.json") }

    static func list() -> [Toy] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { u in
            guard let d = try? Data(contentsOf: u.appendingPathComponent("toy.json")),
                  let t = try? dec.decode(Toy.self, from: d),
                  fm.fileExists(atPath: romURL(t.id).path) else { return nil }
            return t
        }.sorted { $0.created < $1.created }
    }

    static func save(_ toy: Toy) {
        try? FileManager.default.createDirectory(at: dir(toy.id), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(toy) { try? d.write(to: infoURL(toy.id), options: .atomic) }
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir(id))
    }

    static func sizeText(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// Read a file the user picked (Files, AirDrop, Share sheet).
    static func readPicked(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var err: NSError?
        var out: Data?
        var readErr: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &err) { u in
            do { out = try Data(contentsOf: u, options: .mappedIfSafe) } catch { readErr = error }
        }
        if let d = out { return d }
        throw ImportError.unreadable((readErr ?? err)?.localizedDescription ?? "unknown error")
    }

    /// Validate a picked file (raw .bin, a bigger dump, or a .zip).
    static func check(_ data: Data) throws -> RomCheck {
        var image = data
        let isZip = data.count > 4 && data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
        if isZip {
            var out: UnsafeMutablePointer<UInt8>? = nil
            var n = 0
            let r = data.withUnsafeBytes { raw in
                tg_rom_from_zip(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out, &n)
            }
            guard r == 0, let p = out else { throw ImportError.zipNoROM }
            image = Data(bytes: p, count: n)
            tg_free(p, n)
        }
        var info = TgRomInfo()
        let code = image.withUnsafeBytes { raw in
            tg_check_rom(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &info)
        }
        switch code {
        case 0: break
        case -1: throw ImportError.tooSmall(image.count)
        case -3: throw ImportError.blank
        default: throw ImportError.notTG18(image.count)
        }
        let name = cString(&info.name)
        let stem = cString(&info.stem)
        return RomCheck(image: image.prefix(romSize), hash: info.hash, known: info.known == 1, name: name, stem: stem)
    }

    static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<end], as: UTF8.self)
        }
    }

    /// Store the ROM and make the toy.
    static func create(_ c: RomCheck, name: String, color: Int) throws -> Toy {
        let toy = Toy(id: c.stem, name: name.isEmpty ? c.shortName : name, romName: c.name,
                      color: color, known: c.known, created: Date())
        try FileManager.default.createDirectory(at: dir(toy.id), withIntermediateDirectories: true)
        try Data(c.image).write(to: romURL(toy.id), options: .atomic)
        save(toy)
        return toy
    }
}

struct BundledVariant: Identifiable {
    let id: String
    let name: String
    let filename: String
    let color: Int
    static let all = [
        BundledVariant(id: "fairy", name: "Fairy", filename: "fw_tg18_en_v057_2019-05-13_fairy", color: 0),
        BundledVariant(id: "magic", name: "Magic", filename: "fw_tg18_en_v058_2019-05-13_magic", color: 4),
        BundledVariant(id: "wondergarden", name: "Wonder Garden", filename: "fw_tg18_en_v063_2020-02-13_wondergarden", color: 5)
    ]
    static var anyAvailable: Bool {
        all.contains { Bundle.main.url(forResource: $0.filename, withExtension: "bin", subdirectory: "BundledFirmware") != nil }
    }
}
extension ToyStore {
    static func installBundled(_ variant: BundledVariant) throws -> Toy {
        guard let url = Bundle.main.url(forResource: variant.filename, withExtension: "bin", subdirectory: "BundledFirmware") else {
            throw ImportError.unreadable("Bundled firmware is missing; reinstall a complete build.")
        }
        let checked = try check(Data(contentsOf: url, options: .mappedIfSafe))
        if let existing = list().first(where: { $0.id == checked.stem }) { return existing }
        return try create(checked, name: variant.name, color: variant.color)
    }
}

/// Seconds as "3 h 12 min".
func describeDuration(_ s: Double) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = s >= 86400 ? [.day, .hour] : (s >= 3600 ? [.hour, .minute] : [.minute, .second])
    f.unitsStyle = .short
    f.maximumUnitCount = 2
    return f.string(from: s) ?? "\(Int(s)) s"
}

/// The toy's clock value for local time now.
func rtcNow() -> Double {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
    return tg_rtc_seconds(Int64(c.year ?? 2026), UInt32(c.month ?? 1), UInt32(c.day ?? 1),
                          UInt32(c.hour ?? 0), UInt32(c.minute ?? 0), UInt32(c.second ?? 0))
}

/// iOS's own Files picker. It copies the chosen file into the app first, so it
/// works for iCloud Drive, Downloads and other apps' folders alike.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.allowsMultipleSelection = false
        vc.shouldShowFileExtensions = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else { return }
            // let the picker finish closing before the screen changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.onPick(u) }
        }
    }
}