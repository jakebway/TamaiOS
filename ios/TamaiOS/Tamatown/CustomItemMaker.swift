import SwiftUI

/// Fun, simple pixel maker for wallpapers and food — inspired by the easiest
/// pixel-art apps (big pixels, limited palette, only the tools you need).
struct CustomItemMaker: View {
    enum Kind: String, CaseIterable, Identifiable {
        case wallpaper = "Wallpaper"
        case food = "Food"
        var id: String { rawValue }
        var size: Int { self == .wallpaper ? 128 : 24 }
        var subtitle: String { self == .wallpaper ? "128×128 room" : "24×24 snack" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .wallpaper
    @State private var name = ""
    @State private var price = 10
    @State private var pixels: [[Color]] = []
    @State private var history: [[[Color]]] = []
    @State private var tool: Tool = .pencil
    @State private var selectedColor = Color.pink
    @State private var showSent = false

    enum Tool { case pencil, eraser, fill }

    // Tama-friendly 16-color palette
    private let palette: [Color] = [
        .black, .white, .red, .pink, .orange, .yellow,
        .green, .mint, .cyan, .blue, .purple, .brown,
        Color(red: 1, green: 0.8, blue: 0.6), // skin
        Color(red: 0.6, green: 0.4, blue: 0.2), // wood
        Color(red: 0.9, green: 0.9, blue: 0.9), // light gray
        Color(red: 0.3, green: 0.3, blue: 0.3)  // dark gray
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                kindPicker
                canvas
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
            .onChange(of: kind) { _ in resetCanvas() }
        }
    }

    private var kindPicker: some View {
        Picker("Kind", selection: $kind) {
            ForEach(Kind.allCases) { k in
                Text(k.rawValue).tag(k)
            }
        }
        .pickerStyle(.segmented)
        .padding()
    }

    private var canvas: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height) - 32
            let cell = side / CGFloat(kind.size)
            ZStack {
                Color(.secondarySystemBackground)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 0), count: kind.size), spacing: 0) {
                    ForEach(0..<kind.size * kind.size, id: \.self) { i in
                        let x = i % kind.size
                        let y = i / kind.size
                        Rectangle()
                            .fill(pixels.indices.contains(y) && pixels[y].indices.contains(x) ? pixels[y][x] : .clear)
                            .frame(width: cell, height: cell)
                            .border(Color.black.opacity(0.08), width: 0.3)
                            .onTapGesture { paint(x, y) }
                    }
                }
                .frame(width: side, height: side)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 340)
    }

    private var tools: some View {
        HStack(spacing: 20) {
            toolButton(.pencil, "pencil")
            toolButton(.eraser, "eraser")
            toolButton(.fill, "drop.fill")
            Spacer()
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title2)
            }
            .disabled(history.isEmpty)
            Button { resetCanvas() } label: {
                Image(systemName: "trash")
                    .font(.title2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func toolButton(_ t: Tool, _ icon: String) -> some View {
        Button { tool = t } label: {
            Image(systemName: icon)
                .font(.title2)
                .padding(10)
                .background(tool == t ? Color.purple.opacity(0.2) : Color.clear)
                .clipShape(Circle())
        }
        .foregroundStyle(tool == t ? .purple : .primary)
    }

    private var paletteBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(palette.indices, id: \.self) { i in
                    Circle()
                        .fill(palette[i])
                        .frame(width: 36, height: 36)
                        .overlay(Circle().stroke(selectedColor == palette[i] ? Color.purple : Color.clear, lineWidth: 3))
                        .onTapGesture { selectedColor = palette[i] }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 6)
    }

    private var finishBar: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Stepper("\(price) G", value: $price, in: 0...999)
                    .labelsHidden()
                Text("\(price) G").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                send()
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
        pixels = Array(repeating: Array(repeating: Color.clear, count: s), count: s)
        history = []
        if name.isEmpty { name = kind == .wallpaper ? "My Room" : "Snack" }
    }

    private func pushHistory() {
        history.append(pixels)
        if history.count > 20 { history.removeFirst() }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        pixels = last
    }

    private func paint(_ x: Int, _ y: Int) {
        guard y < pixels.count, x < pixels[y].count else { return }
        pushHistory()
        switch tool {
        case .pencil:
            pixels[y][x] = selectedColor
        case .eraser:
            pixels[y][x] = .clear
        case .fill:
            floodFill(x, y, pixels[y][x], selectedColor)
        }
    }

    private func floodFill(_ startX: Int, _ startY: Int, _ target: Color, _ replacement: Color) {
        guard target != replacement else { return }
        var stack = [(startX, startY)]
        var seen = Set<String>()
        while let (x, y) = stack.popLast() {
            let key = "\(x),\(y)"
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

    private func send() {
        // Placeholder: in a full implementation this would convert the pixel grid
        // into a MyMeets-style file and call the same send path used by imports.
        // For now we just celebrate so the UI feels complete.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showSent = true
    }
}
