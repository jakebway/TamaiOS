import SwiftUI

/// TamaDepa: the department store to browse and send food, items, accessories,
/// wallpapers, places, and games to your Tama.
struct TamaDepaView: View {
    @EnvironmentObject var emu: Emulator
    @ObservedObject var town = Town.shared
    @ObservedObject private var wallet = DeviceWallet.shared
    private let balanceTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @ObservedObject private var link = AppLink.shared

    struct Entry: Identifiable, Hashable {
        enum Source: Hashable { case web(WebMeets.Item), pack(PackItem) }
        let id: String
        let name: String
        let kind: String
        let price: Int?
        let note: String?
        let source: Source
        var imageURL: URL? { if case .web(let w) = source { return w.imageURL }; return nil }
    }

    @State private var web: [WebMeets.Item] = []
    @State private var loadError: String?
    @State private var category = "food"
    @State private var search = ""
    @State private var picked: Entry?
    @State private var sending = false
    @State private var progress = ""
    @State private var result: (ok: Bool, text: String)?
    @State private var importing = false
    @State private var custom: (name: String, data: Data)?

    private var isJP: Bool { emu.toy?.romName.contains("(JP") ?? false }
    private var lang: String { isJP ? "jp" : "en" }

    private static func containsJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3040...0x309F).contains(v)   // Hiragana
                || (0x30A0...0x30FF).contains(v)   // Katakana
                || (0x4E00...0x9FFF).contains(v)   // CJK Ideographs
        }
    }

    private static func canonicalKey(_ s: String) -> String {
        s.lowercased().filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
    }

    /// The filtered catalog, merged once (not on every redraw).
    @State private var entries: [Entry] = []

    private func buildEntries() -> [Entry] {
        var out: [Entry] = []
        var seenKeys = Set<String>()
        var seenNames = Set<String>()

        // 1. WebMeets catalog items matching device language (primary source with images)
        for w in web {
            let isStationOrGame = w.item_type == "stations" || w.item_type == "games"
            let hasJapanese = Self.containsJapanese(w.name) || w.lang_dir == "jp"

            if !isJP && hasJapanese && !isStationOrGame { continue }
            if isJP && w.lang_dir == "en" && !isStationOrGame { continue }

            let fileKey = w.item_type + ":" + URL(fileURLWithPath: w.file_name).deletingPathExtension().lastPathComponent.lowercased()
            let nameKey = w.item_type + ":" + Self.canonicalKey(w.name)

            if seenKeys.contains(fileKey) || seenNames.contains(nameKey) { continue }
            seenKeys.insert(fileKey)
            seenNames.insert(nameKey)

            out.append(Entry(id: "w:" + w.id, name: w.name, kind: w.item_type, price: w.item_price,
                             note: w.lang_dir != lang ? "Japan event" : nil, source: .web(w)))
        }

        // 2. Bundled pack items: only add unique items NOT already in WebMeets
        for p in town.items {
            let isStationOrGame = p.kind == "stations" || p.kind == "games"
            let hasJapanese = p.isKana || Self.containsJapanese(p.displayName) || p.lang == "jp"

            if !isJP && hasJapanese && !isStationOrGame { continue }
            if isJP && p.lang == "en" && !isStationOrGame { continue }

            let fileKey = p.kind + ":" + URL(fileURLWithPath: p.file).deletingPathExtension().lastPathComponent.lowercased()
            let nameKey = p.kind + ":" + Self.canonicalKey(p.displayName)

            // Deduplicate against web items by file stem or canonical name
            if seenKeys.contains(fileKey) || seenNames.contains(nameKey) { continue }
            seenKeys.insert(fileKey)
            seenNames.insert(nameKey)

            out.append(Entry(id: "p:\(p.i)", name: p.displayName.capitalized, kind: p.kind, price: nil,
                             note: p.lang != lang ? "Japan event" : nil, source: .pack(p)))
        }

        return out
    }

    private var shown: [Entry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { $0.kind == category && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                walletCard
                connectionCard
                bagCard
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(WebMeets.categories, id: \.key) { c in
                            Button { category = c.key } label: {
                                Label(c.title, systemImage: c.icon)
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Capsule().fill(category == c.key ? Color.blue : Color(.secondarySystemBackground)))
                                    .foregroundStyle(category == c.key ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if category == "accessory" {
                    Label("Accessories are stored upon download and become wearable once your Tama is an adult.", systemImage: "info.circle")
                        .font(.subheadline).foregroundStyle(.secondary).padding(12)
                }
                grid
                DisclosureGroup("Make or import") { ownFileCard }
                if !packReady {
                    Text("The built-in character pack is loading. If it does not finish, use Reload built-in characters in Tamatown Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Catalog by WebMeets (tamagotchicenter.com) and the MyMeets pack (TamaTown).")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .searchable(text: $search, prompt: "Search TamaDepa")
        .navigationTitle("TamaDepa")
        .navigationBarTitleDisplayMode(.inline)
        .background(LinearGradient(colors: [Color.blue.opacity(0.08), Color(.systemBackground)], startPoint: .top, endPoint: .center).ignoresSafeArea())
        .task { wallet.refresh(emu); await load() }
        .onReceive(balanceTimer) { _ in wallet.refresh(emu) }
        .onChange(of: emu.toy?.id) { _ in wallet.refresh(emu) }
        .interactiveDismissDisabled(sending)
        .onChange(of: town.items.count) { _ in entries = buildEntries() }
        .overlay { if sending { BusyOverlay(text: progress) } }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }), titleVisibility: .visible) {
            Button(dialogButton) { if let p = picked { send(p) } }
            Button("Cancel", role: .cancel) { picked = nil }
        }
        .sheet(isPresented: $importing) {
            DocumentPicker { u in
                guard let d = try? Data(contentsOf: u), Town.userItemPacket(d, points: 0) != nil else {
                    result = (false, "That file isn't a Tamagotchi item. Item files start with \"TAMAGO\" (like the .txt files in MyMeets).")
                    return
                }
                let n = Town.userItemName(d)
                custom = (n.isEmpty ? u.deletingPathExtension().lastPathComponent : n, d)
            }.ignoresSafeArea()
        }
        .alert(result?.ok == true ? "TamaDepa" : "Not delivered", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("OK") {}
        } message: { Text(result?.text ?? "") }
    }

    private var packReady: Bool {
        if case .ready = town.pack { return true }
        return false
    }

    /// The toy is connected in Download mode right now.
    private var live: Bool { link.openForDownload }
    private var away: Bool { emu.toy.map { town.state($0).away } ?? false }

    private var walletCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "dollarsign.circle.fill").font(.largeTitle).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.balance.map { "\($0) G" } ?? "— G").font(.system(.title2, design: .rounded).weight(.heavy)).monospacedDigit()
                Text("Current balance from your Tama’s profile").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(live ? "Ready to download" : "Shop now, collect later", systemImage: live ? "checkmark.circle.fill" : "bag.fill")
                .font(.headline).foregroundStyle(live ? Color.green : Color.blue)
            Text(live ? "Choose an item to send directly to your Tama." : "Add items to your pickup bag. On your Tama, choose Connection › App › Download to collect them.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }

    private var hintText: String {
        let name = town.name(emu.toy)
        return away ? "Shopping in town: what you buy goes home with \(name)."
                    : "What you pick goes in the bag. It's delivered by itself next time the device connects (Connection › App › Download)."
    }

    private var hintCard: some View {
        Label(hintText, systemImage: away ? "figure.walk" : "bag.fill")
            .font(.system(.subheadline, design: .rounded)).foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.1)))
    }

    private var dialogTitle: String {
        guard let p = picked else { return "" }
        if p.kind == "wallpaper" { return "Add " + p.name + " to the in-game shop?" }
        if (p.price ?? 0) == 0 { return "Download " + p.name + "?" }
        return (live ? "Buy and send " : "Buy ") + p.name + " for \(max(0, p.price ?? 0)) G?"
    }

    private var dialogButton: String {
        if !live { return "Queue download" }
        if picked?.kind == "wallpaper" { return "Add to shop" }
        return (picked?.price ?? 0) == 0 ? "Download" : "Buy and send"
    }

    @ViewBuilder
    private var bagCard: some View {
        let items = emu.toy.map { town.bag($0) } ?? []
        if !items.isEmpty, let t = emu.toy {
            TownCard(tint: .orange) {
                Label("Pickup bag", systemImage: "bag.fill").font(.system(.headline, design: .rounded)).foregroundStyle(.orange)
                ForEach(items) { it in
                    HStack {
                        Image(systemName: icon(it.kind)).foregroundStyle(.orange)
                        Text(it.name).font(.system(.subheadline, design: .rounded))
                        Spacer()
                        Button(role: .destructive) { town.removeFromBag(t, it) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Text("In-store pickup: connect with Download to collect items. Returning from Visit does not deliver items.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var ownFileCard: some View {
        TownCard(tint: .purple) {
            Label("Custom wallpaper, food, or file", systemImage: "wand.and.stars")
                .font(.system(.headline, design: .rounded)).foregroundStyle(.purple)
            Text("Draw your own wallpaper or food, or import a ready-made file (like Magic Hut).")
                .font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
            if let c = custom {
                Button { sendCustom(c.data, name: c.name) } label: {
                    Label("Send \(c.name)", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
            }
            Button(custom == nil ? "Choose file…" : "Choose another file…") { importing = true }
                .font(.subheadline.weight(.semibold))
            NavigationLink {
                CustomItemMaker()
            } label: {
                Label("Draw your own", systemImage: "paintbrush.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
        }
    }

    @ViewBuilder
    private var grid: some View {
        if web.isEmpty && town.items.isEmpty {
            if let e = loadError {
                VStack(spacing: 10) {
                    Text("Couldn't load TamaDepa").font(.headline)
                    Text(e).font(.caption).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load() } }
                }
                .frame(maxWidth: .infinity).padding(30)
            } else {
                ProgressView("Opening the store…").frame(maxWidth: .infinity).padding(40)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(shown) { it in
                    Button { picked = it } label: { cell(it) }.buttonStyle(.plain)
                }
            }
            if shown.isEmpty {
                Text("Nothing here yet").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
            }
        }
    }

    private func icon(_ kind: String) -> String {
        WebMeets.categories.first { $0.key == kind }?.icon ?? "gift.fill"
    }

    private func cell(_ it: Entry) -> some View {
        VStack(spacing: 6) {
            Group {
                if let u = it.imageURL {
                    AsyncImage(url: u) { img in img.interpolation(.none).resizable().scaledToFit() } placeholder: { Color(.tertiarySystemFill) }
                } else {
                    Image(systemName: icon(it.kind)).font(.title).foregroundStyle(.blue.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.blue.opacity(0.08))
                }
            }
            .frame(width: it.kind == "wallpaper" ? 80 : 52, height: it.kind == "wallpaper" ? 80 : 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(it.name).font(.system(.caption, design: .rounded).weight(.semibold))
                .lineLimit(2).multilineTextAlignment(.center)
            if let n = it.note {
                Text(n).font(.caption2).foregroundStyle(.pink)
            } else if let p = it.price, p > 0 {
                Text(it.kind == "wallpaper" ? "In-game shop: \(p) G" : "\(p) G").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func load() async {
        loadError = nil
        if web.isEmpty, let cached = WebMeets.cachedItems() { web = cached }   // instant
        entries = buildEntries()
        do { web = try await WebMeets.items() } catch { if web.isEmpty { loadError = error.localizedDescription } }
        entries = buildEntries()
    }

    /// Send now if the toy is connected (Download), otherwise put it in the bag.
    private func deliver(name: String, kind: String, cost: Int = 0, packet: @escaping (Int) async throws -> [UInt8]) {
        guard !sending, let toy = emu.toy else { return }
        picked = nil
        let charge = cost == 0 ? 0 : max(0, cost)
        wallet.refresh(emu)
        guard charge == 0 || (wallet.balance.map { $0 >= charge } ?? false) else {
            result = (false, "Not enough Gotchi Points.")
            return
        }
        guard charge == 0 || wallet.adjust(-charge, emu: emu, deviceID: toy.id) else {
            result = (false, "Couldn't update your Tama’s profile balance.")
            return
        }
        let now = live
        let pts = 0
        sending = true
        progress = now ? "Wrapping your item…" : "Putting it in the bag…"
        Task {
            do {
                let pkt = try await packet(pts)
                if !now {
                    town.addToBag(toy, name: name, kind: kind, packet: pkt)
                    sending = false
                    result = (true, "\(name) is ready for pickup. Connect with Download to collect it.")
                    return
                }
                let tl = TamaLink(emu: emu)
                link.openForDownload = false
                progress = "Sending \(name)…"
                try await Task.detached(priority: .userInitiated) { try tl.finishItem(pkt) }.value
                emu.note("gift sent: \(name) points=\(pts)")
                wallet.refresh(emu)
                sending = false
                link.closeWith = "Transfer completed for \(name). Check your Tama."
            } catch {
                if charge > 0 { _ = wallet.adjust(charge, emu: emu, deviceID: toy.id) }
                emu.note("gift failed: \(error.localizedDescription)")
                sending = false
                result = (false, error.localizedDescription)
            }
        }
    }

    private func send(_ it: Entry) {
        guard !sending else { return }
        let cost = it.kind == "wallpaper" ? 0 : max(0, it.price ?? 0)
        wallet.refresh(emu)
        guard cost == 0 || (wallet.balance.map { $0 >= cost } ?? false) else {
            result = (false, "Not enough Gotchi Points. This item costs \(cost) G.")
            return
        }
        switch it.source {
        case .web(let w):
            deliver(name: it.name, kind: it.kind, cost: cost) { pts in try await WebMeets.itemPacket(w, points: pts) }
        case .pack(let p):
            deliver(name: it.name, kind: it.kind, cost: cost) { pts in
                guard let pk = Town.shared.itemPacket(p, points: pts) else { throw URLError(.cannotDecodeContentData) }
                return pk
            }
        }
    }

    private func sendCustom(_ d: Data, name: String) {
        deliver(name: name, kind: "stations") { pts in
            guard let pk = Town.userItemPacket(d, points: pts) else { throw URLError(.cannotDecodeContentData) }
            return pk
        }
    }
}
