import SwiftUI
import PhotosUI

/// Tamatown, TamaiOS's built-in version of the original Tamagotchi app.
/// Visit: your Tama spends the day in town (Tama ♥ Party, TamaDepa, Arcade).
/// Download: straight to TamaDepa to get new items.
struct TamatownView: View {
    @EnvironmentObject var emu: Emulator
    @Environment(\.dismiss) private var dismiss
    @State private var path: [TownPlace] = []
    @ObservedObject private var link = AppLink.shared
    /// The toy chose Download: only the store works then.
    @State private var downloadOnly = false
    @ObservedObject private var town = Town.shared

    /// Tamatown itself only appears while your Tama is visiting.
    private var inTown: Bool { emu.toy.map { town.state($0).away } ?? false }

    /// The device is connecting and we don't know yet whether it's a Visit or a
    /// Download: show a clean arrival screen instead of a half-loaded store.
    private var arriving: Bool { !downloadOnly && (link.busy || (emu.appWaiting && !inTown)) }

    @ViewBuilder private var root: some View {
        if arriving {
            ArrivalView(status: link.status)
        } else if inTown && !downloadOnly {
            TownSquare(path: $path, onHome: { leave() }).navigationTitle("Tamatown")
                .toolbarColorScheme(.light, for: .navigationBar)   // the town is always a light pastel scene: dark title and buttons
                .toolbar { ToolbarItem(placement: .principal) { TownTitle() } }
        } else {
            TamaDepaView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        NavigationLink(value: TownPlace.settings) { Image(systemName: "gearshape.fill") }
                    }
                }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { leave() } } }
                .navigationDestination(for: TownPlace.self) { place in
                    place.view.environmentObject(emu)
                }
        }
        .tint(.pink)
        .overlay { if link.busy && downloadOnly { BusyOverlay(text: link.status) } }
        .alert("Tamatown", isPresented: Binding(get: { link.lastMessage != nil }, set: { if !$0 { link.lastMessage = nil } })) {
            Button("OK") {}
        } message: { Text(link.lastMessage ?? "") }
        .onAppear {
            emu.holdForApp = true      // the toy waits patiently while you're in here
            link.closeWith = nil
            Town.shared.loadIfPresent()
            connect()
        }
        .onChange(of: emu.appWaiting) { w in if w { connect() } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TamaiOSStartWedding"))) { _ in
            leave()
        }
        .onChange(of: path) { p in
            // Home = leave Tamatown; the device then asks "GO BACK?"
            if p.last == .home { path.removeLast(); leave() }
        }
        .onChange(of: link.closeWith) { m in
            guard let m else { return }
            _ = m
            link.closeWith = nil
            dismiss()
        }
        .onDisappear {
            link.hangUp(emu: emu)
            emu.holdForApp = false
            // Leaving Tamatown = going home: answer the device's GO BACK? with YES by
            // itself (B shows the question, A moves to YES, B confirms); the device
            // then calls the app and the homecoming runs quietly in the background.
            if !headingHome, let t = emu.toy, Town.shared.state(t).away, !link.busy, !emu.appWaiting {
                emu.answerGoBack()
            }
        }
    }

    @State private var headingHome = false

    /// Done / Home. If your Tama is in town this means "go home": the device is
    /// answered (GO BACK? › YES) before the sheet closes, so you never see I'M OUT.
    private func leave() {
        guard let t = emu.toy, Town.shared.state(t).away, !link.busy, !emu.appWaiting else { dismiss(); return }
        headingHome = true
        emu.holdForApp = false
        emu.answerGoBack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
    }

    /// Like the phone app: as soon as the toy connects, see which menu it chose.
    /// Visit brings your Tama to town; Download opens TamaDepa.
    private func connect() {
        link.start(emu: emu) {
            path = []
            downloadOnly = true
        }
    }
}

enum TownPlace: Hashable, CaseIterable {
    case home, party, arcade, depa, settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .party: return "Tama ♥ Party"
        case .arcade: return "Arcade"
        case .depa: return "TamaDepa"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .party: return "heart.fill"
        case .arcade: return "gamecontroller.fill"
        case .depa: return "bag.fill"
        case .settings: return "gearshape.fill"
        }
    }
    var tint: Color {
        switch self {
        case .home: return .orange
        case .party: return .pink
        case .arcade: return .purple
        case .depa: return .blue
        case .settings: return .gray
        }
    }
    var blurb: String {
        switch self {
        case .home: return "Leave Tamatown and head home"
        case .party: return "Dates, marriage & gene mixing"
        case .arcade: return "Play games, win Gotchi Points"
        case .depa: return "Shop food, items, places & more"
        case .settings: return "Character pack & extras"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .home: PlaceScreen(place: self) { TownView(mode: .home) }
        case .party: PlaceScreen(place: self) { TownView(mode: .party) }
        case .arcade: ArcadeView()
        case .depa: TamaDepaView()
        case .settings: TownSettingsView()
        }
    }
}

/// A place's page: coloured header, then its content.
struct PlaceScreen<C: View>: View {
    let place: TownPlace
    @ViewBuilder let content: C
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(16)
        }
        .background(LinearGradient(colors: [place.tint.opacity(0.10), Color(.systemBackground)], startPoint: .top, endPoint: .center).ignoresSafeArea())
        .navigationTitle(place.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - the town square

struct TownSquare: View {
    @Binding var path: [TownPlace]
    /// Home leaves Tamatown (the device then asks "GO BACK?").
    var onHome: () -> Void = {}

    private func open(_ p: TownPlace) {
        if p == .home { onHome() } else { path.append(p) }
    }
    @EnvironmentObject var emu: Emulator
    @ObservedObject var town = Town.shared
    private var away: Bool { emu.toy.map { town.state($0).away } ?? false }
    /// Tama ♥ Party is for grown-ups only (like the official app); a child or teen can't even go in.
    private var tooYoung: Bool { emu.toy.flatMap { town.visitInfo($0) }.map { !$0.adult } ?? false }
    @State private var gateAlert = false
    private func enter(_ p: TownPlace) {
        if p == .party && tooYoung { gateAlert = true } else { open(p) }
    }
    private var sceneAspect: CGFloat {
        if town.customBG == nil, TownScene.builtIn == nil, town.wallpaper(town.activeWallpaper) != nil { return 1.0 }
        guard let bg = town.customBG ?? TownScene.builtIn, bg.size.height > 0 else { return 1.25 }
        return min(2.2, max(1.0, bg.size.width / bg.size.height))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                TownScene(open: away) { p in
                    if p != .depa && (away || p == .home || p == .settings) { enter(p) }
                }
                    .aspectRatio(sceneAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                statusBanner
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(away ? [TownPlace.party, .arcade, .home] : [TownPlace.home], id: \.self) { p in
                        Button { enter(p) } label: { PlaceTile(place: p).opacity(p == .party && tooYoung ? 0.45 : 1) }.buttonStyle(.plain)
                    }
                }
                Button { path.append(.settings) } label: {
                    Label("Settings", systemImage: "gearshape.fill").font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(LinearGradient(colors: [Color(red: 1, green: 0.93, blue: 0.97), Color(red: 0.93, green: 0.92, blue: 1)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .alert("Tama ♥ Party is for grown-ups", isPresented: $gateAlert) {
            Button("OK") {}
        } message: { Text("\(town.name(emu.toy)) can go to Tama ♥ Party once grown up. The Arcade is open meanwhile.") }
    }

    private var statusBanner: some View {
        let st = emu.toy.map { town.state($0) }
        let away = st?.away ?? false
        let name = town.name(emu.toy)
        return HStack(spacing: 12) {
            Image(systemName: emu.appWaiting ? "dot.radiowaves.left.and.right" : (away ? "figure.walk" : "house.fill"))
                .font(.title2)
                .foregroundStyle(emu.appWaiting ? .green : (away ? .purple : .orange))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(emu.appWaiting ? "\(name) is connected" : (away ? "\(name) is in town" : "\(name) is at home"))
                    .font(.system(.headline, design: .rounded))
                Text(emu.appWaiting ? "Your device will wait for you here." :
                        (away ? (tooYoung ? "Play in the Arcade. Tama ♥ Party opens once grown up." : "Go to Tama ♥ Party to find a partner.") : "On the device: Connection › App › Visit to come to town, or Download to shop."))
                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
    }
}

struct PlaceTile: View {
    let place: TownPlace
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: place.icon)
                .font(.title2.weight(.bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(place.tint.gradient))
            Text(place.title).font(.system(.headline, design: .rounded))
            Text(place.blurb).font(.system(.caption, design: .rounded)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(place.tint.opacity(0.35), lineWidth: 1.5))
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The town picture: castle in the middle, Tama ♥ Party on the left, TamaDepa
/// on the right, the Arcade in front, and Tamas walking around. Every building
/// can be tapped.
struct TownScene: View {
    /// Your Tama is in town (Visit): every place is open.
    let open: Bool
    let go: (TownPlace) -> Void
    @ObservedObject var town = Town.shared
    @EnvironmentObject var emu: Emulator
    @State private var sim = WanderSim()
    /// The Tamas walking around are the ones you can date at Tama ♥ Party.
    private var walkers: [Suitor] { town.crowd(emu.toy, limit: 8) }
    static let sparkX: [CGFloat] = [0.08, 0.22, 0.36, 0.55, 0.68, 0.83, 0.93, 0.47, 0.15]
    static let sparkY: [CGFloat] = [0.10, 0.06, 0.15, 0.05, 0.12, 0.07, 0.18, 0.22, 0.24]

    var body: some View {
        GeometryReader { g in
            if let bg = town.customBG ?? TownScene.builtIn {
                customScene(bg, g.size.width, g.size.height)
            } else if let wp = town.wallpaper(town.activeWallpaper) {
                customScene(UIImage(cgImage: wp), g.size.width, g.size.height, pixel: true)
            } else {
                ZStack {
                    sky(g.size.width, g.size.height)
                    ground(g.size.width, g.size.height)
                    buildings(g.size.width, g.size.height)
                    walkersLayer(g.size.width, g.size.height)
                    signs(g.size.width, g.size.height)
                }
            }
        }
    }

    private static let skyColors: [Color] = [Color(red: 1.0, green: 0.78, blue: 0.90), Color(red: 0.86, green: 0.84, blue: 1.0), Color(red: 0.78, green: 0.92, blue: 1.0)]

    private func sparkle(_ i: Int, _ w: CGFloat, _ h: CGFloat) -> some View {
        let size: CGFloat = i % 3 == 0 ? 0.035 : 0.022
        let x: CGFloat = w * TownScene.sparkX[i]
        let y: CGFloat = h * TownScene.sparkY[i]
        return Image(systemName: "sparkle")
            .font(.system(size: w * size))
            .foregroundStyle(Color.white.opacity(0.9))
            .position(x: x, y: y)
    }

    private func sky(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: TownScene.skyColors, startPoint: .top, endPoint: .bottom)
            ForEach(0..<9, id: \.self) { i in sparkle(i, w, h) }
            cloud(w * 0.20).position(x: w * 0.20, y: h * 0.16)
            cloud(w * 0.16).position(x: w * 0.80, y: h * 0.12)
        }
    }

    private func ground(_ w: CGFloat, _ h: CGFloat) -> some View {
        let hill1 = Color(red: 0.62, green: 0.86, blue: 0.56), hill2 = Color(red: 0.55, green: 0.82, blue: 0.52)
        let square = Color(red: 0.99, green: 0.93, blue: 0.80), edge = Color(red: 0.96, green: 0.86, blue: 0.70)
        return ZStack {
            Ellipse().fill(hill1).frame(width: w * 0.9, height: h * 0.4).position(x: w * 0.18, y: h * 0.74)
            Ellipse().fill(hill2).frame(width: w * 0.9, height: h * 0.4).position(x: w * 0.85, y: h * 0.76)
            Rectangle().fill(square).frame(height: h * 0.30).position(x: w / 2, y: h * 0.86)
            Rectangle().fill(edge).frame(height: h * 0.012).position(x: w / 2, y: h * 0.715)
        }
    }

    private func buildings(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            Button { go(.party) } label: { castle(w: w, h: h) }
                .buttonStyle(.plain)
                .position(x: w * 0.5, y: h * 0.47)
            Button { go(.party) } label: { partyHall(w: w, h: h) }
                .buttonStyle(.plain)
                .position(x: w * 0.17, y: h * 0.53)

        }
    }

    private func walker(_ a: WanderSim.Actor, _ s: Suitor, _ t: Double, _ w: CGFloat, _ h: CGFloat) -> some View {
        let walking = a.state == .walk
        let hop: Double = walking ? abs(sin(t * 4 + a.phase)) * 0.005 : 0
        let near = (a.lane - 0.7) / 0.25      // a little bigger further down, like it's closer
        let size: CGFloat = w * CGFloat(0.105 + 0.025 * min(1, max(0, near)))
        let x: CGFloat = w * CGFloat(a.x)
        let y: CGFloat = h * CGFloat(a.lane - hop)
        return ZStack {
            CharacterPicture(image: town.image(s))
                .frame(width: size, height: size)
                .scaleEffect(x: CGFloat(a.facing) * -1, y: 1)
                .position(x: x, y: y)
            if a.state == .idle && a.line.isEmpty {
                Text(a.name.capitalized)
                    .font(.system(size: max(8, w * 0.022), weight: .bold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.85)))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .position(x: x, y: y + size * 0.55)
            }
            if !a.line.isEmpty {
                SpeechBubble(text: a.line, size: max(8, w * 0.024))
                    .position(x: min(w * 0.72, max(w * 0.28, x)), y: y - size * 1.15)
            }
        }
    }

    private func walkersLayer(_ w: CGFloat, _ h: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { tl in
            let now = tl.date.timeIntervalSinceReferenceDate
            let singles = town.crowd(emu.toy, limit: 10)
            let _ = sim.sync(singles, now: now)
            let _ = sim.step(now: now)
            ZStack {
                ForEach(sim.actors.indices.sorted(by: { sim.actors[$0].lane < sim.actors[$1].lane }), id: \.self) { i in
                    if i < singles.count { walker(sim.actors[i], singles[i], now, w, h) }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func signs(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            Button { go(.arcade) } label: { arcadeSign(w: w) }
                .buttonStyle(.plain)
                .position(x: w * 0.5, y: h * 0.80)
            // place labels along the bottom, like the original app
            HStack(spacing: w * 0.02) {
                if open { label("Tama ♥ Party", .pink) { go(.party) } }
                if open { label("Arcade", .purple) { go(.arcade) } }
            }
            .position(x: w / 2, y: h * 0.94)
        }
    }

    /// TamaiOS's own town picture (drawn at build time by tools/town.py).
    static let builtIn: UIImage? = UIImage(named: "TownBackground")

    /// The town picture: tap the left for Tama ♥ Party, the middle for
    /// TamaDepa, the right for the Arcade.
    private func hotspot(_ place: TownPlace, _ w: CGFloat, _ h: CGFloat, _ x: CGFloat) -> some View {
        Button { go(place) } label: { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .frame(width: w / 3, height: h * 0.8)
            .position(x: w * x, y: h * 0.5)
    }

    private func customScene(_ bg: UIImage, _ w: CGFloat, _ h: CGFloat, pixel: Bool = false) -> some View {
        ZStack {
            if pixel, let cg = bg.cgImage {
                PixelBackdrop(image: cg).frame(width: w, height: h)
            } else {
                Image(uiImage: bg).resizable().scaledToFill().frame(width: w, height: h).clipped()
            }
            hotspot(.party, w, h, 1.0 / 6)
            hotspot(.arcade, w, h, 5.0 / 6)
            walkersLayer(w, h)
            HStack(spacing: w * 0.02) {
                label("Tama ♥ Party", .pink) { go(.party) }
                label("Arcade", .purple) { go(.arcade) }
            }
            .position(x: w / 2, y: h * 0.92)
        }
    }

    private func cloud(_ s: CGFloat) -> some View {
        ZStack {
            Capsule().fill(.white).frame(width: s, height: s * 0.32)
            Circle().fill(.white).frame(width: s * 0.42).offset(x: -s * 0.14, y: -s * 0.12)
            Circle().fill(.white).frame(width: s * 0.32).offset(x: s * 0.14, y: -s * 0.10)
        }
        .opacity(0.95)
    }

    private static let roofBlue = Color(red: 0.45, green: 0.62, blue: 0.98)
    private static let wallColor = Color(red: 0.90, green: 0.91, blue: 1.0)
    private static let edgeInk = inkLine.opacity(0.6)

    private func roof(_ size: CGFloat) -> some View {
        Triangle().fill(TownScene.roofBlue)
            .overlay(Triangle().stroke(TownScene.edgeInk, lineWidth: 1.5))
            .frame(width: size, height: size)
    }

    private func wallBlock(_ width: CGFloat, _ height: CGFloat) -> some View {
        Rectangle().fill(TownScene.wallColor)
            .overlay(Rectangle().stroke(TownScene.edgeInk, lineWidth: 1.5))
            .frame(width: width, height: height)
    }

    private func tower(_ w: CGFloat, _ h: CGFloat, _ side: CGFloat) -> some View {
        let dx: CGFloat = side * w * 0.12
        return VStack(spacing: 0) {
            roof(w * 0.11)
            wallBlock(w * 0.08, h * 0.20)
        }
        .offset(x: dx, y: h * 0.03)
    }

    private func gate(_ w: CGFloat, _ h: CGFloat) -> some View {
        let door = Color(red: 1, green: 0.85, blue: 0.5)
        return wallBlock(w * 0.26, h * 0.12)
            .overlay(
                Image(systemName: "heart.fill").font(.system(size: w * 0.045)).foregroundStyle(Color.pink)
                    .padding(w * 0.012).background(Capsule().fill(door))
                    .offset(y: h * 0.015)
            )
    }

    private func castle(w: CGFloat, h: CGFloat) -> some View {
        let gem = Color(red: 0.4, green: 0.8, blue: 1)
        return ZStack {
            tower(w, h, -1)
            tower(w, h, 1)
            VStack(spacing: 0) {
                roof(w * 0.16)
                wallBlock(w * 0.13, h * 0.13)
                gate(w, h)
            }
            Image(systemName: "diamond.fill").font(.system(size: w * 0.05)).foregroundStyle(gem).offset(y: h * -0.17)
        }
        .frame(width: w * 0.36, height: h * 0.46)
        .contentShape(Rectangle())
    }

    private static let balloonColors: [Color] = [.red, .yellow, .blue]

    private func balloon(_ i: Int, _ w: CGFloat, _ h: CGFloat) -> some View {
        let dx: CGFloat = w * (CGFloat(i) * 0.03 - 0.12)
        let dy: CGFloat = h * -(0.20 + CGFloat(i % 2) * 0.03)
        return Circle().fill(TownScene.balloonColors[i]).frame(width: w * 0.035, height: w * 0.035).offset(x: dx, y: dy)
    }

    private func partyHall(w: CGFloat, h: CGFloat) -> some View {
        let pink = Color(red: 1, green: 0.72, blue: 0.85)
        let r: CGFloat = w * 0.04
        return ZStack {
            RoundedRectangle(cornerRadius: r).fill(pink)
                .overlay(RoundedRectangle(cornerRadius: r).stroke(TownScene.edgeInk, lineWidth: 1.5))
                .frame(width: w * 0.25, height: h * 0.26)
                .offset(y: h * 0.04)
            Image(systemName: "heart.fill").font(.system(size: w * 0.15)).foregroundStyle(Color.red.opacity(0.85))
                .shadow(color: .white, radius: 0, x: 2, y: 2)
                .offset(y: h * -0.11)
            ForEach(0..<3, id: \.self) { i in balloon(i, w, h) }
            RoundedRectangle(cornerRadius: w * 0.02).fill(Color.white).frame(width: w * 0.07, height: h * 0.09).offset(y: h * 0.12)
        }
        .frame(width: w * 0.30, height: h * 0.45)
        .contentShape(Rectangle())
    }

    private func depa(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: w * 0.02).fill(Color(red: 1.0, green: 0.96, blue: 0.82))
                .overlay(RoundedRectangle(cornerRadius: w * 0.02).stroke(inkLine.opacity(0.6), lineWidth: 1.5))
                .frame(width: w * 0.24, height: h * 0.32)
            // striped awning
            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in Rectangle().fill(i % 2 == 0 ? Color.pink : Color.white) }
            }
            .frame(width: w * 0.27, height: h * 0.05)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .offset(y: -h * 0.10)
            Image(systemName: "bag.fill").font(.system(size: w * 0.07)).foregroundStyle(.blue.opacity(0.8)).offset(y: h * 0.02)
            Text("TAMADEPOT").font(.system(size: w * 0.028, weight: .heavy, design: .rounded)).foregroundStyle(.pink).offset(y: -h * 0.15)
        }
        .frame(width: w * 0.28, height: h * 0.42)
        .contentShape(Rectangle())
    }

    private func arcadeSign(w: CGFloat) -> some View {
        Text("GAME")
            .font(.system(size: w * 0.07, weight: .black, design: .rounded))
            .foregroundStyle(LinearGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple], startPoint: .leading, endPoint: .trailing))
            .padding(.horizontal, w * 0.03).padding(.vertical, w * 0.008)
            .background(Capsule().fill(.white))
            .overlay(Capsule().stroke(inkLine.opacity(0.5), lineWidth: 1.5))
            .rotationEffect(.degrees(-6))
    }

    private func label(_ text: String, _ c: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(c.gradient))
                .overlay(Capsule().stroke(.white, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func cornerButton(_ icon: String, _ text: String, _ c: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundStyle(c)
                Text(text).font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(c)
            }
            .frame(width: 50, height: 50)
            .background(Circle().fill(.white))
            .overlay(Circle().stroke(c.opacity(0.6), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - settings

struct TownSettingsView: View {
    @ObservedObject var town = Town.shared
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @ObservedObject private var wallet = DeviceWallet.shared

    var body: some View {
        List {
            Section("Character pack") {
                switch town.pack {
                case .ready(let n): Label("\(n) characters, \(town.items.count) shop items", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case .loading: ProgressView()
                case .missing: Text("Preparing built-in assets…")
                case .failed(let e): Text(e).foregroundStyle(.orange)
                }
                Button("Reload built-in characters") { town.reloadBundledPack() }
            }
            Section {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Choose a town picture…", systemImage: "photo.on.rectangle")
                }
                if town.customBG != nil {
                    Button("Use the built-in town", role: .destructive) { town.setBackground(nil) }
                }
            } header: {
                Text("Town picture")
            } footer: {
                Text("Use any picture you like as the town — for example a screenshot of the original app from your own phone. Tap the left of it for Tama ♥ Party, the right for the Arcade. TamaDepa is available in Download mode only.")
            }
            Section {
                Button { town.wallpaperIndex = -1; town.setBackground(nil) } label: {
                    HStack {
                        Label("Automatic (follows the time of day)", systemImage: "clock")
                        Spacer()
                        if town.customBG == nil && town.wallpaperIndex < 0 { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(town.niceWallpapers, id: \.self) { n in
                        Button { town.wallpaperIndex = n; town.setBackground(nil) } label: {
                            Group {
                                if let img = town.wallpaper(n) {
                                    Image(decorative: img, scale: 1).interpolation(.none).resizable().scaledToFill()
                                } else { Color(.tertiarySystemFill) }
                            }
                            .frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(town.customBG == nil && town.wallpaperIndex == n ? Color.accentColor : Color.clear, lineWidth: 3))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Town wallpaper")
            } footer: {
                Text("The Tama wallpapers from the character pack. Choosing one replaces your own town picture.")
            }
            Section("Gotchi Points") {
                Text("Profile balance: " + (wallet.balance.map { "\($0) G" } ?? "unavailable"))
                Text("Win more in the Arcade. They go home with your Tama, or with the next delivery.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Thanks") {
                Text("Characters and shop items: the MyMeets pack (TamaTown).")
                Text("Gift catalog: WebMeets (tamagotchicenter.com).")
                Text("Emulator core: tg18-emu by oreo-fox.")
            }
        }
        .navigationTitle("Tamatown Settings")
        .onChange(of: photo) { item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self) { town.setBackground(d) }
                photo = nil
            }
        }
        .sheet(isPresented: $importing) {
            DocumentPicker { u in if let d = try? Data(contentsOf: u) { town.importPack(d) } }.ignoresSafeArea()
        }
    }
}


/// Shown for the moment the device is connecting: the town picture with a
/// friendly status, instead of a spinner over a store that isn't needed yet.
struct ArrivalView: View {
    let status: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.93), Color(red: 0.86, green: 0.9, blue: 1)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView().tint(.pink)
                Text(status.isEmpty ? "Connecting…" : status)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Color(red: 0.35, green: 0.2, blue: 0.45))
            }
        }
    }
}

/// The town is always a light pastel scene, so its title is drawn in its own colours (a plain navigation title
/// turns white in dark mode and disappears into the pink).
struct TownTitle: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .heavy))
            Text("Tamatown")
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .tracking(0.6)
            Image(systemName: "sparkle").font(.system(size: 11, weight: .heavy))
        }
        .foregroundStyle(LinearGradient(colors: [Color(red: 0.88, green: 0.18, blue: 0.50), Color(red: 0.50, green: 0.22, blue: 0.86)],
                                        startPoint: .leading, endPoint: .trailing))
        .shadow(color: .white.opacity(0.9), radius: 0, x: 0, y: 1)
        .shadow(color: Color(red: 0.88, green: 0.18, blue: 0.50).opacity(0.18), radius: 6, y: 2)
        .accessibilityAddTraits(.isHeader)
    }
}
