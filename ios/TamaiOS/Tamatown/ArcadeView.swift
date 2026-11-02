import SwiftUI
import UIKit

/// The Arcade: "Tama Pop" — Tamas peek out of the bushes; tap them before they
/// hide. Every catch is 50 Gotchi Points for your Tama.
struct ArcadeView: View {
    @ObservedObject var town = Town.shared
    @EnvironmentObject private var emu: Emulator
    @ObservedObject private var wallet = DeviceWallet.shared
    @State private var credited = 0
    @AppStorage("arcadeBest") private var best = 0
    @AppStorage("haptics") private var haptics = true

    enum Phase { case ready, countdown, playing, done }
    @State private var phase: Phase = .ready
    @State private var count = 3
    @State private var timeLeft: Double = 0
    @State private var score = 0
    @State private var holes: [Suitor?] = Array(repeating: nil, count: 9)
    @State private var lastShown: [Suitor?] = Array(repeating: nil, count: 9)
    @State private var shownAt: [Double] = Array(repeating: 0, count: 9)
    @State private var catchableUntil: [Double] = Array(repeating: -1, count: 9)
    private struct Sprite {
        let suitor: Suitor
        let image: CGImage
    }
    @State private var spritePool: [Sprite] = []
    @State private var lastImages: [CGImage?] = Array(repeating: nil, count: 9)
    @State private var lastCallback: Double = 0
    @State private var countdownRemaining: Double = 3
    @State private var bursts: [Int: Double] = [:]      // hole -> time of the "+50"
    @State private var clock: Double = 0
    @State private var ticks = 0
    @State private var touchingHoles: Set<Int> = []

    private let length: Double = 25
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                board
                    .aspectRatio(0.9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white, lineWidth: 4))
                Text("Winnings update your Tama’s profile balance directly. No second award is sent on the way home.")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .background(LinearGradient(colors: [Color.purple.opacity(0.12), Color(.systemBackground)], startPoint: .top, endPoint: .center).ignoresSafeArea())
        .scrollDisabled(phase == .playing || phase == .countdown)
        .onAppear { wallet.refresh(emu) }
        .navigationTitle("Arcade")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(timer) { _ in tick() }
        .onDisappear {
            touchingHoles.removeAll()
            catchableUntil = Array(repeating: -1, count: 9)
            if phase != .done { ArcadeDiagnostics.shared.end("left arcade", score: score); phase = .ready }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            chip(icon: "star.fill", tint: .yellow, text: "\(score)")
            VStack(alignment: .leading, spacing: 4) {
                Text(phase == .playing ? "\(Int(timeLeft.rounded(.up))) s" : "Tama Pop")
                    .font(.system(.caption, design: .rounded).weight(.heavy)).foregroundStyle(.secondary)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.purple.opacity(0.15))
                        Capsule().fill(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * progress)
                    }
                }
                .frame(height: 10)
            }
            chip(icon: "dollarsign.circle.fill", tint: .orange, text: wallet.balance.map { "\($0) G" } ?? "— G")
        }
    }

    private var progress: CGFloat {
        switch phase {
        case .playing: return CGFloat(max(0, timeLeft / length))
        case .done: return 0
        default: return 1
        }
    }

    private func burst(_ age: Double, _ size: CGFloat) -> some View {
        let rise: CGFloat = size * (0.55 + CGFloat(age) * 0.6)
        let fade: Double = max(0, 1 - age * 1.6)
        return Text("+50")
            .font(.system(size: size * 0.18, weight: .black, design: .rounded))
            .foregroundStyle(Color.yellow)
            .shadow(color: .orange, radius: 0, x: 1, y: 2)
            .offset(y: -rise)
            .opacity(fade)
    }

    private func tama(_ i: Int, _ size: CGFloat) -> some View {
        let up = holes[i] != nil
        // up: peeking over the bush; down: tucked behind it (the cell clips the rest)
        // the cell is size tall and the bush covers its bottom 42%: a hidden Tama sits
        // just below the bush top, a popped one stands on it with its whole head showing
        let lift: CGFloat = up ? -size * 0.40 : size * 0.16
        let img = lastImages[i]
        return CharacterPicture(image: img)
            .frame(width: size * 0.56, height: size * 0.56)
            .offset(y: lift)
    }

    private func chip(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.system(.headline, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
    }

    // MARK: the board

    private static let sky = [Color(red: 0.72, green: 0.88, blue: 1.0), Color(red: 0.96, green: 0.86, blue: 1.0)]
    private static let lawn = [Color(red: 0.62, green: 0.88, blue: 0.55), Color(red: 0.45, green: 0.76, blue: 0.42)]

    private var board: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: ArcadeView.sky, startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: ArcadeView.lawn, startPoint: .top, endPoint: .bottom)
                    .frame(height: g.size.height * 0.82)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<3, id: \.self) { col in
                                hole(row * 3 + col, size: g.size.width / 3)
                            }
                        }
                    }
                }
                .padding(.top, g.size.height * 0.10)
                overlay
            }
        }
    }

    private func hole(_ i: Int, size: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // the Tama, popping up from behind the bush
            tama(i, size)
            // the bush in front (drawn once, never redrawn)
            BushView(size: size, variant: i % 3).equatable()
                .frame(width: size, height: size * 0.46)
            if let t = bursts[i] {
                burst(clock - t, size)
            }
        }
        .frame(width: size, height: size, alignment: .bottom)   // bush sits on the cell's floor
        .clipped()
        .contentShape(Rectangle())
        .overlay {
            ArcadeTouchTarget { tap(i) }
                .allowsHitTesting(phase == .playing)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tama hole \(i + 1)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap(i) }
    }

    @ViewBuilder
    private var overlay: some View {
        switch phase {
        case .ready, .done:
            VStack(spacing: 12) {
                Text(phase == .done ? "You caught \(score)!" : "Tama Pop")
                    .font(.system(.largeTitle, design: .rounded).weight(.black))
                    .foregroundStyle(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing))
                Text(phase == .done ? "+\(credited) Gotchi Points 🎉" : "Tap the Tamas as they pop out of the bushes!")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                Button { begin() } label: {
                    Label(phase == .done ? "Play again" : "Play", systemImage: "play.fill")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .padding(.horizontal, 30).padding(.vertical, 12)
                        .background(Capsule().fill(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                if best > 0 { Text("Best: \(best)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial))
            .padding(28)
        case .countdown:
            Text("\(count)")
                .font(.system(size: 96, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .purple, radius: 0, x: 3, y: 4)
                .id(count)
                .transition(.scale.combined(with: .opacity))
        case .playing:
            EmptyView()
        }
    }

    // MARK: game

    private func prepareSprites() {
        guard spritePool.isEmpty else { return }
        let started = ProcessInfo.processInfo.systemUptime
        var candidates = Array(town.suitors.prefix(12))
        if candidates.isEmpty, let fallback = town.randomSuitor(mix: false) { candidates = [fallback] }
        var prepared: [Sprite] = []
        for candidate in candidates {
            if let image = town.image(candidate) { prepared.append(Sprite(suitor: candidate, image: image)) }
        }
        spritePool = prepared
        ArcadeDiagnostics.shared.prepared(count: prepared.count, seconds: ProcessInfo.processInfo.systemUptime - started)
    }

    private func begin() {
        guard phase == .ready || phase == .done else { return }
        touchingHoles.removeAll()
        // Core reads and sprite composition happen before the countdown, never during play.
        wallet.refresh(emu)
        guard wallet.balance != nil else { emu.say("Your Tama’s profile is not ready yet."); return }
        prepareSprites()
        guard !spritePool.isEmpty else { emu.say("Tamatown characters are still loading. Try again shortly."); return }
        catchableUntil = Array(repeating: -1, count: 9)
        credited = 0
        score = 0
        holes = Array(repeating: nil, count: 9)
        bursts = [:]
        count = 3
        countdownRemaining = 3
        ticks = 0
        clock = 0
        lastCallback = ProcessInfo.processInfo.systemUptime
        ArcadeDiagnostics.shared.start()
        withAnimation(.spring()) { phase = .countdown }
    }

    private func tick() {
        guard phase == .countdown || phase == .playing else { return }
        let started = ProcessInfo.processInfo.systemUptime
        guard UIApplication.shared.applicationState == .active else {
            lastCallback = started
            return
        }
        let gap = max(0, started - lastCallback)
        lastCallback = started
        // Count real elapsed time under normal load. A long stall pauses excess game time.
        let dt = min(gap, 0.10)
        ArcadeDiagnostics.shared.callback(gap: gap, discarded: max(0, gap - dt))
        defer { if phase != .done { ArcadeDiagnostics.shared.work(seconds: ProcessInfo.processInfo.systemUptime - started) } }
        clock += dt
        ticks += 1
        if !bursts.isEmpty { bursts = bursts.filter { clock - $0.value < 0.7 } }
        switch phase {
        case .countdown:
            countdownRemaining -= dt
            let next = max(1, Int(countdownRemaining.rounded(.up)))
            if countdownRemaining <= 0 {
                timeLeft = length
                phase = .playing
            } else if count != next { withAnimation(.spring()) { count = next } }
        case .playing:
            timeLeft = max(0, timeLeft - dt)
            if timeLeft <= 0 { finish(); return }
            let stay = 0.45 + 0.55 * (timeLeft / length)
            for i in 0..<9 where holes[i] != nil && clock - shownAt[i] > stay {
                catchableUntil[i] = clock + 0.12
                withAnimation(.easeIn(duration: 0.12)) { holes[i] = nil }
            }
            let spawnChance = 1 - pow(0.65, dt / 0.05)
            if holes.compactMap({ $0 }).count < 4 && Double.random(in: 0...1) < spawnChance {
                let free = (0..<9).filter { holes[$0] == nil && bursts[$0] == nil && clock > catchableUntil[$0] }
                if let i = free.randomElement(), let sprite = spritePool.randomElement() {
                    shownAt[i] = clock
                    lastImages[i] = sprite.image
                    lastShown[i] = sprite.suitor
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { holes[i] = sprite.suitor }
                }
            }
        default: break
        }
    }

    private func finish() {
        guard phase == .playing else { return }
        touchingHoles.removeAll()
        catchableUntil = Array(repeating: -1, count: 9)
        withAnimation { holes = Array(repeating: nil, count: 9); phase = .done }
        ArcadeDiagnostics.shared.end("completed", score: score)
        // One award after gameplay; no emulator locks are acquired by the gameplay timer.
        let start = ProcessInfo.processInfo.systemUptime
        credited = wallet.credit(score * 50, emu: emu)
        ArcadeDiagnostics.shared.reward(seconds: ProcessInfo.processInfo.systemUptime - start, amount: credited)
        best = max(best, score)
    }

    private func tap(_ i: Int) {
        guard phase == .playing, holes[i] != nil || clock <= catchableUntil[i] else { return }
        catchableUntil[i] = -1
        score += 1
        bursts[i] = clock
        if haptics { Haptics.tap() }
        withAnimation(.easeOut(duration: 0.08)) { holes[i] = nil }
    }
}


final class ArcadeDiagnostics {
    static let shared = ArcadeDiagnostics()
    private let lock = NSLock()
    private var state = "not played"
    private var sprites = 0
    private var prepareSeconds = 0.0
    private var callbacks = 0
    private var over100 = 0
    private var over250 = 0
    private var maxGap = 0.0
    private var maxWork = 0.0
    private var pausedSeconds = 0.0
    private var started = 0.0
    private var duration = 0.0
    private var catches = 0
    private var rewardSeconds = 0.0
    private var credited = 0
    func prepared(count: Int, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        sprites = count; prepareSeconds = seconds
    }
    func start() {
        lock.lock(); defer { lock.unlock() }
        state = "active (countdown or round)"
        callbacks = 0; over100 = 0; over250 = 0; maxGap = 0; maxWork = 0
        pausedSeconds = 0; catches = 0; rewardSeconds = 0; credited = 0; duration = 0
        started = ProcessInfo.processInfo.systemUptime
    }
    func callback(gap: Double, discarded: Double) {
        lock.lock(); defer { lock.unlock() }
        callbacks += 1; maxGap = max(maxGap, gap); pausedSeconds += discarded
        if gap > 0.1 { over100 += 1 }
        if gap > 0.25 { over250 += 1 }
    }
    func work(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        maxWork = max(maxWork, seconds)
    }
    func end(_ reason: String, score: Int) {
        lock.lock(); defer { lock.unlock() }
        guard state.hasPrefix("active") else { return }
        state = reason; catches = score; duration = ProcessInfo.processInfo.systemUptime - started
    }
    func reward(seconds: Double, amount: Int) {
        lock.lock(); defer { lock.unlock() }
        rewardSeconds = seconds; credited = amount
    }
    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        return ["arcade-performance-v1", "state: \(state)",
                "cached sprites: \(sprites); preparation ms: \(Int(prepareSeconds * 1000))",
                "callbacks: \(callbacks); gaps >100ms: \(over100); >250ms: \(over250)",
                "max callback gap ms: \(Int(maxGap * 1000)); max callback work ms: \(Int(maxWork * 1000))",
                "excess stall time paused: \(String(format: "%.2f", pausedSeconds)) s",
                "round wall duration (includes countdown): \(String(format: "%.2f", duration)) s",
                "catches: \(catches); credited: \(credited) G; reward ms: \(Int(rewardSeconds * 1000))",
                "Timer metrics are not rendered-frame FPS. No profile polling or sprite composition during play."].joined(separator: "\n")
    }
}

struct ArcadeTouchTarget: UIViewRepresentable {
    var hit: () -> Void
    func makeUIView(context: Context) -> ArcadeTouchView {
        let view = ArcadeTouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.hit = hit
        return view
    }
    func updateUIView(_ view: ArcadeTouchView, context: Context) { view.hit = hit }
}
final class ArcadeTouchView: UIView {
    var hit: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { hit?() }
}

/// A round, leafy bush: a cluster of outlined puffs with highlights and a few
/// berries. Equatable, so SwiftUI draws it once instead of on every game tick.
struct BushView: View, Equatable {
    let size: CGFloat
    let variant: Int

    private static let ink = Color(red: 0.16, green: 0.33, blue: 0.18)
    private static let leaf = [Color(red: 0.38, green: 0.74, blue: 0.36), Color(red: 0.34, green: 0.68, blue: 0.40), Color(red: 0.42, green: 0.76, blue: 0.32)]
    private static let light = Color(red: 0.62, green: 0.88, blue: 0.50)
    private static let berry = [Color(red: 1.0, green: 0.45, blue: 0.55), Color(red: 1.0, green: 0.82, blue: 0.35), Color.white]
    // puffs as (x, y, radius) in units of the bush width, y from the bottom
    private static let puffs: [(CGFloat, CGFloat, CGFloat)] = [
        (0.15, 0.16, 0.15), (0.33, 0.26, 0.17), (0.52, 0.28, 0.18), (0.70, 0.24, 0.17), (0.86, 0.15, 0.13),
        (0.08, 0.07, 0.10), (0.30, 0.10, 0.18), (0.55, 0.10, 0.20), (0.78, 0.09, 0.15)]

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width * 0.92, x0 = sz.width * 0.04, base = sz.height
            func circle(_ p: (CGFloat, CGFloat, CGFloat), grow: CGFloat) -> Path {
                let r = p.2 * w + grow
                return Path(ellipseIn: CGRect(x: x0 + p.0 * w - r, y: base - p.1 * w - r, width: r * 2, height: r * 2))
            }
            let leaf = BushView.leaf[variant % 3]
            // outline: every puff a little bigger, in dark green
            for p in BushView.puffs { ctx.fill(circle(p, grow: max(2, w * 0.025)), with: .color(BushView.ink)) }
            for p in BushView.puffs { ctx.fill(circle(p, grow: 0), with: .color(leaf)) }
            // soft shading on the lower half, highlights on the top puffs
            ctx.fill(Path(CGRect(x: 0, y: base - w * 0.10, width: sz.width, height: w * 0.10)), with: .color(BushView.ink.opacity(0.18)))
            for p in BushView.puffs.prefix(5) {
                let r = p.2 * w * 0.42
                ctx.fill(Path(ellipseIn: CGRect(x: x0 + p.0 * w - r * 1.2, y: base - p.1 * w - p.2 * w * 0.55 - r * 0.5, width: r * 1.6, height: r)),
                         with: .color(BushView.light.opacity(0.85)))
            }
            // a few berries
            for (k, p) in [(0.28, 0.20), (0.62, 0.18), (0.80, 0.14)].enumerated() {
                let r = w * 0.035
                ctx.fill(Path(ellipseIn: CGRect(x: x0 + CGFloat(p.0) * w - r, y: base - CGFloat(p.1) * w - r, width: r * 2, height: r * 2)),
                         with: .color(BushView.berry[(k + variant) % 3]))
            }
        }
    }
}