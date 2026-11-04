import SwiftUI
import UIKit

// MARK: - shared bits

/// A gene picture (one part on its own); shows a dash when the part is empty.
struct GenePicture: View {
    let image: CGImage?
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
        } else {
            Image(systemName: "minus").font(.title3.weight(.bold)).foregroundStyle(Color.secondary.opacity(0.6))
        }
    }
}

private func tick() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

/// A wallpaper drawn pixel-perfect (a whole number of screen pixels per picture pixel), centred, with a soft
/// blurred copy of itself filling any space around it, so it is never stretched or cropped.
struct PixelBackdrop: View {
    let image: CGImage
    var body: some View {
        GeometryReader { g in
            let scale = UIScreen.main.scale
            let side = min(g.size.width, g.size.height)
            let k = max(1, floor(side * scale / CGFloat(image.width)))
            let s = CGFloat(image.width) * k / scale
            ZStack {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height).blur(radius: 22).clipped()
                Image(decorative: image, scale: 1).interpolation(.none).resizable().frame(width: s, height: s)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// The picture behind a character: one of the pack's Tama wallpapers, changing smoothly with the situation.
private struct Backdrop: View {
    @ObservedObject var town = Town.shared
    let index: Int
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let img = town.wallpaper(index) {
                PixelBackdrop(image: img).id(index).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: index)
    }
}

// MARK: - A date

/// A date: spend time together until the hearts are full, then propose.
struct SuitorSheet: View {
    let suitor: Suitor
    let tamaName: String
    let adult: Bool
    let onPropose: (_ babySex: Int, _ genes: Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var town = Town.shared
    @State private var babySex = 2
    @State private var genes = 0
    @State private var hearts = 0
    @State private var done: Set<Int> = []
    @State private var said = ""

    private struct Outing { let icon: String; let title: String; let line: String; let scene: Int }
    /// Each outing has its own Tama wallpaper behind the two of them.
    private let outings: [Outing] = [
        Outing(icon: "cup.and.saucer.fill", title: "Have a drink", line: "Sharing a warm drink and a slice of cake.", scene: 12),
        Outing(icon: "figure.walk", title: "Take a walk", line: "A slow walk through the park together.", scene: 18),
        Outing(icon: "music.note", title: "Go to a show", line: "Dancing along at the show.", scene: 17),
        Outing(icon: "fork.knife", title: "Have a picnic", line: "A picnic under the apple trees.", scene: 25),
        Outing(icon: "moon.stars.fill", title: "Watch the stars", line: "Lying back to watch the stars come out.", scene: 3),
    ]
    private static let meetScene = 18
    private static let loveScene = 7
    @State private var scene = SuitorSheet.meetScene
    /// Everyone has one favourite outing worth two hearts.
    private var favourite: Int { suitor.name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % outings.count }
    private var full: Bool { hearts >= 5 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        GeometryReader { g in
                            ZStack(alignment: .bottom) {
                                Backdrop(index: scene)
                                CharacterPicture(image: town.image(suitor))
                                    .frame(width: g.size.width * 0.42, height: g.size.width * 0.42)
                                    .padding(.bottom, g.size.width * 0.05)
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text(suitor.name).font(.system(.title, design: .rounded).weight(.heavy))
                        Text(said.isEmpty ? suitor.blurb : said)
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            ForEach(0..<5, id: \.self) { i in
                                Image(systemName: i < hearts ? "heart.fill" : "heart").foregroundStyle(.pink)
                            }
                        }
                        .font(.title2)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }

                Section(header: Text(full ? "You two had a lovely time" : "Spend time with \(suitor.name)"),
                        footer: Text(full ? "" : "Fill all five hearts to propose.")) {
                    ForEach(0..<outings.count, id: \.self) { i in
                        let used = done.contains(i)
                        Button { go(i) } label: {
                            HStack {
                                Label(outings[i].title, systemImage: outings[i].icon)
                                Spacer()
                                if used { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                else if i == favourite && !full { Text("Favourite").font(.caption).foregroundStyle(.pink) }
                            }
                        }
                        .disabled(used || full)
                    }
                }

                if full {
                    Section(header: Text("About the baby"),
                            footer: Text(genes == 0 ? "Mixes the parents the same way the official app did." : "Gives the baby a more random blend of both parents.")) {
                        Picker("Baby", selection: $babySex) {
                            Text("Surprise").tag(2); Text("Boy").tag(0); Text("Girl").tag(1)
                        }.pickerStyle(.segmented)
                        Picker("Genes", selection: $genes) {
                            Text("Like the app").tag(0); Text("Wild mix").tag(2)
                        }.pickerStyle(.segmented)
                    }
                }

                if !adult {
                    Section {
                        Label("\(tamaName) isn't a grown-up yet — the device may refuse.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .bottom) {
                Button { onPropose(babySex, genes) } label: {
                    Text("Propose").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.pink).disabled(!full)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { said = "Hi \(tamaName)! Shall we hang out?" }
        }
    }

    private func go(_ i: Int) {
        guard !done.contains(i), !full else { return }
        done.insert(i)
        hearts = min(5, hearts + (i == favourite ? 2 : 1))
        said = (i == favourite ? "My favourite! " : "") + outings[i].line
        scene = full ? SuitorSheet.loveScene : outings[i].scene
        if full { said = "\(tamaName)… I think I'm in love." }
        tick()
    }
}

// MARK: - Design your own

/// Build a partner gene by gene. The picture at the top is built as you choose.
struct DesignView: View {
    let onDone: (Suitor) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var town = Town.shared
    @State private var s = Suitor(name: "", body: 0, face: 0, head: 0, back: 0, bodyColor: 0, headColor: 0, backColor: 0, blurb: "Made just for you.")
    @State private var part = 0
    @State private var wall = 0

    private let names = ["Body", "Face", "Head", "Back"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stage
                chips
                List {
                    if part != 1 {
                        Section(header: Text("\(names[part]) colour")) { colours }
                    }
                    Section(header: Text("\(names[part]) style")) { genesGrid }
                }
                .listStyle(.insetGrouped)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Design your own")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Meet") {
                        var x = s
                        if x.name.isEmpty { x.name = Town.names.randomElement()! }
                        onDone(x)
                    }.fontWeight(.bold).disabled(town.image(s) == nil)
                }
            }
            .onAppear { surprise(first: true); wall = town.niceWallpapers.contains(2) ? 2 : 0 }
        }
    }

    // MARK: top: the character, built live

    private var stage: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        Backdrop(index: wall)
                        CharacterPicture(image: town.image(s))
                            .frame(width: g.size.width * 0.62, height: g.size.width * 0.62)
                            .padding(.bottom, g.size.width * 0.04)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 8) {
                    Button { nextWall() } label: {
                        Image(systemName: "photo").font(.body).padding(9).background(Circle().fill(.thinMaterial))
                    }
                    .accessibilityLabel("Change wallpaper")
                    Button { surprise(first: false) } label: {
                        Image(systemName: "dice.fill").font(.body).padding(9).background(Circle().fill(.thinMaterial))
                    }
                    .accessibilityLabel("Surprise me")
                }
                .padding(8)
            }
            HStack(spacing: 8) {
                TextField("Name (A–Z)", text: Binding(get: { s.name }, set: { s.name = String($0.uppercased().filter { $0.isLetter && $0.isASCII }.prefix(8)) }))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Text("\(s.name.count)/8").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    /// The four genes on their own, each in its colour: tap one to change it.
    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Button { part = i; tick() } label: {
                    VStack(spacing: 4) {
                        GenePicture(image: town.layer(i, id: gene(i), color: colour(i)))
                            .frame(height: 42).padding(.horizontal, 4)
                        Text(names[i]).font(.caption.weight(.semibold))
                            .foregroundStyle(part == i ? Color.accentColor : Color.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(part == i ? Color.accentColor : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: below: colours and genes for the chosen part

    private var colours: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<13, id: \.self) { p in
                    Button { setColor(p) } label: {
                        Circle().fill(Town.swatch(p)).frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: colour(part) == p ? 3 : 0).padding(-4))
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var genesGrid: some View {
        let list = part == 0 ? town.bodyIDs : town.ids
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
            ForEach(list, id: \.self) { gid in
                let sel = gene(part) == gid
                Button { setPart(gid) } label: {
                    GenePicture(image: town.layer(part, id: gid, color: colour(part)))
                        .frame(width: 46, height: 46)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(sel ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemGroupedBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(sel ? Color.accentColor : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: state

    private func gene(_ p: Int) -> UInt16 { [s.body, s.face, s.head, s.back][p] }
    private func colour(_ p: Int) -> Int { [s.bodyColor, 0, s.headColor, s.backColor][p] }

    private func setPart(_ g: UInt16) {
        switch part { case 0: s.body = g; case 1: s.face = g; case 2: s.head = g; default: s.back = g }
        tick()
    }
    private func setColor(_ p: Int) {
        switch part { case 0: s.bodyColor = p; case 2: s.headColor = p; case 3: s.backColor = p; default: break }
        tick()
    }
    private func nextWall() {
        let list = town.niceWallpapers
        guard !list.isEmpty else { return }
        let i = list.firstIndex(of: wall) ?? -1
        wall = list[(i + 1) % list.count]
        tick()
    }
    private func surprise(first: Bool) {
        guard let r = town.randomSuitor(mix: true) else { return }
        s.body = r.body; s.face = r.face; s.head = r.head; s.back = r.back
        s.bodyColor = first ? 0 : r.bodyColor; s.headColor = first ? 0 : r.headColor; s.backColor = first ? 0 : r.backColor
        if !first { tick() }
    }
}
