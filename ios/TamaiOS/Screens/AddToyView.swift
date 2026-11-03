import SwiftUI
import UniformTypeIdentifiers

/// Pick a ROM dump, check it, name the toy, pick a colour, hatch.
struct AddToyView: View {
    let firstRun: Bool
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Step { case pick, checking, found(RomCheck), failed(ImportError) }
    @State private var step: Step = .pick
    enum AddSheet: String, Identifiable { case picker, help; var id: String { rawValue } }
    @State private var sheet: AddSheet?
    @State private var name = ""
    @State private var color = 0
    @State private var existing: Toy?

    var body: some View {
        let theme = Theme.of(color)
        ZStack {
            LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    if !firstRun {
                        HStack { Spacer(); Button("Cancel") { dismiss() }.foregroundStyle(theme.ink) }
                    }
                    EggBadge(theme: theme).frame(width: 120, height: 150).padding(.top, firstRun ? 30 : 0)
                    content(theme)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .picker: DocumentPicker { check($0) }.ignoresSafeArea()
            case .help: DumpHelpView()
            }
        }
        .onAppear(perform: takePending)
        .onChange(of: model.pendingImport) { _ in takePending() }
    }

    @ViewBuilder
    private func content(_ theme: Theme) -> some View {
        switch step {
        case .pick:
            VStack(spacing: 14) {
                Text(firstRun ? "Welcome to TamaiOS" : "Add a device")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                Text("Bring your own Tamagotchi ON or Meets to your iPhone. You'll need the 8 MB flash dump you read from your own toy.")
                    .font(.system(.body, design: .rounded))
                    .multilineTextAlignment(.center)
                    .opacity(0.85)
            }
            .foregroundStyle(theme.ink)
            if !firstRun && model.devicesFull {
                Text("You have \(AppModel.maxDevices) devices, the most TamaiOS keeps for smooth play. Delete one in Settings to add another.")
                    .font(.system(.callout, design: .rounded).weight(.semibold)).multilineTextAlignment(.center)
                    .foregroundStyle(theme.ink)
            } else {
                BigButton(title: "Choose my ROM file", icon: "folder.fill", theme: theme) { sheet = .picker }
            }
            Text("A .bin file, or a .zip with one inside. You can also share it to TamaiOS from Files or AirDrop.")
                .font(.system(.footnote, design: .rounded)).multilineTextAlignment(.center)
                .foregroundStyle(theme.ink.opacity(0.75))
            Button { sheet = .help } label: {
                Label("How do I get my ROM?", systemImage: "questionmark.circle.fill")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(theme.ink)

        case .checking:
            ProgressView().scaleEffect(1.6).tint(theme.ink).padding(30)
            Text("Checking your file…").font(.system(.headline, design: .rounded)).foregroundStyle(theme.ink)

        case .found(let c):
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label(c.known ? "Found \(c.name)" : "Tamagotchi ON / Meets dump", systemImage: "checkmark.seal.fill")
                        .font(.system(.headline, design: .rounded)).foregroundStyle(.green)
                    if !c.known {
                        Text("This version isn't one TamaiOS has been tested with. It will probably still work — if it doesn't, use Settings › Console › diag and send the result.")
                            .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
                    }
                    if let e = existing {
                        Text("You already have this device (\"\(e.name)\"). Hatching it again replaces nothing — it just opens your existing one.")
                            .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
                    } else {
                        Text("Name").font(.system(.subheadline, design: .rounded).weight(.semibold))
                        TextField(c.shortName, text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .rounded))
                        Text("Shell colour").font(.system(.subheadline, design: .rounded).weight(.semibold))
                        ColorPickerRow(selection: $color)
                    }
                }
            }
            BigButton(title: existing == nil ? "Hatch!" : "Open my device", icon: "sparkles", theme: theme) { hatch(c) }
            Button("Choose a different file") { step = .pick }.foregroundStyle(theme.ink)

        case .failed(let e):
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label(e.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.headline, design: .rounded)).foregroundStyle(.orange)
                    Text(e.errorDescription ?? "").font(.system(.body, design: .rounded))
                }
            }
            BigButton(title: "Try another file", icon: "folder.fill", theme: theme) { sheet = .picker }
            Button { sheet = .help } label: { Label("How do I get my ROM?", systemImage: "questionmark.circle.fill") }
                .foregroundStyle(theme.ink)
        }
    }

    private func takePending() {
        if let u = model.pendingImport {
            model.pendingImport = nil
            if !firstRun && model.devicesFull { return }      // at the device limit: the screen explains it
            check(u)
        }
    }

    private func check(_ url: URL) {
        step = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Step
            do {
                let data = try ToyStore.readPicked(url)
                result = .found(try ToyStore.check(data))
            } catch let e as ImportError {
                result = .failed(e)
            } catch {
                result = .failed(.unreadable(error.localizedDescription))
            }
            DispatchQueue.main.async {
                if case .found(let c) = result {
                    existing = model.toys.first { $0.id == c.stem }
                    name = ""
                }
                withAnimation(.spring()) { step = result }
            }
        }
    }

    private func hatch(_ c: RomCheck) {
        if let e = existing {
            model.showAdd = false
            model.play(e)
            dismiss()
            return
        }
        do {
            let toy = try ToyStore.create(c, name: name.trimmingCharacters(in: .whitespaces), color: color)
            model.added(toy)
            dismiss()
        } catch {
            step = .failed(.unreadable(error.localizedDescription))
        }
    }
}

struct BigButton: View {
    let title: String
    let icon: String
    let theme: Theme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(theme.ink))
                .foregroundStyle(theme.top)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct Card<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
    }
}

struct ColorPickerRow: View {
    @Binding var selection: Int
    var body: some View {
        // Wraps onto extra rows instead of overflowing, so no circle is ever cut off.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Theme.all) { t in
                Button { withAnimation { selection = t.id } } label: {
                    Circle()
                        .fill(LinearGradient(colors: [t.top, t.bottom], startPoint: .top, endPoint: .bottom))
                        .frame(width: 38, height: 38)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: selection == t.id ? 3 : 0))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name)
            }
        }
    }
}

/// A small egg for headers.
struct EggBadge: View {
    let theme: Theme
    var body: some View {
        GeometryReader { g in
            ZStack {
                EggShape().fill(LinearGradient(colors: [theme.top.opacity(0.95), theme.bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                EggShape().stroke(Color.white.opacity(0.7), lineWidth: 3)
                RoundedRectangle(cornerRadius: g.size.width * 0.08)
                    .fill(Color(white: 0.12))
                    .frame(width: g.size.width * 0.46, height: g.size.width * 0.46)
                    .overlay(Text("♥").font(.system(size: g.size.width * 0.2)).foregroundStyle(theme.top))
                    .offset(y: -g.size.height * 0.02)
            }
            .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
        }
    }
}

struct DumpHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            DumpHelpContent()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct DumpHelpContent: View {
    var body: some View {
            List {
                Section("What you need") {
                    Text("A copy (\"dump\") of the 8 MB flash chip inside your own Tamagotchi ON or Tamagotchi Meets. TamaiOS doesn't include any game — it runs the one from your toy.")
                }
                Section("How people usually dump it") {
                    Text("1. Open the toy and find the 8-pin flash chip on the board.")
                    Text("2. Clip a CH341A programmer (set to 3.3 V) onto the chip.")
                    Text("3. Read the chip with the programmer's software and save the result as a .bin file. Read it twice and check both files match.")
                    Text("4. Put the .bin in the Files app (iCloud Drive or On My iPhone) or AirDrop it to your phone, then choose it here.")
                }
                Section("Works with") {
                    Text("Tamagotchi ON: Fairy, Magic, Wonder Garden (EN)")
                    Text("Tamagotchi Meets: Fairy, Magical, Pastel, Sanrio, Sweets, Fantasy (JP)")
                }
                Section("Infrared (Connection › Tamagotchi)") {
                    Text("PLAYDATE, GIFT and MARRY work with your other devices. On the device you're playing choose Connection › Tamagotchi and a mode. When it says WAITING… TamaiOS wakes another of your devices, takes it to the same screen and links them; then press B (the middle button). Both sides use their real data.")
                    Text("The other device sleeps again afterwards and catches up on its time when you switch to it. With only one device, it meets a copy of itself (PLAYDATE only). GIFT and MARRY need a device that's grown enough, like the real thing.")
                }
                Section("Bluetooth") {
                    Text("Connection › App works with TamaiOS's built-in Tamatown: Visit to date, marry, shop and play; Download to get new items.")
                }
            }
            .navigationTitle("Getting your ROM")
    }
}