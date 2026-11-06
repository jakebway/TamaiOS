import Foundation

/// The built-in "phone app": talks to the toy's (emulated) Bluetooth module
/// the way the official Tamagotchi app did. Transport as used by WebMeets:
/// a packet goes as F0 8D, 20-byte writes 15 ms apart, F0 CD. The toy answers
/// F0 0C <received u16> (0x0200 = finished); the app then asks for data with
/// F0 8E 0D and gets F0 0D <len u16>, the data, F0 4D.
final class LinkDiagnostics {
    static let shared = LinkDiagnostics()
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ message: String) {
        let line = String(format: "%.3f", ProcessInfo.processInfo.systemUptime) + " " + message
        lock.lock(); defer { lock.unlock() }
        events.append(line)
        if events.count > 800 { events.removeFirst(events.count - 800) }
    }
    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        return (["arcade-performance-v1 / settings-touch-v1 / settings-care-v1 / pickup-download-only-v1 / marriage-name-fix-v1",
                 "Arcade: cached sprites, no in-round wallet polling, bounded elapsed time. Transport unchanged."] + events).joined(separator: "\n")
    }
}

final class TamaLink {
    enum LinkError: LocalizedError {
        case notRunning, noAnswer, writeFailed
        var errorDescription: String? {
            switch self {
            case .notRunning: return "No device is running."
            case .noAnswer: return "Your Tama didn't answer. On the device, choose Connection › App › Download, then try again."
            case .writeFailed: return "Couldn't send to your Tama. Try again."
            }
        }
    }

    private let diagnosticID = String(UUID().uuidString.prefix(8))
    private func trace(_ text: String) { LinkDiagnostics.shared.record("[\(diagnosticID)] \(text)") }
    let emu: Emulator
    /// The device's answer to the last hello (it carries its mode and the Tama's name).
    var hello: [UInt8] = []
    init(emu: Emulator) { self.emu = emu }

    var ready: Bool { (emu.withCore { tg_radio_ready($0) } ?? 0) != 0 }

    func connect(_ on: Bool) {
        trace("connect=\(on) ready=\(ready)")
        if on { emu.linkBusy = true }
        emu.withCore { tg_radio_connect($0, on ? 1 : 0) }
        if !on { emu.radioStale = true; emu.holdLatch = false; emu.linkBusy = false }
    }

    private func write(_ d: [UInt8]) throws {
        // The emulated module takes the next chunk as soon as the device has read
        // the last one, so no artificial Bluetooth delays are needed.
        for _ in 0..<4000 {
            guard let r = emu.withCore({ h in d.withUnsafeBufferPointer { tg_radio_write(h, $0.baseAddress, $0.count) } }) else {
                throw LinkError.notRunning
            }
            if r == 1 { return }
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw LinkError.writeFailed
    }

    private func read() -> [UInt8]? {
        emu.withCore { h -> [UInt8]? in
            var p: UnsafeMutablePointer<UInt8>? = nil
            var n = 0
            guard tg_radio_read(h, &p, &n) == 1, let p else { return nil }
            let a = Array(UnsafeBufferPointer(start: p, count: n))
            tg_free(p, n)
            return a
        } ?? nil
    }

    /// Throw away anything the toy sent that nobody asked for.
    func drain(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if read() == nil { Thread.sleep(forTimeInterval: 0.002) }
        }
    }

    /// Send one packet.
    func send(_ pkt: [UInt8]) throws {
        let hash = pkt.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        trace("SEND bytes=\(pkt.count) op=\(pkt.count > 0x4c ? Int(pkt[0x4c]) : -1) cmd=\(pkt.count > 0x5e ? Int(pkt[0x5e]) : -1) fnv32=\(String(format: "%08X", hash))")
        Thread.sleep(forTimeInterval: 0.02)
        try write([0xF0, 0x8D])
        var i = 0
        while i < pkt.count {
            let j = min(i + 20, pkt.count)
            try write(Array(pkt[i..<j]))
            i = j
        }
        try write([0xF0, 0xCD])
    }

    /// Wait for the toy's answer to a packet; returns the data it sent back.
    func answer(firstTimeout: Double = 4, idleTimeout: Double = 4) throws -> [UInt8] {
        var gotAny = false
        var buffer: [UInt8] = []
        var expected = -1
        var acked = false
        let start = Date()
        var last = Date()
        while true {
            if let n = read() {
                if expected < 0 || buffer.count + n.count >= expected || (n.count >= 2 && n[0] == 0xF0) {
                    trace("RX bytes=\(n.count) collected=\(buffer.count) expected=\(expected) prefix=\(n.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))")
                }
                gotAny = true
                last = Date()
                let tag = n.count >= 2 ? UInt16(n[0]) | UInt16(n[1]) << 8 : 0
                if expected >= 0 && buffer.count < expected && tag != 0x4DF0 {
                    buffer += n                                  // data chunk
                } else if tag == 0x0CF0 {                        // received / finished
                    acked = true
                    let status = n.count >= 4 ? UInt16(n[2]) | UInt16(n[3]) << 8 : 0
                    if status == 0x0200 { return buffer }
                    try write([0xF0, 0x8E, 0x0D])                // "send me your data"
                } else if tag == 0x0DF0 {                        // data follows
                    expected = n.count >= 4 ? Int(UInt16(n[2]) | UInt16(n[3]) << 8) : 0
                    buffer.removeAll(keepingCapacity: true)
                } else if tag == 0x4DF0 || tag == 0x5CF0 {      // data done
                    return buffer
                } else if expected >= 0 {
                    buffer += n
                }
                continue
            }
            let now = Date()
            if !gotAny && now.timeIntervalSince(start) > firstTimeout { throw LinkError.noAnswer }
            if gotAny && now.timeIntervalSince(last) > idleTimeout {
                trace("IDLE TIMEOUT acked=\(acked) received=\(buffer.count) expected=\(expected)")
                if acked { return buffer }
                throw LinkError.noAnswer
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

}

extension TamaLink {
    static func packet(op: UInt8, cmd: UInt8) -> [UInt8] {
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        tg_mm_packet(op, cmd, &p, &n)
        guard let p else { return [] }
        let a = Array(UnsafeBufferPointer(start: p, count: n))
        tg_free(p, n)
        return a
    }

    /// Hello (op, cmd 0), then the op's own packet; returns what the toy sends back.
    private func exchange(op: UInt8, then second: [UInt8]?, progress: (String) -> Void, firstTimeout: Double = 4) throws -> [UInt8] {
        guard emu.isLoaded else { throw LinkError.notRunning }
        drain(0.05)
        connect(true)
        defer {
            drain(0.05)
            connect(false)
        }
        progress("Saying hello…")
        try send(TamaLink.packet(op: op, cmd: 0))
        _ = try answer(firstTimeout: firstTimeout)
        drain(0.05)
        guard let second else { return [] }
        try send(second)
        Thread.sleep(forTimeInterval: 0.05)
        return try answer(firstTimeout: 8, idleTimeout: 4)
    }

    /// Come home carrying a souvenir and points (GO BACK? › YES on the toy).
    func back(packet: [UInt8], progress: (String) -> Void) throws {
        progress("Walking your Tama home…")
        _ = try exchange(op: 0x15, then: packet, progress: progress)
    }

    /// The wedding (GO BACK? › YES on the toy): the toy comes home married.
    func marry(_ packet: [UInt8], progress: (String) -> Void) throws {
        progress("The wedding is starting…")
        _ = try exchange(op: 0x16, then: packet, progress: progress)
    }
}

/// One app session, like the phone app: as soon as the toy connects TamaiOS
/// says hello and learns which menu the toy is in (Visit, Download, or coming
/// back), then does the right thing by itself.
extension TamaLink {
    static let modeVisit: UInt8 = 0x14, modeBack: UInt8 = 0x15, modeDownload: UInt8 = 0x17

    /// Connect and say hello. Returns the toy's mode; stays connected.
    func probe() throws -> UInt8 {
        guard emu.isLoaded else { throw LinkError.notRunning }
        drain(0.05)
        connect(true)
        do {
            try send(TamaLink.packet(op: 0x17, cmd: 0))
            let a = try answer()
            drain(0.05)
            guard a.count > 0x4C else { throw LinkError.noAnswer }
            hello = a
            emu.linkBusy = false      // stay connected; the toy waits (held) until we continue
            return a[0x4C]
        } catch {
            close()
            throw error
        }
    }

    /// After probe() in Visit mode: the toy comes to town. Returns its visit data.
    func finishVisit() throws -> [UInt8] {
        defer { close() }
        emu.linkBusy = true
        try send(TamaLink.packet(op: 0x14, cmd: 0x34))
        Thread.sleep(forTimeInterval: 0.05)
        let d = try answer(firstTimeout: 8, idleTimeout: 4)
        guard d.count >= 512 else { throw LinkError.noAnswer }
        return d
    }

    /// After probe() in Download mode: deliver one item packet.
    func finishItem(_ pkt: [UInt8]) throws {
        defer { close() }
        emu.linkBusy = true
        try send(pkt)
        _ = try answer(firstTimeout: 6, idleTimeout: 3)
    }

    /// Hang up from Download mode: the toy reacts the moment it has the command, so don't wait the usual
    /// three seconds of silence for a reply that never comes.
    func hangUpQuick(_ pkt: [UInt8]) {
        defer { close() }
        emu.linkBusy = true
        try? send(pkt)
        _ = try? answer(firstTimeout: 1.5, idleTimeout: 0.3)
    }

    func close() {
        emu.linkBusy = true
        drain(0.05)
        connect(false)
    }
}

/// Runs the app side of every connection by itself, like the phone app did:
/// - Visit: your Tama comes to town (date, shop, play).
/// - GO BACK › YES: your Tama comes home — with a wedding if you proposed,
///   otherwise without store items; pickups remain queued for Download.
/// - Download: delivers what's waiting in the bag, or opens TamaDepa.
final class AppLink: ObservableObject {
    static let shared = AppLink()
    @Published var busy = false
    @Published var status = ""
    @Published var openForDownload = false
    @Published var lastMessage: String?
    /// Set when the job is done and the app should close (the message shows on the toy screen).
    @Published var closeWith: String?
    private var running = false

    private func main(_ f: @escaping () -> Void) { DispatchQueue.main.sync(execute: f) }

    func start(emu: Emulator, onDownload: @escaping () -> Void) {
        guard !running, emu.appWaiting, let toy = emu.toy else { return }
        let town = Town.shared
        let st = town.state(toy)
        running = true
        busy = true
        status = "Connecting…"
        let link = TamaLink(emu: emu)
        let progress: (String) -> Void = { m in DispatchQueue.main.async { self.status = m } }
        DispatchQueue.global(qos: .userInitiated).async {
            var msg: String?
            var close = false
            var download = false
            do {
                if st.away {
                    close = true
                    let name = town.name(toy)
                    if st.pending == .marry {
                        guard let s = st.suitor,
                              let pkt = town.marriagePacket(toy, s, babySex: st.babySex, genes: st.genes) else {
                            throw TamaLink.LinkError.writeFailed
                        }
                        try link.marry(pkt, progress: progress)
                        let f = DateFormatter(); f.dateStyle = .medium
                        self.main {
                            var y = town.state(toy)
                            y.married.append("\(f.string(from: Date())): \(name) married \(s.name)")
                            y.away = false; y.pending = .none; y.suitor = nil; y.petName = nil
                            town.save(y, toy)
                            town.invalidateDeviceCache(toy)
                        }
                        emu.note("married \(s.name)")
                        msg = ""
                    } else {
                        try link.back(packet: Town.backPacket(nil, points: 0), progress: progress)
                        self.main {
                            DeviceWallet.shared.refresh(emu)
                            var y = town.state(toy)
                            y.away = false; y.pending = .none; y.suitor = nil
                            town.save(y, toy)
                        }
                        emu.note("ordinary GO BACK: no item attached; pickup bag preserved")
                        msg = "Welcome home! 🏠"
                    }
                    emu.saveNow()
                } else {
                    let mode = try link.probe()
                    let tama = town.name(toy)      // known from the last visit, if any
                    emu.note("app connected, device mode \(String(format: "%02x", mode))")
                    if mode == TamaLink.modeVisit {
                        progress("\(tama) is coming to town…")
                        let d = try link.finishVisit()
                        emu.fastForward(20)       // play the goodbye scene now, while you look around town
                        town.saveVisit(d, toy)
                        let pet = Town.decodeName(d)
                        self.main {
                            var x = town.state(toy)
                            x.away = true
                            x.pending = .none
                            if !pet.isEmpty { x.petName = pet }
                            town.save(x, toy)
                            town.shuffle()
                        }
                        emu.saveNow()
                        msg = nil     // the town itself says who's visiting; no pop-up needed
                    } else if mode == TamaLink.modeDownload {
                        if let gift = town.state(toy).pointGifts?.first(where: { !$0.attempted }) {
                            let balance = emu.withCore { tg_profile_points($0) } ?? -1
                            if balance < 0 || gift.amount > DeviceWallet.maximum - Int(balance) {
                                link.close()
                                msg = "Gift remains queued until the profile is ready and has room below 65,535 G."
                            } else {
                                self.main { town.markGiftAttempt(gift.id, for: toy) }
                                progress("Sending \(gift.amount) Gotchi Points…")
                                try link.finishItem(Town.pointsPacket(gift.amount))
                                self.main { town.removeGift(gift.id, for: toy); DeviceWallet.shared.refresh(emu) }
                                emu.saveNow()
                                close = true
                                msg = "Sent \(gift.amount) Gotchi Points! Watch the device."
                            }
                        } else if let it = town.bag(toy).first, let data = town.bagData(toy, it),
                           let pkt = Town.userItemPacket(data, points: 0) {
                            let pts = 0
                            progress("Delivering \(it.name)…")
                            try link.finishItem(pkt)
                            self.main {
                                town.removeFromBag(toy, it)
                                DeviceWallet.shared.refresh(emu)
                            }
                            emu.saveNow()
                            close = true
                            msg = "Delivered \(it.name)\(pts > 0 ? " and \(pts) Gotchi Points" : "")! 🎁 Watch the device."
                        } else {
                            download = true
                        }
                    } else {
                        link.close()
                    }
                }
            } catch {
                close = false
                emu.note("app connect failed: \(error.localizedDescription)")
                msg = "Couldn't finish talking to your Tama. On the device choose Connection › App again and it'll pick up where it left off."
            }
            DispatchQueue.main.async {
                self.running = false
                self.busy = false
                self.openForDownload = download
                if close {
                    if let msg, !msg.isEmpty { emu.say(msg, seconds: 7) }
                    self.closeWith = msg ?? ""
                } else {
                    self.lastMessage = msg
                }
                if download { onDownload() }
            }
        }
    }

    /// Leaving the app without buying: hang up so the toy isn't left waiting.
    func hangUp(emu: Emulator) {
        guard openForDownload else { return }
        openForDownload = false
        let link = TamaLink(emu: emu)
        // Everything from here to the toy being back on its menu happens out of sight and silently: hang-up,
        // then the CONNECTING and FAIL screens, which run ahead at full speed.
        emu.beginQuiet()
        DispatchQueue.global(qos: .userInitiated).async {
            // Just hanging up leaves the device on CONNECTING for ~20 s. A command it
            // doesn't expect in Download mode ends the session at once and the toy shows FAIL. One press of C
            // on that screen goes back a single page, to the VISIT / DOWNLOAD list (tested on all firmwares),
            // so FAIL is never seen; left alone it would show FAIL for ~7 s and then drop out to the room.
            link.hangUpQuick(TamaLink.packet(op: 0x15, cmd: 0x36))
            emu.fastForward(0.2, keys: [.c])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { emu.endQuiet() }
        }
    }
}

/// WebMeets (tamagotchicenter.com): free item catalog and gift packets for the
/// Meets/On, made by the Tamagotchi Center community.
enum WebMeets {
    static let base = "https://tamagotchicenter.com/api/webmeets"

    struct Item: Codable, Identifiable, Hashable {
        let lang: String?
        let lang_dir: String
        let file_name: String
        let item_name: String
        let item_price: Int?
        let item_type: String
        let food_type: String?
        var id: String { lang_dir + "/" + file_name }
        var name: String {
            item_name.replacingOccurrences(of: "\u{3000}", with: " ").trimmingCharacters(in: .whitespaces)
        }
        var imageURL: URL? {
            let f = file_name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file_name
            return URL(string: "\(WebMeets.base)/resources/item-image/\(lang_dir)/\(f)")
        }
    }

    static func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var c = URLComponents(string: base + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("webmeets-items.json")
    }

    /// The catalog saved last time (instant; refreshed in the background).
    static func cachedItems() -> [Item]? {
        guard let d = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([Item].self, from: d)
    }

    static func items() async throws -> [Item] {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("webmeets-items.json")
        do {
            let d = try await get("/v1/items")
            try? d.write(to: cache, options: .atomic)
            return try JSONDecoder().decode([Item].self, from: d)
        } catch {
            if let d = try? Data(contentsOf: cache), let v = try? JSONDecoder().decode([Item].self, from: d) { return v }
            throw error
        }
    }

    static func itemPacket(_ item: Item, points: Int) async throws -> [UInt8] {
        var q = [URLQueryItem(name: "lang", value: item.lang_dir), URLQueryItem(name: "item", value: item.file_name)]
        if points > 0 { q.append(URLQueryItem(name: "points", value: String(min(points, 99999)))) }
        let d = try await get("/v1/item-message", query: q)
        guard d.count >= 64, d.prefix(6) == Data("TAMAGO".utf8) else { throw URLError(.cannotParseResponse) }
        return [UInt8](d)
    }

    static let categories: [(key: String, title: String, icon: String)] = [
        ("food", "Food", "fork.knife"), ("item", "Items", "gift.fill"), ("accessory", "Accessories", "sparkles"),
        ("wallpaper", "Wallpapers", "photo.fill"), ("stations", "Places", "map.fill"), ("games", "Games", "gamecontroller.fill"),
    ]
}