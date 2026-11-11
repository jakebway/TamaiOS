import SwiftUI
import UIKit

/// Flat RGBA bitmap. One array of UInt32 instead of thousands of UIColor objects,
/// so drawing, undo and flood fill are all cheap.
struct PixelBitmap {
    let size: Int
    var px: [UInt32]

    init(size: Int) {
        self.size = size
        self.px = Array(repeating: 0, count: size * size)
    }

    static func pack(_ c: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(r) | (byte(g) << 8) | (byte(b) << 16) | (255 << 24)
    }

    mutating func set(_ x: Int, _ y: Int, _ v: UInt32) {
        guard x >= 0, y >= 0, x < size, y < size else { return }
        px[y * size + x] = v
    }

    /// Square brush, `brush` cells wide, centred on the touched cell.
    mutating func stamp(_ cx: Int, _ cy: Int, brush: Int, _ v: UInt32) {
        let lo = -(brush - 1) / 2
        for dy in 0..<brush {
            for dx in 0..<brush { set(cx + lo + dx, cy + lo + dy, v) }
        }
    }

    /// Straight line between two cells so fast swipes never leave gaps.
    mutating func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, brush: Int, _ v: UInt32) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            stamp(x, y, brush: brush, v)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    mutating func fill(_ sx: Int, _ sy: Int, _ v: UInt32) {
        guard sx >= 0, sy >= 0, sx < size, sy < size else { return }
        let target = px[sy * size + sx]
        guard target != v else { return }
        var stack = [(sx, sy)]
        while let (x, y) = stack.popLast() {
            guard x >= 0, y >= 0, x < size, y < size, px[y * size + x] == target else { continue }
            px[y * size + x] = v
            stack.append((x + 1, y)); stack.append((x - 1, y))
            stack.append((x, y + 1)); stack.append((x, y - 1))
        }
    }

    func cgImage() -> CGImage? {
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Fast, drag-friendly pixel maker for wallpapers and food.
/// The canvas stays put; only the tools below it scroll, so drawing never fights scrolling.
struct CustomItemMaker: View {
    typealias Kind = Creation.Kind
    enum Tool { case pencil, eraser, fill }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var emu: Emulator
    @ObservedObject private var link = AppLink.shared
    @State private var custom = Color.pink
    @State private var sending = false
    @State private var resultText: String?
    @State private var kind: Kind
    @State private var name: String
    @State private var price: Int
    @State private var bitmap: PixelBitmap
    /// The saved creation this drawing belongs to (set once it's saved, or when editing one).
    @State private var savedID: UUID?
    @State private var seed: UInt64
    @ObservedObject private var creations = Creations.shared
    @State private var history: [[UInt32]] = []
    @State private var image: CGImage?
    @State private var tool: Tool = .pencil
    @State private var brush: Int
    @State private var selected = 3
    @State private var showSent = false
    @State private var sentOK = false
    @State private var lastCell: (Int, Int)?

    private static let paletteColors: [UIColor] = [
        .black, .white, .systemRed, .systemPink, .systemOrange, .systemYellow,
        .systemGreen, .systemMint, .systemCyan, .systemBlue, .systemPurple, .brown,
        UIColor(red: 1, green: 0.8, blue: 0.6, alpha: 1),
        UIColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1),
        UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        UIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
    ]
    /// Pass a saved creation to keep editing it; otherwise starts a blank wallpaper.
    init(editing c: Creation? = nil) {
        let k = c?.kind ?? .wallpaper
        var bm = PixelBitmap(size: k.size)
        if let c, let px = Creations.shared.pixels(c) {
            // saved as 0xAARRGGBB, the canvas keeps RGBA
            bm.px = px.map { v in (v & 0xFF00_0000) | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF) }
        }
        _kind = State(initialValue: k)
        _name = State(initialValue: c?.name ?? "MY ROOM")
        _price = State(initialValue: c?.price ?? 10)
        _bitmap = State(initialValue: bm)
        _savedID = State(initialValue: c?.id)
        _seed = State(initialValue: c?.seed ?? UInt64.random(in: 1...UInt64.max))
        _brush = State(initialValue: k == .wallpaper ? 2 : 1)
    }

    private let packed: [UInt32] = CustomItemMaker.paletteColors.map(PixelBitmap.pack)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvasView
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                ScrollView {
                    VStack(spacing: 14) {
                        kindPicker
                        tools
                        paletteGrid
                        finishBar
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Make something")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert(resultText ?? "", isPresented: $showSent) {
                Button("OK") { if sentOK { dismiss() } }
            }
            .overlay { if sending { BusyOverlay(text: "Sending…") } }
            .onAppear { if image == nil { image = bitmap.cgImage() } }
            .onChange(of: kind) { _ in
                if kind.size != bitmap.size {            // wallpaper <-> food: a different canvas
                    name = kind == .wallpaper ? "MY ROOM" : kind.title.uppercased()
                    brush = kind == .wallpaper ? 2 : 1
                    savedID = nil
                    seed = UInt64.random(in: 1...UInt64.max)
                    resetCanvas()
                } else {                                  // snack <-> meal keeps your drawing
                    if name == "SNACK" || name == "MEAL" { name = kind.title.uppercased() }
                    seed = UInt64.random(in: 1...UInt64.max)
                }
            }
        }
        // Drawing near the edge or pulling down must not close or pop this screen.
        .interactiveDismissDisabled()
    }

    /// Big, clear choice of what you're making (it decides how the device files it).
    private var kindPicker: some View {
        HStack(spacing: 10) {
            ForEach(Kind.allCases, id: \.self) { k in
                Button { kind = k } label: {
                    VStack(spacing: 4) {
                        Image(systemName: k == .wallpaper ? "photo.fill" : k == .meal ? "fork.knife" : "birthday.cake.fill").font(.title2)
                        Text(k.title).font(.system(.headline, design: .rounded))
                        Text(k == .wallpaper ? "A room background" : k == .meal ? "Fills hunger hearts" : "Fills happy hearts")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 78)
                    .background(RoundedRectangle(cornerRadius: 14).fill(kind == k ? Color.purple.opacity(0.18) : Color(.secondarySystemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(kind == k ? Color.purple : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Letters the device can show, in capitals, 12 at most.
    private static func deviceText(_ s: String) -> String {
        let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .!?&-+")
        return String(s.uppercased().filter { ok.contains($0) }.prefix(12))
    }

    private var canvasView: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            ZStack {
                Checker()
                if let img = image {
                    Image(decorative: img, scale: 1)
                        .interpolation(.none)
                        .resizable()
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 3)
            .contentShape(Rectangle())
            .gesture(dragGesture(side: side))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxHeight: 380)
    }

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let n = kind.size
                let cell = side / CGFloat(n)
                let x = min(n - 1, max(0, Int(value.location.x / cell)))
                let y = min(n - 1, max(0, Int(value.location.y / cell)))
                let v: UInt32 = tool == .eraser ? 0 : currentColor
                if lastCell == nil {
                    pushHistory()
                    if tool == .fill {
                        bitmap.fill(x, y, v)
                    } else {
                        bitmap.stamp(x, y, brush: brush, v)
                    }
                } else if tool != .fill, let (lx, ly) = lastCell, lx != x || ly != y {
                    bitmap.line(lx, ly, x, y, brush: brush, v)
                } else {
                    return
                }
                lastCell = (x, y)
                image = bitmap.cgImage()
            }
            .onEnded { _ in lastCell = nil }
    }

    private var tools: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                toolButton(.pencil, "pencil")
                toolButton(.eraser, "eraser")
                toolButton(.fill, "drop.fill")
                Spacer()
                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.title2).frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .disabled(history.isEmpty)
                Button { resetCanvas() } label: {
                    Image(systemName: "trash")
                        .font(.title2).frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
            }
            Picker("Brush", selection: $brush) {
                Text("Fine").tag(1); Text("Medium").tag(2); Text("Thick").tag(4)
            }
            .pickerStyle(.segmented)
        }
    }

    private func toolButton(_ t: Tool, _ icon: String) -> some View {
        Button { tool = t } label: {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 48, height: 48)
                .background(tool == t ? Color.purple.opacity(0.25) : Color.clear)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .foregroundStyle(tool == t ? .purple : .primary)
    }

    /// The colour being drawn with: a palette swatch, or the colour wheel (selected == -1).
    private var currentColor: UInt32 {
        selected >= 0 ? packed[selected] : PixelBitmap.pack(UIColor(custom))
    }

    /// Wraps onto rows instead of scrolling sideways, so nothing is ever cut off.
    private var paletteGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
            // colour wheel: any colour you like
            ColorPicker("", selection: Binding(get: { custom }, set: { custom = $0; selected = -1; if tool == .eraser { tool = .pencil } }), supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.5)
                .frame(width: 48, height: 48)
                .overlay(Circle().strokeBorder(Color.purple, lineWidth: selected == -1 ? 4 : 0).frame(width: 46, height: 46))
            ForEach(packed.indices, id: \.self) { i in
                Button { selected = i; if tool == .eraser { tool = .pencil } } label: {
                    Circle()
                        .fill(Color(CustomItemMaker.paletteColors[i]))
                        .frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .overlay(Circle().strokeBorder(Color.purple, lineWidth: selected == i ? 4 : 0))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var finishBar: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Name").font(.headline)
                    Spacer()
                    Text("\(name.count)/12").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                TextField("NAME", text: Binding(get: { name }, set: { name = CustomItemMaker.deviceText($0) }))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                Text("Capital letters, numbers and . ! ? & - + — just like the device shows them.")
                    .font(.caption2).foregroundStyle(.secondary)
                if kind == .wallpaper {      // only wallpapers are bought in the in-game shop; food goes straight to the bag
                    Text("Price in the shop").font(.headline).padding(.top, 4)
                    HStack(spacing: 8) {
                        ForEach([0, 10, 50, 100, 300, 500], id: \.self) { p in
                            Button { price = p } label: {
                                Text(p == 0 ? "Free" : "\(p) G")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(Capsule().fill(price == p ? Color.purple : Color(.secondarySystemBackground)))
                                    .foregroundStyle(price == p ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                send()
            } label: {
                Label("Send to my Tama", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button { saveOnly() } label: {
                Label("Save to TamaDepa", systemImage: "tray.and.arrow.down.fill")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Everything you send is also kept in TamaDepa › My creations until you delete it.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// Turn the drawing into a real item file (like WebMeets' custom items) and
    /// send it: straight to the device if it's connected with Download, otherwise
    /// into the bag so it arrives with the next Download or when your Tama comes home.
    /// Keep the drawing in TamaDepa (My creations) until you delete it.
    @discardableResult
    private func keep() -> (Creation, [UInt8])? {
        let label = name.trimmingCharacters(in: .whitespaces)
        // PixelBitmap is RGBA in memory; the item builder wants 0xAARRGGBB
        let argb: [UInt32] = bitmap.px.map { v in
            (v & 0xFF00_0000) | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
        }
        var c = Creation(name: label, kind: kind, price: kind == .wallpaper ? price : 0, seed: seed)
        if let id = savedID { c.id = id }
        guard let pkt = Creations.packet(c, pixels: argb) else { return nil }
        let saved = creations.save(c, pixels: argb)
        savedID = saved.id
        return (saved, pkt)
    }

    private func saveOnly() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard keep() != nil else {
            sentOK = false
            resultText = "Couldn't save it. Download the character pack in Tamatown › Settings first."
            showSent = true
            return
        }
        sentOK = true
        resultText = "Saved in TamaDepa under My creations. It stays there until you delete it."
        showSent = true
    }

    /// Turn the drawing into a real item file (like WebMeets' custom items) and
    /// send it: straight to the device if it's connected with Download, otherwise
    /// into the bag so it arrives with the next Download or when your Tama comes home.
    private func send() {
        guard let toy = emu.toy else { return }
        let label = name.trimmingCharacters(in: .whitespaces)
        let kindName = kind.bagKind
        guard let (_, pkt) = keep() else {
            sentOK = false
            resultText = "Couldn't make the item. Download the character pack in Tamatown › Settings first."
            showSent = true
            return
        }
        let town = Town.shared
        let tama = town.name(toy)
        if link.openForDownload {
            link.openForDownload = false
            sending = true
            let tl = TamaLink(emu: emu)
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) { try tl.finishItem(pkt) }.value
                    sending = false
                    link.closeWith = "\(tama) got \(label)! 🎁"
                    dismiss()
                } catch {
                    sending = false
                    sentOK = false
                    resultText = error.localizedDescription
                    showSent = true
                }
            }
        } else {
            town.addToBag(toy, name: label, kind: kindName, packet: pkt)
            sentOK = true
            resultText = town.state(toy).away
                ? "\(label) is in the bag. It goes home with \(tama)."
                : "\(label) is in the bag. It arrives the next time your device connects with Download."
            showSent = true
        }
    }

    private func resetCanvas() {
        bitmap = PixelBitmap(size: kind.size)
        history = []
        lastCell = nil
        image = bitmap.cgImage()
    }

    private func pushHistory() {
        history.append(bitmap.px)
        if history.count > 30 { history.removeFirst() }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        bitmap.px = last
        image = bitmap.cgImage()
    }
}

/// Light checkerboard so erased (transparent) pixels are visible.
private struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            let n = 16
            let c = size.width / CGFloat(n)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            for y in 0..<n {
                for x in 0..<n where (x + y) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * c, y: CGFloat(y) * c, width: c, height: c)),
                             with: .color(Color(white: 0.88)))
                }
            }
        }
    }
}
