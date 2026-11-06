import SwiftUI

/// TamaiOS Town: your Tama visits, goes on dates and gets married — the part of
/// the old Tamagotchi app that sent your Tama home with a baby.
struct TownView: View {
    enum Mode { case party, home }
    var mode: Mode = .party
    @EnvironmentObject var emu: Emulator
    @ObservedObject var town = Town.shared

    @State private var alert: (title: String, text: String)?
    @State private var chosen: Suitor?
    @State private var designing = false
    @State private var importing = false

    private var toy: Toy? { emu.toy }
    private var packError: String? {
        if case .failed(let e) = town.pack { return e }
        return nil
    }
    private var st: Town.State { toy.map { town.state($0) } ?? Town.State() }
    private var tamaName: String { town.name(toy) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch town.pack {
            case .ready: ready
            case .loading: ProgressView("Getting TamaiOS Town ready…").frame(maxWidth: .infinity).padding(40)
            case .missing: ProgressView("Loading built-in characters…").frame(maxWidth: .infinity).padding(40)
            case .failed: packCard
            }
        }
        .onAppear { town.loadIfPresent() }
        .sheet(item: $chosen) { s in
            SuitorSheet(suitor: s, tamaName: tamaName, adult: toy.flatMap { town.visitInfo($0)?.adult } ?? true) { babySex, genes in
                propose(s, babySex: babySex, genes: genes)
            }
        }
        .sheet(isPresented: $designing) { DesignView { s in designing = false; chosen = s } }
        .sheet(isPresented: $importing) {
            DocumentPicker { u in
                if let d = try? Data(contentsOf: u) { town.importPack(d) }
            }.ignoresSafeArea()
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK") {}
        } message: { Text(alert?.text ?? "") }
    }

    // MARK: character pack

    private var packCard: some View {
        TownCard(tint: .orange) {
            Label("Built-in characters unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.orange)
            Text(packError ?? "The included MyMeets archive could not be loaded.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Retry included assets") { town.reloadBundledPack() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: main town

    @ViewBuilder
    private var ready: some View {
        if !st.away {
            visitCard
        } else if st.pending != .none {
            pendingCard
        } else if mode == .home {
            TownCard(tint: .purple) {
                Label("\(tamaName) is out in town", systemImage: "figure.walk")
                    .font(.system(.headline, design: .rounded)).foregroundStyle(.purple)
                Text("Date at Tama ♥ Party and play in the Arcade. Souvenirs and Gotchi Points go home with \(tamaName).")
                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
                comeHomeHint
            }
        } else {
            awayHeader
            suitorGrid
            comeHomeHint
        }
        if !st.married.isEmpty {
            TownCard(tint: .yellow) {
                Label("Family album", systemImage: "heart.text.square.fill")
                    .font(.system(.headline, design: .rounded)).foregroundStyle(.orange)
                ForEach(Array(st.married.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.system(.footnote, design: .rounded))
                }
            }
        }
        Text("Characters from the MyMeets pack (TamaTown). Genes mixed on your iPhone, the way the official app did.")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }

    private var visitCard: some View {
        TownCard(tint: .pink) {
            Label("\(tamaName) isn't in town yet", systemImage: "figure.walk.motion")
                .font(.system(.headline, design: .rounded)).foregroundStyle(.pink)
            Text("On the device choose Connection › App › Visit. TamaiOS brings your Tama to town by itself, then you can come here to meet someone.")
                .font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
            if let t = toy, FileManager.default.fileExists(atPath: town.visitURL(t).path) {
                Button("My Tama already left home (shows I'M OUT)") {
                    var x = town.state(t); x.away = true; x.pending = .none; town.save(x, t)
                }
                .font(.footnote)
            }
        }
    }

    private var awayHeader: some View {
        let info = toy.flatMap { town.visitInfo($0) }
        return TownCard(tint: .purple) {
            HStack {
                Image(systemName: "heart.fill").font(.largeTitle).foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(tamaName) is in town!").font(.system(.headline, design: .rounded))
                    Text("Tap someone to go on a date. When it's love, propose!")
                        .font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            if let info, !info.adult {
                Label("\(tamaName) isn't a grown-up yet, so can't marry (like the official app). Dates are still fine.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var suitorGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Singles nearby").font(.system(.title3, design: .rounded).weight(.bold))
                Spacer()
                Button { withAnimation { town.shuffle() } } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(.bordered)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ForEach(town.suitors) { s in
                    Button { chosen = s } label: {
                        VStack(spacing: 4) {
                            CharacterPicture(image: town.image(s)).frame(width: 80, height: 80)
                            Text(s.name).font(.system(.subheadline, design: .rounded).weight(.heavy))
                            Text(s.isMix ? "One of a kind" : " ").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.pink)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 136)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                }
                Button { designing = true } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "paintpalette.fill").font(.largeTitle).foregroundStyle(.pink)
                        Text("Design your own").font(.system(.subheadline, design: .rounded).weight(.bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 128)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.pink.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6])))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pendingCard: some View {
        TownCard(tint: .pink) {
            if st.pending == .marry, let s = st.suitor {
                HStack(spacing: 12) {
                    CharacterPicture(image: town.image(s)).frame(width: 72, height: 72)
                    VStack(alignment: .leading) {
                        Text("\(s.name) said YES!").font(.system(.title3, design: .rounded).weight(.bold))
                        Text("Now send \(tamaName) home for the wedding.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Heading home 🏠").font(.system(.title3, design: .rounded).weight(.bold))
            }
            step(1, "Tap Home or Done to head home.")
            step(2, "The wedding happens on the way, all by itself.")
            step(3, "Watch your device for the egg!")
            Button("Change my mind") { setPending(.none, nil) }.font(.footnote)
        }
    }

    private var comeHomeHint: some View {
        Label("To come home, tap Home or Done. TamaiOS takes care of the rest.", systemImage: "house.fill")
            .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
    }

    private func step(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(.caption, design: .rounded).weight(.heavy)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Color.pink))
            Text(s).font(.system(.subheadline, design: .rounded))
        }
    }

    // MARK: actions

    private func setPending(_ p: Town.Pending, _ s: Suitor?, babySex: Int = 2, genes: Int = 0) {
        guard let t = toy else { return }
        var x = town.state(t)
        x.pending = p
        x.suitor = s
        x.babySex = babySex
        x.genes = genes
        town.save(x, t)
    }

    private func propose(_ s: Suitor, babySex: Int, genes: Int) {
        // like the official app, only grown-ups can marry
        if let toy, let info = town.visitInfo(toy), !info.adult { return }
        chosen = nil
        guard st.away, st.pending == .none, !AppLink.shared.busy else { return }
        setPending(.marry, s, babySex: babySex, genes: genes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: Notification.Name("TamaiOSStartWedding"), object: nil)
        }
    }
}

// MARK: - pieces

struct TownCard<C: View>: View {
    let tint: Color
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1.5))
    }
}

struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.4)
                Text(text).font(.system(.headline, design: .rounded)).multilineTextAlignment(.center)
                Text("Keep TamaiOS open").font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        }
    }
}

