import SwiftUI

/// Egg outline of the Tamagotchi ON: a full, rounded top and a wide bottom.
struct EggShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, x = r.minX, y = r.minY, cx = r.midX
        var p = Path()
        p.move(to: CGPoint(x: cx, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.58),
                   control1: CGPoint(x: x + w * 0.86, y: y), control2: CGPoint(x: x + w, y: y + h * 0.25))
        p.addCurve(to: CGPoint(x: cx, y: y + h),
                   control1: CGPoint(x: x + w, y: y + h * 0.86), control2: CGPoint(x: x + w * 0.82, y: y + h))
        p.addCurve(to: CGPoint(x: x, y: y + h * 0.58),
                   control1: CGPoint(x: x + w * 0.18, y: y + h), control2: CGPoint(x: x, y: y + h * 0.86))
        p.addCurve(to: CGPoint(x: cx, y: y),
                   control1: CGPoint(x: x, y: y + h * 0.25), control2: CGPoint(x: x + w * 0.14, y: y))
        p.closeSubpath()
        return p
    }
}

/// Small rounded five-pointed star.
struct StarShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY + r.height * 0.04)
        let R = min(r.width, r.height) / 2, ri = R * 0.48
        var p = Path()
        for i in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let rad = i % 2 == 0 ? R : ri
            let pt = CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Cartoon ink colour for outlines.
let inkLine = Color(red: 0.23, green: 0.14, blue: 0.31)

/// Layout of the toy, shared by the static shell and the live parts on top.
/// Every position is measured from the top-left of the whole toy, so the
/// shell, screen and buttons always line up exactly.
struct ShellMetrics {
    let w: CGFloat
    var scale: CGFloat = 3
    var line: CGFloat { max(2.5, w * 0.02) }
    var loopH: CGFloat { w * 0.13 }                  // strap loop above the egg
    var eggH: CGFloat { w * 1.24 }
    var labelH: CGFloat { button * 0.36 }            // A B C under the buttons
    var totalH: CGFloat { loopH + eggH + line }
    var cx: CGFloat { w / 2 }
    var eggTop: CGFloat { loopH }
    /// Coloured frame around the screen.
    var frame: CGFloat { w * 0.72 }
    /// LCD size, snapped so each of its 128 pixels covers a whole number of
    /// device pixels (crisp, even pixels).
    var screen: CGFloat {
        let ideal = w * 0.52 * scale
        var per = max(1, (ideal / 128).rounded())
        if per > 1 && per * 128 / scale > w * 0.55 { per -= 1 }   // must fit its frame
        return per * 128 / scale
    }
    var screenY: CGFloat { eggTop + eggH * 0.41 }   // centre of the screen
    var button: CGFloat { w * 0.145 }
    var buttonDX: CGFloat { w * 0.24 }               // A and C sit this far left/right of centre
    var buttonsY: CGFloat { eggTop + eggH * 0.81 }   // centre of A and C
    var middleDrop: CGFloat { button * 0.2 }         // B sits a little lower, like a smile
}

extension Theme {
    /// The contrasting colour of the screen frame, like the ON's faceplates.
    var frameTheme: Theme { Theme.of([1, 0, 4, 2, 0, 4][min(max(id, 0), 5)]) }
}

/// Everything that never changes while you play: drawn once and cached.
struct ShellArt: View, Equatable {
    let theme: Theme
    let m: ShellMetrics

    static func == (a: ShellArt, b: ShellArt) -> Bool { a.theme == b.theme && a.m.w == b.m.w && a.m.scale == b.m.scale }

    var body: some View {
        let w = m.w, h = m.eggH, lw = m.line, cx = m.cx
        let eggMid = m.eggTop + h / 2
        let ft = theme.frameTheme
        let ringD = w * 0.13
        ZStack(alignment: .topLeading) {
            // strap loop, fully inside the drawing so nothing is cut off
            Circle().stroke(inkLine, lineWidth: lw * 2.4)
                .overlay(Circle().stroke(Color(white: 0.93), lineWidth: lw * 1.0))
                .frame(width: ringD, height: ringD)
                .position(x: cx, y: lw * 1.3 + ringD / 2)
            Capsule().fill(theme.bottom).overlay(Capsule().stroke(inkLine, lineWidth: lw))
                .frame(width: w * 0.15, height: w * 0.07)
                .position(x: cx, y: m.eggTop + w * 0.005)

            // the shell
            EggShape().fill(theme.bottom)
                .overlay(EggShape().fill(Color.black.opacity(0.10)))
                .frame(width: w - lw, height: h - lw)
                .position(x: cx, y: eggMid)
            EggShape()
                .fill(LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom))
                .frame(width: (w - lw) * 0.94, height: (h - lw) * 0.94)
                .position(x: cx - w * 0.03, y: eggMid - h * 0.03)
                .mask(EggShape().frame(width: w - lw, height: h - lw).position(x: cx, y: eggMid))
            EggShape().stroke(inkLine, lineWidth: lw)
                .frame(width: w - lw, height: h - lw)
                .position(x: cx, y: eggMid)

            // shine along the upper-left edge, clear of the screen frame
            EggShape().trim(from: 0.86, to: 0.925)
                .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: w * 0.021, lineCap: .round))
                .frame(width: (w - lw) * 0.935, height: (h - lw) * 0.935)
                .position(x: cx, y: eggMid)

            // screen frame (centred on the screen), its shadow, and a heart
            let fr = m.frame
            RoundedRectangle(cornerRadius: fr * 0.30, style: .continuous)
                .fill(LinearGradient(colors: [ft.top, ft.bottom], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: fr * 0.30, style: .continuous).stroke(inkLine, lineWidth: lw))
                .frame(width: fr, height: fr)
                .position(x: cx, y: m.screenY)
            StarShape().fill(Color.white)
                .overlay(StarShape().stroke(inkLine, style: StrokeStyle(lineWidth: lw * 0.5, lineJoin: .round)))
                .frame(width: w * 0.05, height: w * 0.05)
                .position(x: cx, y: m.screenY - fr / 2 + (fr - m.screen) / 4)
            // dark border right around the LCD
            RoundedRectangle(cornerRadius: m.screen * 0.08, style: .continuous)
                .fill(inkLine)
                .frame(width: m.screen + lw * 1.6, height: m.screen + lw * 1.6)
                .position(x: cx, y: m.screenY)

            // button wells
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(inkLine.opacity(0.18))
                    .frame(width: m.button * 1.18, height: m.button * 1.18)
                    .position(x: cx + CGFloat(i - 1) * m.buttonDX, y: m.buttonsY + (i == 1 ? m.middleDrop : 0) + m.button * 0.04)
            }
        }
        .frame(width: w, height: m.totalH, alignment: .topLeading)
    }
}

struct DeviceView: View {
    /// The window's real safe-area insets (the view itself ignores them to centre the toy).
    private static var windowInsets: UIEdgeInsets {
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        return w?.safeAreaInsets ?? .zero
    }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var emu: Emulator
    @AppStorage("showHints") private var showHints = true
    @State private var showSettings = false
    @State private var restoreError = false
    @State private var showApp = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let theme = Theme.of(emu.toy?.color ?? 0)
        GeometryReader { geo in
            let room = geo.size.height - 64 - (showHints ? 44 : 0)
            let m = ShellMetrics(w: min(geo.size.width - 24, room / 1.45, 640), scale: displayScale)
            ZStack {
                LinearGradient(colors: [theme.top.opacity(0.45), theme.bottom.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar(theme)
                    Spacer(minLength: 0)
                    toy(theme, m)
                    Spacer(minLength: 0)
                    if showHints { hint(theme).padding(.horizontal, 56).padding(.bottom, 6) }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)

                // settings: bottom right (clear of the clock and battery on iPhone Duo)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(theme.ink)
                                .padding(12)
                                .background(Circle().fill(.ultraThinMaterial))
                        }
                        .accessibilityLabel("Settings")
                    }
                    .padding(.trailing, 16).padding(.bottom, 12)
                }

                if let t = emu.toast {
                    VStack {
                        Text(t)
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(Capsule().fill(.ultraThickMaterial))
                            .shadow(radius: 8)
                            .padding(.top, 60).padding(.horizontal, 20)
                            // the toy is centred across the whole screen (safe area ignored), so keep the pop-up out of the
                            // side strip with the clock and battery on iPhone Duo
                            .padding(.leading, Self.windowInsets.left).padding(.trailing, Self.windowInsets.right)
                            .onTapGesture { emu.toast = nil }
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let s = emu.stopped { stoppedCard(s, theme) }
            }
            .animation(.spring(), value: emu.toast)
        }
        // centre the toy on the whole screen (on iPhone Duo the side with the clock and battery is otherwise left out)
        .ignoresSafeArea(.container, edges: .horizontal)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model).environmentObject(emu) }
        .background(Color.clear.sheet(isPresented: $showApp) { TamatownView().environmentObject(emu) })
        .onAppear {
            // a Tama that's out visiting belongs in Tamatown, not on the I'M OUT screen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let t = emu.toy, Town.shared.state(t).away, !showApp, !showSettings, !emu.appWaiting { showApp = true }
            }
        }
        .background(Color.clear.sheet(isPresented: $model.openPickup) {
            NavigationStack {
                TamaDepaView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.openPickup = false } } }
            }.environmentObject(emu)
        })
        .onChange(of: model.openTown) { open in
            if open { model.openTown = false; showApp = true }
        }
        .onChange(of: emu.appWaiting) { waiting in
            // the device chose Connection › App, like with the phone app:
            // coming home from Tamatown is handled quietly; anything else opens Tamatown
            guard waiting, !showSettings else { return }
            if let t = emu.toy, Town.shared.state(t).away {
                AppLink.shared.start(emu: emu) {}
            } else {
                showApp = true
            }
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { model.pendingBackup != nil }, set: { if !$0 { model.pendingBackup = nil } }), titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if let u = model.pendingBackup, let d = try? ToyStore.readPicked(u) {
                    restoreError = !emu.restoreBackup(d)
                }
                model.pendingBackup = nil
            }
            Button("Cancel", role: .cancel) { model.pendingBackup = nil }
        } message: {
            Text("This replaces \(emu.toy?.name ?? "your device")'s current state with the backup. (Console command \"restorebak\" undoes it.)")
        }
        .alert("That backup doesn't fit this device", isPresented: $restoreError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It was made with a different ROM version. Switch to the matching device first, then restore it.")
        }
    }

    private func titleLabel(chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text((emu.daytimeMode ? "☀️ " : "") + (emu.toy?.name ?? "TamaiOS"))
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                if chevron { Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)) }
            }
            if let r = emu.toy?.romName {
                Text(r).font(.system(.caption2, design: .rounded)).opacity(0.7)
            }
        }
    }

    private func topBar(_ theme: Theme) -> some View {
        HStack {
            if model.toys.count > 1 {
                Menu {
                    ForEach(model.toys) { t in
                        Button {
                            if t.id != emu.toy?.id { model.play(t) }
                        } label: {
                            Label((LiveTamaName.savedName(t.id) ?? t.name) + " · " + t.romName,
                                  systemImage: t.id == emu.toy?.id ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: { titleLabel(chevron: true) }
                .tint(theme.ink)
            } else {
                titleLabel(chevron: false)
            }
            Spacer()
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .frame(height: 56)
    }

    /// The whole toy: cached art, the live LCD, and the buttons, all placed
    /// from the same metrics so they line up exactly.
    private func toy(_ theme: Theme, _ m: ShellMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            ShellArt(theme: theme, m: m)
                .equatable()
                .drawingGroup()
                .shadow(color: .black.opacity(0.18), radius: m.w * 0.03, y: m.w * 0.02)
            screenView(m)
                .position(x: m.cx, y: m.screenY)
            buttons(theme, m)
        }
        .frame(width: m.w, height: m.totalH + m.labelH, alignment: .topLeading)
    }

    private func screenView(_ m: ShellMetrics) -> some View {
        let size = m.screen
        return ZStack {
            inkLine
            LCDView(sink: emu.frames)
            if emu.dark {
                Color.black
                Text("z z z").font(.system(size: size * 0.09, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.05, style: .continuous))
        // the dark border is drawn with the screen itself, so nothing can peek through
        .padding(m.line * 0.8)
        .background(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous).fill(inkLine))
        .accessibilityLabel("Device screen")
    }

    private func buttons(_ theme: Theme, _ m: ShellMetrics) -> some View {
        let d = m.button
        let keys: [(String, TGKey)] = [("A", .a), ("B", .b), ("C", .c)]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { i in
                let k = keys[i].1
                ToyButton(label: keys[i].0, size: d, theme: theme, line: m.line) { emu.press(k) } up: { emu.release(k) }
                    .position(x: m.cx + CGFloat(i - 1) * m.buttonDX,
                              y: m.buttonsY + (i == 1 ? m.middleDrop : 0))
            }
        }
        .frame(width: m.w, height: m.totalH + m.labelH, alignment: .topLeading)
    }

    private func hint(_ theme: Theme) -> some View {
        HStack(spacing: 14) {
            Text("**A** choose").fixedSize()
            Text("**B** OK").fixedSize()
            Text("**C** back").fixedSize()
            Button { withAnimation { showHints = false } } label: { Image(systemName: "xmark.circle.fill") }
        }
        .font(.system(.footnote, design: .rounded))
        .foregroundStyle(theme.ink.opacity(0.85))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    private func stoppedCard(_ s: StopInfo, _ theme: Theme) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                Text(s.title).font(.system(.title3, design: .rounded).weight(.bold))
                Text("Restarting is like taking the batteries out — your pet and its progress are kept.")
                    .font(.system(.callout, design: .rounded)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                BigButton(title: "Restart device", icon: "arrow.clockwise", theme: theme) { emu.restart() }
                Button("Reload last autosave") { emu.reload() }
                Button("Open Console") { showSettings = true }
                    .font(.system(.footnote, design: .rounded))
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.regularMaterial))
            .padding(30)
        }
    }
}

/// A cartoon button that reacts on touch-down (no gesture delay).
struct ToyButton: View {
    let label: String
    let size: CGFloat
    let theme: Theme
    let line: CGFloat
    let down: () -> Void
    let up: () -> Void
    @State private var pressed = false
    @AppStorage("haptics") private var haptics = true

    var body: some View {
        VStack(spacing: size * 0.08) {
            ZStack {
                Circle().fill(inkLine.opacity(0.35))
                    .offset(y: size * 0.07)
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.6), theme.button], center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: size * 0.55))
                    .overlay(Circle().fill(Color.black.opacity(pressed ? 0.12 : 0)))
                    .overlay(Circle().stroke(inkLine, lineWidth: line))
                    .offset(y: pressed ? size * 0.06 : 0)
            }
            .frame(width: size, height: size)
            .overlay(
                TouchPad(down: {
                    pressed = true
                    if haptics { Haptics.tap() }
                    down()
                }, up: {
                    pressed = false
                    up()
                })
                .frame(width: size * 1.5, height: size * 1.6)
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Button \(label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { down(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { up() } }
    }
}