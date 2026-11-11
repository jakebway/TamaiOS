import SwiftUI
import UIKit

/// A partner your Tama can marry: four parts (Body, Face, Head, Back) each
/// taken from a character, three of them recoloured.
struct Suitor: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var body: UInt16
    var face: UInt16
    var head: UInt16
    var back: UInt16
    var bodyColor: Int
    var headColor: Int
    var backColor: Int
    var blurb: String

    var isMix: Bool { !(body == face && face == head && head == back) }
}

/// TamaiOS Town: the dating and marriage part of the built-in Tama App.
final class Town: ObservableObject {
    static let shared = Town()

    enum Pack: Equatable { case missing, loading, ready(Int), failed(String) }
    enum Pending: String, Codable { case none, marry, back }

    @Published var pack: Pack = .missing
    @Published var ids: [UInt16] = []
    /// Characters with a real body (a few are only accessories: a bow, a hat). Only these can be a Body.
    @Published var bodyIDs: [UInt16] = []
    @Published var suitors: [Suitor] = []
    /// Which wallpaper is behind the town (chosen in Tamatown Settings) when you haven't picked your own picture.
    /// -1 = automatic: it follows the time of day.
    @Published var wallpaperIndex: Int = Prefs.d.object(forKey: "town.wallpaper") as? Int ?? -1 {
        didSet { Prefs.d.set(wallpaperIndex, forKey: "town.wallpaper") }
    }
    /// The wallpaper to show behind the town right now.
    var activeWallpaper: Int {
        if wallpaperIndex >= 0 { return wallpaperIndex }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 7 && hour < 17 { return 4 }       // sunny beach
        if hour >= 17 && hour < 20 { return 22 }     // sunset
        return 6                                      // night city
    }
    /// Shop items (food, items, accessories, wallpapers, places, games) from the pack.
    @Published var items: [PackItem] = []
    /// Your own town picture (Tamatown Settings), if you chose one.
    @Published var customBG: UIImage? = UIImage(contentsOfFile: Town.backgroundFile.path)

    static var backgroundFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("TownPicture.img")
    }

    func setBackground(_ data: Data?) {
        if let data, let img = UIImage(data: data) {
            try? data.write(to: Town.backgroundFile, options: .atomic)
            customBG = img
        } else {
            try? FileManager.default.removeItem(at: Town.backgroundFile)
            customBG = nil
        }
    }

    static var bundledPack: URL? { Bundle.main.url(forResource: "MyMeets2_3_7", withExtension: "zip", subdirectory: "BundledAssets") }
    static var packFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("TownPack.zip")
    }

    private var imageCache: [String: CGImage] = [:]
    private var emptyLayers = Set<String>()

    // MARK: character pack

    func loadIfPresent() {
        guard case .missing = pack else { return }
        guard let bundled = Town.bundledPack else {
            pack = .failed("Built-in MyMeets assets are missing. Rebuild with assets/MyMeets2_3_7.zip included."); return
        }
        load(from: bundled)
    }

    func reloadBundledPack() {
        guard pack != .loading else { return }
        pack = .missing; loadIfPresent()
    }
    // Retained for source compatibility; this no longer makes a network request.
    func download() { reloadBundledPack() }

    func importPack(_ data: Data) {
        do {
            try data.write(to: Town.packFile, options: .atomic)
            load(from: Town.packFile)
        } catch { pack = .failed(error.localizedDescription) }
    }

    private func load(from url: URL) {
        pack = .loading
        Task.detached(priority: .userInitiated) {
            let d = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
            let n = d.withUnsafeBytes { tg_mm_load_zip($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            var ids = [UInt16](repeating: 0, count: 512)
            let c = ids.withUnsafeMutableBufferPointer { tg_mm_ids($0.baseAddress, 512) }
            let all = Array(ids.prefix(c))
            let bodies = all.filter { id in
                var info = [Int32](repeating: 0, count: 2)
                return tg_mm_body_info(id, &info) == 1 && info[0] >= 200 && info[1] == 7
            }
            await MainActor.run {
                if n > 0 {
                    self.ids = all
                    self.bodyIDs = bodies.isEmpty ? all : bodies
                    self.items = Town.readItems()
                    self.imageCache = [:]
                    self.pack = .ready(Int(n))
                    if self.suitors.isEmpty { self.shuffle() }
                } else {
                    self.pack = .failed("The built-in character pack could not be read. Check the build's bundled-asset validation log.")
                }
            }
        }
    }

    static func readItems() -> [PackItem] {
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        tg_mm_items(&p, &n)
        guard let p else { return [] }
        let d = Data(bytes: p, count: n)
        tg_free(p, n)
        return (try? JSONDecoder().decode([PackItem].self, from: d)) ?? []
    }

    /// Delivery packet for a pack item, with Gotchi Points.
    func itemPacket(_ it: PackItem, points: Int) -> [UInt8]? {
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        guard tg_mm_item_packet(it.i, UInt32(max(0, points)), &p, &n) == 1, let p else { return nil }
        let a = Array(UnsafeBufferPointer(start: p, count: n))
        tg_free(p, n)
        return a
    }

    /// Delivery packet for an item file you brought (e.g. a place like Magic Hut).
    static func userItemPacket(_ d: Data, points: Int) -> [UInt8]? {
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        let ok = d.withUnsafeBytes { tg_mm_user_item($0.bindMemory(to: UInt8.self).baseAddress, $0.count, UInt32(max(0, points)), &p, &n) }
        guard ok == 1, let p else { return nil }
        let a = Array(UnsafeBufferPointer(start: p, count: n))
        tg_free(p, n)
        return a
    }

    static func userItemName(_ d: Data) -> String {
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        d.withUnsafeBytes { tg_mm_user_item_name($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &p, &n) }
        guard let p else { return "" }
        let s = String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
        tg_free(p, n)
        return s
    }

    // MARK: pictures

    func image(_ s: Suitor) -> CGImage? {
        image(body: s.body, bodyColor: s.bodyColor, face: s.face, head: s.head, headColor: s.headColor, back: s.back, backColor: s.backColor)
    }

    func image(body: UInt16, bodyColor: Int, face: UInt16, head: UInt16, headColor: Int, back: UInt16, backColor: Int) -> CGImage? {
        let key = "\(body).\(bodyColor).\(face).\(head).\(headColor).\(back).\(backColor)"
        if let c = imageCache[key] { return c }
        var px = [UInt32](repeating: 0, count: 64 * 64)
        let ok = px.withUnsafeMutableBufferPointer {
            tg_mm_compose(body, Int32(bodyColor), face, head, Int32(headColor), back, Int32(backColor), $0.baseAddress)
        }
        guard ok == 1 else { return nil }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: data as CFData),
              let img = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        imageCache[key] = img
        return img
    }

    /// One gene on its own (0 Body, 1 Face, 2 Head, 3 Back), in a colour, trimmed to its edges. nil = nothing there.
    func layer(_ part: Int, id: UInt16, color: Int) -> CGImage? {
        let key = "L\(part).\(id).\(color)"
        if let c = imageCache[key] { return c }
        if emptyLayers.contains(key) { return nil }
        var px = [UInt32](repeating: 0, count: 64 * 64)
        let ok = px.withUnsafeMutableBufferPointer { tg_mm_layer(Int32(part), id, Int32(color), $0.baseAddress) }
        var x0 = 64, x1 = -1, y0 = 64, y1 = -1
        if ok == 1 {
            for i in 0..<(64 * 64) where px[i] >> 24 != 0 {
                let x = i % 64, y = i / 64
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard ok == 1, x1 >= x0 else { emptyLayers.insert(key); return nil }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: data as CFData),
              let full = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                 provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let img = full.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
        else { return nil }
        imageCache[key] = img
        return img
    }

    /// The pack's wallpapers (the toy's own room and place pictures, 128x128).
    var wallpaperCount: Int { Int(tg_mm_wallpaper_count()) }

    func wallpaper(_ n: Int) -> CGImage? {
        let key = "W\(n)"
        if let c = imageCache[key] { return c }
        var wh = [Int32](repeating: 0, count: 2)
        var px = [UInt32](repeating: 0, count: 128 * 128)
        let ok = px.withUnsafeMutableBufferPointer { tg_mm_wallpaper(Int32(n), &wh, $0.baseAddress) }
        guard ok == 1, wh[0] > 0, wh[1] > 0 else { return nil }
        let (w, h) = (Int(wh[0]), Int(wh[1]))
        let data = px.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(rebasing: $0[0..<(w * h)])) }
        guard let prov = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        imageCache[key] = img
        return img
    }

    /// The wallpapers that look good behind a character (the rest are duplicates or have writing on them).
    var niceWallpapers: [Int] {
        let n = wallpaperCount
        return (Array(0..<30) + [32, 33, 34, 35, 60, 61, 62, 63, 64, 65]).filter { $0 < n }
    }

    static func swatch(_ pal: Int) -> Color {
        var c = [UInt32](repeating: 0, count: 8)
        _ = c.withUnsafeMutableBufferPointer { tg_mm_palette(Int32(pal), $0.baseAddress) }
        let v = c[2]
        return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    // MARK: suitors

    static let names = ["LUNA", "MOCHI", "PIP", "KIKI", "SUNNY", "MILO", "POPPY", "BIBI", "COCO", "NOVA", "TOFU", "PEACH",
                        "BUBBLE", "MAPLE", "ZIGGY", "HONEY", "PUDDING", "SKY", "BEAN", "CLOVER", "JUNO", "PIXIE", "SUGAR",
                        "TWINKLE", "BOBA", "DAISY", "FIZZ", "GIGI", "HOPPY", "IVY", "JELLY", "KOBE", "LULU", "MINT",
                        "NUGGET", "OLIVE", "PRINCE", "QUILL", "ROSIE", "SPROUT", "TIKI", "UMI", "VIOLET", "WAFFLE", "YUZU", "ZUZU"]
    static let blurbs = ["Loves picnics and long walks in the park.", "Collects shiny stickers.", "Best dancer in TamaiOS Town!",
                         "Bakes the fluffiest cakes.", "Always up for an adventure.", "Writes little poems about the stars.",
                         "Never misses a game night.", "Grows the prettiest flowers in town.", "Can't stop humming happy tunes.",
                         "Dreams of travelling the world.", "Super gentle and great with babies.", "Tells the funniest jokes.",
                         "Knows every snack shop in town.", "A sleepyhead who loves cosy naps.", "Brave, kind and a little bit shy."]

    func randomSuitor(mix: Bool) -> Suitor? {
        guard !ids.isEmpty else { return nil }
        let pick = { self.ids.randomElement()! }
        let base = (self.bodyIDs.isEmpty ? self.ids : self.bodyIDs).randomElement()!
        let s = Suitor(name: Town.names.randomElement()!,
                       body: base, face: mix ? pick() : base, head: mix ? pick() : base, back: mix ? pick() : base,
                       bodyColor: Int.random(in: 0...12), headColor: Int.random(in: 0...12), backColor: Int.random(in: 0...12),
                       blurb: Town.blurbs.randomElement()!)
        return image(s) == nil ? nil : s
    }

    /// How many singles live in town (the grid, the people walking about and the Arcade game use them).
    static let crowdSize = 18

    func shuffle() {
        var out: [Suitor] = []
        var tries = 0
        while out.count < Town.crowdSize && tries < 240 {
            tries += 1
            if let s = randomSuitor(mix: out.count >= Town.crowdSize * 2 / 3),
               !out.contains(where: { $0.name == s.name || ($0.body == s.body && !s.isMix && !$0.isMix) }) {
                out.append(s)
            }
        }
        suitors = out
    }

    // MARK: partners you designed (kept for as long as this generation of your Tama lasts)

    /// A partner made with "Design your own", with how far the dating has got. It stays until the Tama marries
    /// (a new generation), so you can keep seeing them on later visits.
    struct Partner: Codable, Identifiable, Equatable {
        var suitor: Suitor
        var hearts = 0
        var done: [Int] = []
        var generation: Int
        var id: UUID { suitor.id }
    }

    /// The current generation of this toy: each marriage starts the next.
    func generation(_ toy: Toy) -> Int { state(toy).married.count }

    /// Partners designed for the Tama as it is now.
    func partners(_ toy: Toy?) -> [Partner] {
        guard let toy else { return [] }
        let st = state(toy)
        return (st.partners ?? []).filter { $0.generation == st.married.count }
    }

    func partner(_ id: UUID, _ toy: Toy?) -> Partner? { partners(toy).first { $0.id == id } }

    func addPartner(_ suitor: Suitor, _ toy: Toy) {
        var x = state(toy)
        guard !(x.partners ?? []).contains(where: { $0.id == suitor.id }) else { return }
        x.partners = (x.partners ?? []).filter { $0.generation == x.married.count } + [Partner(suitor: suitor, generation: x.married.count)]
        save(x, toy)
    }

    func updatePartner(_ id: UUID, hearts: Int, done: [Int], _ toy: Toy) {
        var x = state(toy)
        guard let i = x.partners?.firstIndex(where: { $0.id == id }) else { return }
        x.partners?[i].hearts = hearts; x.partners?[i].done = done
        save(x, toy)
    }

    func removePartner(_ id: UUID, _ toy: Toy) {
        var x = state(toy)
        x.partners = x.partners?.filter { $0.id != id }
        save(x, toy)
    }

    /// Everyone who wanders the town: your own partners first, then the singles.
    func crowd(_ toy: Toy?, limit: Int) -> [Suitor] {
        Array((partners(toy).map(\.suitor) + suitors).prefix(limit))
    }

    // MARK: per-toy state (the Tama away in town, a wedding waiting)

    struct State: Codable {
        var away = false
        var pending: Pending = .none
        var suitor: Suitor?
        var babySex = 2          // 0 boy, 1 girl, 2 surprise
        var genes = 0            // 0 like the app, 2 random
        var married: [String] = []
        /// Things bought for this toy that haven't reached it yet (souvenirs).
        var bag: [BagItem]? = nil
        /// The Tamagotchi's own name (from its last visit).
        var petName: String? = nil
        var pointGifts: [PointGift]? = nil
        /// Partners designed in Tama ♥ Party, kept for this generation.
        var partners: [Partner]? = nil
    }

    struct PointGift: Codable, Identifiable, Equatable {
        var id = UUID()
        var amount: Int
        var attempted = false
    }
    func queuePoints(_ amount: Int, for toy: Toy) {
        guard (1...DeviceWallet.maximum).contains(amount) else { return }
        var value = state(toy)
        value.pointGifts = (value.pointGifts ?? []) + [PointGift(amount: amount)]
        save(value, toy)
    }
    func markGiftAttempt(_ id: UUID, for toy: Toy) {
        var value = state(toy)
        if let i = value.pointGifts?.firstIndex(where: { $0.id == id }) {
            value.pointGifts?[i].attempted = true
            save(value, toy)
        }
    }
    func removeGift(_ id: UUID, for toy: Toy) {
        var value = state(toy)
        value.pointGifts = (value.pointGifts ?? []).filter { $0.id != id }
        save(value, toy)
    }
    static func pointsPacket(_ amount: Int) -> [UInt8] {
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        tg_mm_points_packet(UInt32(max(0, min(DeviceWallet.maximum, amount))), &p, &n)
        guard let p else { return [] }
        defer { tg_free(p, n) }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }
    struct BagItem: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var kind: String
    }

    // MARK: the bag (souvenirs) and the pocket (Gotchi Points for the toy)

    private func bagDir(_ toy: Toy) -> URL {
        let d = ToyStore.dir(toy.id).appendingPathComponent("bag", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func bag(_ toy: Toy) -> [BagItem] { state(toy).bag ?? [] }

    /// Keep a bought item (its delivery packet) until the toy can receive it.
    func addToBag(_ toy: Toy, name: String, kind: String, packet: [UInt8]) {
        let it = BagItem(name: name, kind: kind)
        try? Data(packet).write(to: bagDir(toy).appendingPathComponent(it.id.uuidString + ".bin"), options: .atomic)
        var x = state(toy)
        x.bag = (x.bag ?? []) + [it]
        save(x, toy)
    }

    func bagData(_ toy: Toy, _ it: BagItem) -> Data? {
        try? Data(contentsOf: bagDir(toy).appendingPathComponent(it.id.uuidString + ".bin"))
    }

    func removeFromBag(_ toy: Toy, _ it: BagItem) {
        try? FileManager.default.removeItem(at: bagDir(toy).appendingPathComponent(it.id.uuidString + ".bin"))
        var x = state(toy)
        x.bag = (x.bag ?? []).filter { $0.id != it.id }
        save(x, toy)
    }

    /// Gotchi Points won in the Arcade, waiting to go to the toy.
    static var pocket: Int {
        get { UserDefaults.standard.integer(forKey: "gotchiPocket") }
        set { UserDefaults.standard.set(max(0, min(99999, newValue)), forKey: "gotchiPocket") }
    }

    /// The come-home packet, carrying an optional souvenir and points.
    static func backPacket(_ item: Data?, points: Int) -> [UInt8] {
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        let pts = UInt32(max(0, points))
        if let item {
            item.withUnsafeBytes { tg_mm_back_packet($0.bindMemory(to: UInt8.self).baseAddress, $0.count, pts, &p, &n) }
        } else {
            tg_mm_back_packet(nil, 0, pts, &p, &n)
        }
        guard let p else { return [] }
        let a = Array(UnsafeBufferPointer(start: p, count: n))
        tg_free(p, n)
        return a
    }

    private func stateURL(_ toy: Toy) -> URL { ToyStore.dir(toy.id).appendingPathComponent("town.json") }
    func visitURL(_ toy: Toy) -> URL { ToyStore.dir(toy.id).appendingPathComponent("visit.bin") }

    // Views ask for the state many times per redraw, so it is read from disk
    // once and kept in memory (thread-safe: the app link reads it off the main thread).
    private let cacheLock = NSLock()
    private var stateCache: [String: State] = [:]
    private var visitCache: [String: (name: String, adult: Bool, sex: Int)?] = [:]

    /// The names given to the twins, in the order they were typed on the toy.
    static func twinNames(_ id: String) -> [String] { Prefs.d.stringArray(forKey: "twins.names.v1." + id) ?? [] }
    func noteTwinName(_ id: String, _ name: String) {
        guard Self.twinNames(id) != [name] else { return }
        Prefs.d.set([name], forKey: "twins.names.v1." + id)
        objectWillChange.send()
    }

    /// Two babies hatched after the latest marriage: say so in its entry (once).
    func noteTwins(_ toy: Toy) {
        if !Prefs.d.bool(forKey: "twins.v1." + toy.id) {
            Prefs.d.set(true, forKey: "twins.v1." + toy.id)
            objectWillChange.send()
        }
        var s = state(toy)
        guard let last = s.married.last, !last.hasSuffix("(twins)") else { return }
        s.married[s.married.count - 1] = last + " (twins)"
        save(s, toy)
    }

    func state(_ toy: Toy) -> State {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = stateCache[toy.id] { return c }
        var s = State()
        if let d = try? Data(contentsOf: stateURL(toy)), let x = try? JSONDecoder().decode(State.self, from: d) { s = x }
        stateCache[toy.id] = s
        return s
    }

    /// The Tamagotchi's name (from the device), for messages. Falls back to "your Tama".
    func name(_ toy: Toy?) -> String {
        guard let toy else { return "Your Tama" }
        if let live = LiveTamaName.shared.verifiedName, !live.isEmpty {
            return Town.withSuffix(live, japanese: toy.romName.contains("(JP"))
        }
        let liveCurrent = LiveTamaName.shared.name
        if liveCurrent != "Your Tama" && !liveCurrent.isEmpty {
            return Town.withSuffix(liveCurrent, japanese: toy.romName.contains("(JP"))
        }
        var base = ""
        if let n = visitInfo(toy)?.name, !n.isEmpty { base = n.capitalized }
        else if let n = LiveTamaName.savedName(toy.id), !n.isEmpty { base = n }
        else if let n = state(toy).petName, !n.isEmpty { base = n }
        guard !base.isEmpty else { return "Your Tama" }
        return Town.withSuffix(base, japanese: toy.romName.contains("(JP"))
    }

    /// The device stores only the name you typed; it always shows it with the
    /// "-tchi" ending ("Clubu" → "Clubutchi"), so do the same.
    static func withSuffix(_ n: String, japanese: Bool) -> String {
        if japanese { return n.hasSuffix("っち") ? n : n + "っち" }
        return n.lowercased().hasSuffix("tchi") ? n : n + "tchi"
    }

    /// The Tamagotchi's own name from visit data (not the owner's profile name).
    static func decodeName(_ bytes: [UInt8]) -> String {
        guard bytes.count > 0x70 else { return "" }
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        bytes.withUnsafeBufferPointer { tg_mm_tama_name($0.baseAddress, $0.count, &p, &n) }
        guard let p else { return "" }
        let s = String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
        tg_free(p, n)
        return s.capitalized
    }

    /// Store what the device sent when it came to town.
    func saveVisit(_ data: [UInt8], _ toy: Toy) {
        try? Data(data).write(to: visitURL(toy), options: .atomic)
        cacheLock.lock(); visitCache[toy.id] = nil; cacheLock.unlock()
    }

    func invalidateDeviceCache(_ toy: Toy) {
        cacheLock.lock(); stateCache[toy.id] = nil; visitCache[toy.id] = nil; cacheLock.unlock()
        objectWillChange.send()
    }

    func save(_ s: State, _ toy: Toy) {
        cacheLock.lock(); stateCache[toy.id] = s; cacheLock.unlock()
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL(toy), options: .atomic) }
        objectWillChange.send()
    }

    func visitData(_ toy: Toy) -> [UInt8] { (try? Data(contentsOf: visitURL(toy))).map { [UInt8]($0) } ?? [] }

    func visitInfo(_ toy: Toy) -> (name: String, adult: Bool, sex: Int)? {
        cacheLock.lock()
        if let c = visitCache[toy.id] { cacheLock.unlock(); return c }
        cacheLock.unlock()
        let info = readVisitInfo(toy)
        cacheLock.lock(); visitCache[toy.id] = .some(info); cacheLock.unlock()
        return info
    }

    private func readVisitInfo(_ toy: Toy) -> (name: String, adult: Bool, sex: Int)? {
        let v = visitData(toy)
        guard v.count > 0x70 else { return nil }
        let info = v.withUnsafeBufferPointer { tg_mm_visit_info($0.baseAddress, $0.count) }
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        v.withUnsafeBufferPointer { tg_mm_tama_name($0.baseAddress, $0.count, &p, &n) }
        var name = ""
        if let p { name = String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self); tg_free(p, n) }
        return (name, info & 1 != 0, Int((info >> 1) & 1))
    }

    func marriagePacket(_ toy: Toy, _ s: Suitor, babySex: Int, genes: Int) -> [UInt8]? {
        let visit = visitData(toy)
        let lang: UInt8 = toy.romName.contains("(JP") ? 4 : 8
        let sex: UInt8 = babySex == 2 ? UInt8.random(in: 0...1) : UInt8(babySex)
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        let ok = visit.withUnsafeBufferPointer { v in
            s.name.withCString { name in
                tg_mm_marriage(v.baseAddress, v.count, s.body, Int32(s.bodyColor), s.face, s.head, Int32(s.headColor),
                               s.back, Int32(s.backColor), sex, lang, UInt8(genes), name, UInt64.random(in: 1...UInt64.max), &p, &n)
            }
        }
        guard ok == 1, let p else { return nil }
        let a = Array(UnsafeBufferPointer(start: p, count: n))
        tg_free(p, n)
        return a
    }
}

/// One item in the character pack's shop.
struct PackItem: Decodable, Hashable {
    let i: Int
    let lang: String
    let file: String
    let id: String
    let name: String
    let kind: String
    /// Written in kana (for Japanese toys)?
    var isKana: Bool { name.unicodeScalars.contains { $0.value >= 0x3040 && $0.value < 0x3100 } }
    var displayName: String { name.isEmpty ? id : name.capitalized }
}

/// A pixel-sharp character picture.
struct CharacterPicture: View {
    let image: CGImage?
    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
            } else {
                Image(systemName: "questionmark").font(.title).foregroundStyle(.secondary)
            }
        }
    }
}
final class DeviceWallet: ObservableObject {
    static let shared = DeviceWallet()
    static let maximum = 65535
    @Published private(set) var balance: Int?
    @Published private(set) var deviceID: String?
    func refresh(_ emu: Emulator) {
        let id = emu.toy?.id
        let raw = emu.withCore { tg_profile_points($0) } ?? -1
        let next = raw >= 0 ? Int(raw) : nil
        if id != deviceID { deviceID = id }
        if next != balance { balance = next }
    }
    @discardableResult
    func adjust(_ amount: Int, emu: Emulator, deviceID: String) -> Bool {
        guard emu.toy?.id == deviceID, let delta = Int32(exactly: amount) else { return false }
        let next = emu.withCore { tg_profile_adjust_points($0, delta) } ?? -1
        guard next >= 0 else { refresh(emu); return false }
        self.deviceID = deviceID
        balance = Int(next)
        emu.saveNow()
        return true
    }
    func credit(_ amount: Int, emu: Emulator) -> Int {
        refresh(emu)
        guard let current = balance, let id = emu.toy?.id else { return 0 }
        let accepted = max(0, min(amount, Self.maximum - current))
        return accepted > 0 && adjust(accepted, emu: emu, deviceID: id) ? accepted : 0
    }
}
