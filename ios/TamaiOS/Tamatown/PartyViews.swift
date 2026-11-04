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

private func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}

/// Little hearts that float up each time `trigger` changes.
struct HeartBurst: View {
    let trigger: Int
    var symbol = "💗"
    @State private var t: CGFloat = 1

    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                Text(symbol)
                    .font(.system(size: 16 + CGFloat(i % 3) * 6))
                    .offset(x: CGFloat(i - 3) * 26 + CGFloat((i * 37) % 11) - 5, y: -t * (70 + CGFloat(i % 4) * 22))
                    .opacity(Double(1 - t))
                    .scaleEffect(0.6 + t * 0.6)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _ in
            t = 0
            withAnimation(.easeOut(duration: 1.2)) { t = 1 }
        }
    }
}

// MARK: - A date

/// A date: meet the suitor, spend time together until the hearts are full, then propose.
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
    @State private var burst = 0
    @State private var bob = false
    @State private var said = ""
    @State private var lastGain = 0

    private struct Outing { let icon: String; let title: String; let line: String }
    private let outings: [Outing] = [
        Outing(icon: "☕️", title: "Café", line: "Sharing a warm drink and a slice of cake."),
        Outing(icon: "🌳", title: "Walk", line: "A slow walk through the park together."),
        Outing(icon: "🎬", title: "Movie", line: "Sharing popcorn at the movies."),
        Outing(icon: "🧺", title: "Picnic", line: "A picnic on the grass in the sunshine."),
        Outing(icon: "🌟", title: "Stargaze", line: "Lying back to watch the stars come out."),
    ]
    /// Everyone has one favourite outing worth two hearts.
    private var favourite: Int { suitor.name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % outings.count }
    private var full: Bool { hearts >= 5 }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 20) {
                        hero
                        outingsRow
                        if full { babyCard }
                        if !adult {
                            Label("\(tamaName) isn't a grown-up yet — the device may refuse.", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(.footnote, design: .rounded)).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 120)
                }
                proposeBar
            }
            .background(
                LinearGradient(colors: [Color.pink.opacity(0.18), Color(.systemBackground)], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
            )
            .navigationTitle("Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                said = "Hi \(tamaName)! Shall we hang out?"
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { bob = true }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.pink.opacity(0.35), .purple.opacity(0.22)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 210, height: 210)
                Circle().strokeBorder(Color.pink.opacity(full ? 0.9 : 0.25), lineWidth: full ? 4 : 2).frame(width: 210, height: 210)
                CharacterPicture(image: town.image(suitor)).frame(width: 150, height: 150)
                    .offset(y: bob ? -5 : 5)
                HeartBurst(trigger: burst, symbol: full ? "💘" : "💗")
            }
            Text(suitor.name).font(.system(size: 32, weight: .heavy, design: .rounded))
            // what they say
            Text(said)
                .font(.system(.callout, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
                .animation(.easeInOut(duration: 0.2), value: said)
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: i < hearts ? "heart.fill" : "heart")
                        .foregroundStyle(.pink)
                        .scaleEffect(i < hearts ? 1.12 : 1.0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.5).delay(Double(i) * 0.05), value: hearts)
                }
            }
            .font(.title)
            Text(full ? "It's love! 💘" : suitor.blurb)
                .font(.system(.subheadline, design: .rounded).weight(full ? .bold : .regular))
                .foregroundStyle(full ? Color.pink : Color.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var outingsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(full ? "You two had a lovely time" : "Where shall we go with \(tamaName)?")
                .font(.system(.headline, design: .rounded))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(0..<outings.count, id: \.self) { i in
                    let o = outings[i]
                    let used = done.contains(i)
                    Button { go(i) } label: {
                        VStack(spacing: 4) {
                            Text(o.icon).font(.system(size: 30))
                            Text(o.title).font(.system(.footnote, design: .rounded).weight(.semibold))
                            Text(used ? "✓ Done" : (i == favourite ? "Favourite" : " "))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(used ? Color.secondary : Color.pink)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(used ? Color(.tertiarySystemBackground) : Color(.secondarySystemBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(used ? Color.clear : Color.pink.opacity(0.35), lineWidth: 1.5))
                        .opacity(used || full ? 0.55 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(used || full)
                }
            }
        }
    }

    private var babyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About the baby").font(.system(.headline, design: .rounded))
            Picker("Baby", selection: $babySex) {
                Text("Surprise").tag(2); Text("Boy").tag(0); Text("Girl").tag(1)
            }.pickerStyle(.segmented)
            Picker("Genes", selection: $genes) {
                Text("Like the app").tag(0); Text("Wild mix").tag(2)
            }.pickerStyle(.segmented)
            Text(genes == 0 ? "Mixes the parents the same way the official app did." : "Gives the baby a more random blend of both parents.")
                .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var proposeBar: some View {
        VStack(spacing: 6) {
            Button { onPropose(babySex, genes) } label: {
                Label("Propose 💍", systemImage: "heart.circle.fill")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(.pink)
            .disabled(!full)
            if !full {
                Text("Spend time together until the hearts are full.")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }

    private func go(_ i: Int) {
        guard !done.contains(i), !full else { return }
        let gain = i == favourite ? 2 : 1
        done.insert(i)
        withAnimation(.spring()) { hearts = min(5, hearts + gain) }
        lastGain = gain
        burst += 1
        said = (i == favourite ? "My favourite! " : "") + outings[i].line
        tap(full ? .heavy : .light)
        if hearts >= 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation { said = "\(tamaName)… I think I'm in love. 💞" }
                burst += 1
                tap(.heavy)
            }
        }
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
    @State private var pop = false

    private let names = ["Body", "Face", "Head", "Back"]
    private let icons = ["figure.stand", "face.smiling", "crown", "sparkles"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stage
                chips
                Divider().padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        colours
                        genesGrid
                    }
                    .padding(16)
                }
            }
            .background(Color(.systemBackground))
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
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LinearGradient(colors: [Color.pink.opacity(0.22), Color.purple.opacity(0.16)], startPoint: .top, endPoint: .bottom))
                    CharacterPicture(image: town.image(s)).padding(14)
                        .scaleEffect(pop ? 1.06 : 1.0)
                }
                .frame(height: 190)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: pop)
                Button { surprise(first: false) } label: {
                    Image(systemName: "dice.fill").font(.title3).padding(10)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .padding(10).accessibilityLabel("Surprise me")
            }
            HStack(spacing: 10) {
                Image(systemName: "pencil").foregroundStyle(.secondary)
                TextField("Name (A–Z)", text: Binding(get: { s.name }, set: { s.name = String($0.uppercased().filter { $0.isLetter && $0.isASCII }.prefix(8)) }))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Text("\(s.name.count)/8").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    /// The four genes on their own, each in its colour: tap one to change it.
    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Button { withAnimation(.easeInOut(duration: 0.15)) { part = i }; tap() } label: {
                    VStack(spacing: 4) {
                        GenePicture(image: town.layer(i, id: gene(i), color: colour(i)))
                            .frame(height: 46).padding(.horizontal, 4)
                        Text(names[i]).font(.system(.caption, design: .rounded).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(part == i ? Color.pink.opacity(0.16) : Color(.secondarySystemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(part == i ? Color.pink : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    // MARK: below: colours and genes for the chosen part

    @ViewBuilder
    private var colours: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(names[part]) colour").font(.system(.headline, design: .rounded))
            if part == 1 {
                Text("Faces keep their own look. Pick one below.")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<13, id: \.self) { p in
                            Button { setColor(p) } label: {
                                Circle().fill(Town.swatch(p)).frame(width: 38, height: 38)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: colour(part) == p ? 3 : 0).padding(-4))
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private var genesGrid: some View {
        let list = part == 0 ? town.bodyIDs : town.ids
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(names[part]) style").font(.system(.headline, design: .rounded))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                ForEach(list, id: \.self) { gid in
                    let sel = gene(part) == gid
                    Button { setPart(gid) } label: {
                        GenePicture(image: town.layer(part, id: gid, color: colour(part)))
                            .frame(width: 52, height: 52)
                            .frame(maxWidth: .infinity, minHeight: 68)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(sel ? Color.pink.opacity(0.18) : Color(.secondarySystemBackground)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(sel ? Color.pink : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: state

    private func gene(_ p: Int) -> UInt16 { [s.body, s.face, s.head, s.back][p] }
    private func colour(_ p: Int) -> Int { [s.bodyColor, 0, s.headColor, s.backColor][p] }

    private func setPart(_ g: UInt16) {
        switch part { case 0: s.body = g; case 1: s.face = g; case 2: s.head = g; default: s.back = g }
        bump()
    }
    private func setColor(_ p: Int) {
        switch part { case 0: s.bodyColor = p; case 2: s.headColor = p; case 3: s.backColor = p; default: break }
        bump()
    }
    private func bump() {
        tap(.soft)
        pop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pop = false }
    }
    private func surprise(first: Bool) {
        guard let r = town.randomSuitor(mix: true) else { return }
        s.body = r.body; s.face = r.face; s.head = r.head; s.back = r.back
        s.bodyColor = first ? 0 : r.bodyColor; s.headColor = first ? 0 : r.headColor; s.backColor = first ? 0 : r.backColor
        if !first { bump() }
    }
}
