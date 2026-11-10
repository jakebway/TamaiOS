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
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        GeometryReader { g in
            let scale = displayScale
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
    /// For a partner you designed: where the dating left off, and a way to keep it.
    var savedHearts = 0
    var savedDone: [Int] = []
    var onProgress: ((_ hearts: Int, _ done: [Int]) -> Void)? = nil
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
                        footer: Text(full ? "" : (adult ? "Fill all five hearts to propose." : "\(tamaName) can only marry once grown up. Dates are fine."))) {
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

                if full && adult {
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
                        Label("\(tamaName) isn't a grown-up yet, so can't marry. Dates are fine.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .bottom) {
                Button { onPropose(babySex, genes) } label: {
                    Text("Propose").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.pink).disabled(!full || !adult)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                hearts = savedHearts; done = Set(savedDone)
                said = savedHearts > 0 ? "Welcome back, \(tamaName)! I missed you." : "Hi \(tamaName)! Shall we hang out?"
            }
        }
    }

    private func go(_ i: Int) {
        guard !done.contains(i), !full else { return }
        done.insert(i)
        hearts = min(5, hearts + (i == favourite ? 2 : 1))
        said = (i == favourite ? "My favourite! " : "") + outings[i].line
        scene = full ? SuitorSheet.loveScene : outings[i].scene
        if full { said = "\(tamaName)… I think I'm in love." }
        onProgress?(hearts, done.sorted())
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
            .onAppear { surprise(first: true) }
        }
    }

    // MARK: top: the character, built live

    private var stage: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        DressingRoom()
                        CharacterPicture(image: town.image(s))
                            .frame(width: g.size.width * 0.62, height: g.size.width * 0.62)
                            .padding(.bottom, g.size.width * 0.04)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 8) {
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
        ColourWheel(selected: Binding(get: { colour(part) }, set: { setColor($0) }))
            .frame(width: 220, height: 220)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
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
    private func surprise(first: Bool) {
        guard let r = town.randomSuitor(mix: true) else { return }
        s.body = r.body; s.face = r.face; s.head = r.head; s.back = r.back
        s.bodyColor = first ? 0 : r.bodyColor; s.headColor = first ? 0 : r.headColor; s.backColor = first ? 0 : r.backColor
        if !first { tick() }
    }
}


// MARK: - dressing room and colour wheel

/// The same backdrop every time a partner is made: a boutique fitting room (wall, curtain, mirror, wooden floor and a rug).
struct DressingRoom: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 1.0, green: 0.94, blue: 0.95), Color(red: 0.98, green: 0.86, blue: 0.90)],
                               startPoint: .top, endPoint: .bottom)
                // wall panels
                HStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { i in
                        Rectangle().fill(Color.white.opacity(i % 2 == 0 ? 0.0 : 0.16))
                    }
                }.frame(height: h * 0.72).frame(maxHeight: .infinity, alignment: .top)
                // curtain on the left
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle().fill(Color(red: 0.86, green: 0.38, blue: 0.58).opacity(i % 2 == 0 ? 1 : 0.82))
                    }
                }
                .frame(width: w * 0.2, height: h * 0.72)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Color(red: 0.55, green: 0.2, blue: 0.35))
                    .frame(width: w * 0.2, height: 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(y: 0)
                // mirror on the right
                RoundedRectangle(cornerRadius: w * 0.07, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.88, green: 0.95, blue: 1.0), Color(red: 0.72, green: 0.86, blue: 0.98)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.07, style: .continuous).stroke(Color(red: 0.85, green: 0.62, blue: 0.3), lineWidth: 4))
                    .frame(width: w * 0.24, height: h * 0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, h * 0.08).padding(.trailing, w * 0.07)
                // floor
                VStack(spacing: 0) {
                    Spacer()
                    ZStack(alignment: .top) {
                        Rectangle().fill(Color(red: 0.86, green: 0.66, blue: 0.48))
                        VStack(spacing: 0) {
                            ForEach(0..<4, id: \.self) { _ in
                                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
                                Spacer()
                            }
                        }
                        Rectangle().fill(Color(red: 0.62, green: 0.42, blue: 0.3)).frame(height: 3)
                    }.frame(height: h * 0.28)
                }
                // rug
                Ellipse().fill(Color(red: 1.0, green: 0.78, blue: 0.86))
                    .overlay(Ellipse().stroke(Color.white.opacity(0.8), lineWidth: 3).padding(5))
                    .frame(width: w * 0.62, height: h * 0.13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, h * 0.03)
            }
        }
    }
}

/// A round colour picker. A Tama's body, head and back can only be painted in the 13 colours the toy knows, so
/// the wheel is made of exactly those: bright colours go around the ring in rainbow order, whites, greys and
/// blacks sit in the middle. Tap or drag to choose.
struct ColourWheel: View {
    @Binding var selected: Int

    private struct Entry { let index: Int; let color: Color; let hue: Double; let sat: Double; let bri: Double }
    private static let entries: [Entry] = (0..<13).map { i in
        let c = Town.swatch(i)
        var h: CGFloat = 0, sa: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getHue(&h, saturation: &sa, brightness: &b, alpha: &a)
        return Entry(index: i, color: c, hue: Double(h), sat: Double(sa), bri: Double(b))
    }
    private static let ring: [Entry] = entries.filter { $0.sat >= 0.2 }.sorted { $0.hue < $1.hue }
    private static let centre: [Entry] = entries.filter { $0.sat < 0.2 }.sorted { $0.bri > $1.bri }

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let outer = side / 2, inner = outer * 0.5
            let n = Double(Self.ring.count)
            ZStack {
                ForEach(Array(Self.ring.enumerated()), id: \.element.index) { k, e in
                    let a0 = Angle.degrees(Double(k) / n * 360 - 90 - 180 / n), a1 = Angle.degrees(Double(k + 1) / n * 360 - 90 - 180 / n)
                    let on = selected == e.index
                    WheelWedge(start: a0, end: a1, innerRatio: 0.5)
                        .fill(e.color)
                        .overlay(WheelWedge(start: a0, end: a1, innerRatio: 0.5).stroke(Color.white, lineWidth: on ? 4 : 1.5))
                        .scaleEffect(on ? 1.06 : 1)
                        .zIndex(on ? 1 : 0)
                }
                // the neutrals in the middle
                let cols = Self.centre.count <= 3 ? Self.centre.count : 3
                let rows = (Self.centre.count + cols - 1) / max(1, cols)
                VStack(spacing: 6) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 6) {
                            ForEach(0..<cols, id: \.self) { c in
                                let i = r * cols + c
                                if i < Self.centre.count {
                                    let e = Self.centre[i]
                                    Circle().fill(e.color)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected == e.index ? 3 : 0).padding(-3))
                                        .frame(width: inner * 0.5, height: inner * 0.5)
                                } else { Color.clear.frame(width: inner * 0.5, height: inner * 0.5) }
                            }
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            .position(x: g.size.width / 2, y: g.size.height / 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let cx = g.size.width / 2, cy = g.size.height / 2
                let dx = Double(v.location.x - cx), dy = Double(v.location.y - cy)
                let r = (dx * dx + dy * dy).squareRoot()
                guard r <= Double(outer) * 1.1 else { return }
                var pick: Int?
                if r < Double(inner) {
                    // nearest of the neutral circles
                    let cols = Self.centre.count <= 3 ? Self.centre.count : 3
                    let rows = (Self.centre.count + cols - 1) / max(1, cols)
                    let cell = Double(inner) * 0.5 + 6
                    let col = Int(((dx + cell * Double(cols) / 2) / cell).rounded(.down)), row = Int(((dy + cell * Double(rows) / 2) / cell).rounded(.down))
                    let i = max(0, min(rows - 1, row)) * cols + max(0, min(cols - 1, col))
                    if i < Self.centre.count { pick = Self.centre[i].index }
                } else if !Self.ring.isEmpty {
                    var deg = atan2(dy, dx) * 180 / .pi + 90 + 180 / n      // 0 at the top of the first wedge
                    deg = deg.truncatingRemainder(dividingBy: 360); if deg < 0 { deg += 360 }
                    pick = Self.ring[min(Self.ring.count - 1, Int(deg / 360 * n))].index
                }
                if let pick, pick != selected { selected = pick; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            })
        }
        .accessibilityLabel("Colour wheel")
    }
}

private struct WheelWedge: Shape {
    var start: Angle, end: Angle, innerRatio: CGFloat
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), o = min(r.width, r.height) / 2, i = o * innerRatio
        var p = Path()
        p.addArc(center: c, radius: o, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: c, radius: i, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}
