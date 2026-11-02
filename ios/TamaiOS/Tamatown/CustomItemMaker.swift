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
    enum Kind: String, CaseIterable, Identifiable {
        case wallpaper = "Wallpaper"
        case food = "Food"
        var id: String { rawValue }
        var size: Int { self == .wallpaper ? 128 : 24 }
    }
    enum Tool { case pencil, eraser, fill }

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .wallpaper
    @State private var name = "My Room"
    @State private var price = 10
    @State private var bitmap = PixelBitmap(size: 128)
    @State private var history: [[UInt32]] = []
    @State private var image: CGImage?
    @State private var tool: Tool = .pencil
    @State private var brush = 2
    @State private var selected = 3
    @State private var showSent = false
    @State private var lastCell: (Int, Int)?

    private static let paletteColors: [UIColor] = [
        .black, .white, .systemRed, .systemPink, .systemOrange, .systemYellow,
        .systemGreen, .systemMint, .systemCyan, .systemBlue, .systemPurple, .brown,
        UIColor(red: 1, green: 0.8, blue: 0.6, alpha: 1),
        UIColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1),
        UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        UIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
    ]
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
            .alert("Sent!", isPresented: $showSent) {
                Button("OK") { dismiss() }
            } message: {
                Text("Your \(kind.rawValue.lowercased()) is on its way to your Tama.")
            }
            .onAppear { if image == nil { resetCanvas() } }
            .onChange(of: kind) { _ in
                name = kind == .wallpaper ? "My Room" : "Snack"
                brush = kind == .wallpaper ? 2 : 1
                resetCanvas()
            }
        }
        // Drawing near the edge or pulling down must not close or pop this screen.
        .interactiveDismissDisabled()
    }

    private var kindPicker: some View {
        Picker("Kind", selection: $kind) {
            ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
        }
        .pickerStyle(.segmented)
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
                let v: UInt32 = tool == .eraser ? 0 : packed[selected]
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

    /// Wraps onto rows instead of scrolling sideways, so nothing is ever cut off.
    private var paletteGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
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
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Stepper(value: $price, in: 0...999) {
                    Text("\(price) G")
                }
                .fixedSize()
            }
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showSent = true
            } label: {
                Label("Send to my Tama", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
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
