import SwiftUI
import UIKit

/// Fast, drag-friendly pixel maker for wallpapers and food.
/// Uses a single canvas instead of thousands of views.
struct CustomItemMaker: View {
    enum Kind: String, CaseIterable, Identifiable {
        case wallpaper = "Wallpaper"
        case food = "Food"
        var id: String { rawValue }
        var size: Int { self == .wallpaper ? 128 : 24 }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .wallpaper
    @State private var name = "My Room"
    @State private var price = 10
    @State private var pixels: [[UIColor]] = []
    @State private var history: [[[UIColor]]] = []
    @State private var tool: Tool = .pencil
    @State private var selectedColor = UIColor.systemPink
    @State private var showSent = false
    @State private var image: UIImage?
    @State private var strokeStarted = false

    enum Tool { case pencil, eraser, fill }

    private let palette: [UIColor] = [
        .black, .white, .systemRed, .systemPink, .systemOrange, .systemYellow,
        .systemGreen, .systemMint, .systemCyan, .systemBlue, .systemPurple, .brown,
        UIColor(red: 1, green: 0.8, blue: 0.6, alpha: 1),
        UIColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1),
        UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        UIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                kindPicker
                canvasView
                    .padding(.horizontal)
                tools
                paletteBar
                finishBar
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
            .onAppear { resetCanvas() }
            .onChange(of: kind) { _ in
                name = kind == .wallpaper ? "My Room" : "Snack"
                resetCanvas()
            }
        }
    }

    private var kindPicker: some View {
        Picker("Kind", selection: $kind) {
            ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
        }
        .pickerStyle(.segmented)
        .padding()
    }

    private var canvasView: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            ZStack {
                Color(.secondarySystemBackground)
                if let img = image {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: side, height: side)
                        .gesture(dragGesture(side: side))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 320)
    }

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !strokeStarted {
                    pushHistory()
                    strokeStarted = true
                }
                let size = kind.size
                let cell = side / CGFloat(size)
                let x = Int(value.location.x / cell)
                let y = Int(value.location.y / cell)
                guard x >= 0, x < size, y >= 0, y < size else { return }
                paint(x, y, recordHistory: false)
            }
            .onEnded { _ in
                strokeStarted = false
            }
    }

    private var tools: some View {
        HStack(spacing: 16) {
            toolButton(.pencil, "pencil")
            toolButton(.eraser, "eraser")
            toolButton(.fill, "drop.fill")
            Spacer()
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .disabled(history.isEmpty)
            Button { resetCanvas() } label: {
                Image(systemName: "trash")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func toolButton(_ t: Tool, _ icon: String) -> some View {
        Button { tool = t } label: {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(tool == t ? Color.purple.opacity(0.25) : Color.clear)
                .clipShape(Circle())
        }
        .foregroundStyle(tool == t ? .purple : .primary)
    }

    private var paletteBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(palette.indices, id: \.self) { i in
                    Circle()
                        .fill(Color(palette[i]))
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(selectedColor == palette[i] ? Color.purple : Color.clear, lineWidth: 3))
                        .onTapGesture { selectedColor = palette[i] }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func resetCanvas() {
        let s = kind.size
        pixels = Array(repeating: Array(repeating: UIColor.clear, count: s), count: s)
        history = []
        rebuildImage()
    }

    private func pushHistory() {
        history.append(pixels)
        if history.count > 30 { history.removeFirst() }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        pixels = last
        rebuildImage()
    }

    private func paint(_ x: Int, _ y: Int, recordHistory: Bool) {
        guard y >= 0, y < pixels.count, x >= 0, x < pixels[y].count else { return }
        if recordHistory { pushHistory() }
        switch tool {
        case .pencil:
            pixels[y][x] = selectedColor
        case .eraser:
            pixels[y][x] = .clear
        case .fill:
            floodFill(x, y, pixels[y][x], selectedColor)
        }
        rebuildImage()
    }

    private func floodFill(_ startX: Int, _ startY: Int, _ target: UIColor, _ replacement: UIColor) {
        guard target != replacement else { return }
        var stack = [(startX, startY)]
        var seen = Set<Int>()
        let w = pixels.first?.count ?? 0
        while let (x, y) = stack.popLast() {
            let key = y * w + x
            guard y >= 0, y < pixels.count, x >= 0, x < pixels[y].count,
                  !seen.contains(key), pixels[y][x] == target else { continue }
            seen.insert(key)
            pixels[y][x] = replacement
            stack.append((x+1, y))
            stack.append((x-1, y))
            stack.append((x, y+1))
            stack.append((x, y-1))
        }
    }

    private func rebuildImage() {
        let s = kind.size
        let scale: CGFloat = kind == .wallpaper ? 2 : 8
        let size = CGSize(width: CGFloat(s) * scale, height: CGFloat(s) * scale)
        UIGraphicsBeginImageContextWithOptions(size, false, 1)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for y in 0..<s {
            for x in 0..<s {
                let c = pixels[y][x]
                if c.cgColor.alpha > 0 {
                    ctx.setFillColor(c.cgColor)
                    ctx.fill(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale))
                }
            }
        }
        image = UIGraphicsGetImageFromCurrentImageContext()
    }
}
