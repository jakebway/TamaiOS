import SwiftUI
import UniformTypeIdentifiers

struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var emu: Emulator
    @Environment(\.dismiss) private var dismiss

    @AppStorage("soundOn") private var soundOn = true
    @AppStorage("volume") private var volume = 0.6
    @AppStorage("haptics") private var haptics = true
    @AppStorage("liveInBackground") private var live = true
    @AppStorage("callAlerts") private var callAlerts = true
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("neverSleep") private var neverSleep = true
    @AppStorage("showHints") private var showHints = true

    @ObservedObject private var careAlerts = CareAlerts.shared
    @ObservedObject private var liveName = LiveTamaName.shared
    @State private var name = ""
    @State private var nameFor = ""
    @State private var confirmRestart = false
    @State private var showReset = false
    enum SettingsSheet: Identifiable {
        case share(URL), picker
        var id: String { if case .share(let u) = self { return u.path }; return "picker" }
    }
    @State private var sheet: SettingsSheet?
    @State private var restoreFailed = false

    var body: some View {
        NavigationStack {
            Form {
                if let toy = emu.toy {
                    Section {
                        TextField("Device label", text: $name)
                            .onSubmit { rename(toy) }
                        ColorPickerRow(selection: Binding(get: { toy.color }, set: { c in var t = toy; t.color = c; model.update(t) }))
                            .padding(.vertical, 4)
                        Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { emu.syncClock() } } label: { Label("Sync Clock", systemImage: "clock.arrow.circlepath") }
                        Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { emu.sleepNow() } } label: { Label("Sleep Now", systemImage: "moon.zzz.fill") }
                        Button(role: .destructive) { confirmRestart = true } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    } header: { Text(toy.romName) }
                }

                Section {
                    Toggle(isOn: Binding(get: { emu.daytimeMode }, set: { emu.setDaytimeMode($0) })) {
                        Label("Daytime Mode", systemImage: "sun.max.fill")
                    }.disabled(emu.clockChanging || emu.loading || emu.linkBusy || emu.appWaiting)
                    if emu.clockChanging { ProgressView("Updating device clock…") }
                } header: { Text("Clock") } footer: {
                    Text("Start your Tama’s day at noon to play after bedtime. Time continues normally. Turn off to return to your iPhone’s current date and time.")
                }

                Section("Sound & Haptics") {
                    Toggle("Sound", isOn: $soundOn)
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1.2)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    .disabled(!soundOn)
                    Toggle("Haptic Feedback", isOn: $haptics)
                    Toggle("Button Hints", isOn: $showHints)
                }

                Section {
                    Toggle("Background Mode", isOn: $live)
                    Toggle("Prevent Auto-Lock", isOn: $keepAwake)
                    Toggle("Keep Tama Screen On", isOn: $neverSleep)
                } header: { Text("Power & Display") } footer: {
                    Text("Background Mode lets your Tama keep running when you leave TamaiOS. When off, your Tama pauses and its clock catches up when you return.")
                }

                Section {
                    Toggle(isOn: $callAlerts) {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    .onChange(of: callAlerts) { on in
                        if on { careAlerts.prepare() } else { careAlerts.cancelAll() }
                    }
                    if callAlerts && careAlerts.permissionNotRequested {
                        Button("Allow Notifications") { careAlerts.ask() }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Receive alerts when your Tama needs care, goes to the bathroom, gets sick, or grows up.")
                }

                Section {
                    Button { makeBackup() } label: { Label("Back Up", systemImage: "square.and.arrow.up") }
                    Button { sheet = .picker } label: { Label("Restore from Backup", systemImage: "square.and.arrow.down") }
                } header: { Text("Backup") } footer: {
                    Text("TamaiOS saves automatically. Backups are .tamaios files you can keep in Files or iCloud Drive.")
                }

                Section("Devices") {
                    NavigationLink { ToysView() } label: { Label("Devices (\(model.toys.count))", systemImage: "square.grid.2x2.fill") }
                    Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showAdd = true } } label: {
                        Label("Add Device", systemImage: "plus.circle.fill")
                    }
                }

                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.openPickup = true }
                    } label: {
                        Label("TamaDepa In-Store Pick Up", systemImage: "bag.fill")
                    }
                } footer: {
                    Text("Browse items and queue gifts. On your Tama choose Connection › App › Download for pickup.")
                }

                Section("Help") {
                    NavigationLink { ConsoleView() } label: { Label("Console", systemImage: "terminal.fill") }
                }

                Section {
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button(role: .destructive) { showReset = true } label: { Label("Reset Device…", systemImage: "exclamationmark.triangle.fill") }
                        .disabled(emu.toy == nil || emu.loading || AppLink.shared.busy)
                } header: { Text("Danger Zone") } footer: {
                    Text("Erase this Tama and start fresh. Its variant, other devices, and exported backups are kept.")
                }
            }
            .sheet(isPresented: $showReset) { ResetDeviceView().environmentObject(model).environmentObject(emu) }
            .buttonStyle(SettingsRowButtonStyle())
            .environment(\.defaultMinListRowHeight, 52)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { if let t = emu.toy { rename(t) }; dismiss() } label: { Text("Done").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) } } }
            .onAppear { name = emu.toy?.name ?? ""; nameFor = emu.toy?.id ?? ""; careAlerts.prepare() }
            .onChange(of: emu.toy?.id) { _ in name = emu.toy?.name ?? ""; nameFor = emu.toy?.id ?? "" }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in careAlerts.refresh() }
            .onChange(of: soundOn) { _ in emu.applySettings() }
            .onChange(of: volume) { _ in emu.applySettings() }
            .onChange(of: neverSleep) { _ in emu.applySettings() }
            .onChange(of: live) { _ in emu.applySettings(); emu.audio.restart(); careAlerts.prepare() }
            .onChange(of: keepAwake) { v in UIApplication.shared.isIdleTimerDisabled = v }
            .confirmationDialog("Restart the device?", isPresented: $confirmRestart, titleVisibility: .visible) {
                Button("Restart", role: .destructive) { emu.restart(); dismiss() }
            } message: { Text("Like taking the batteries out and putting them back. Your pet is kept.") }
            .sheet(item: $sheet) { which in
                switch which {
                case .share(let u): ActivityView(items: [u])
                case .picker:
                    DocumentPicker { u in
                        if let d = try? ToyStore.readPicked(u) {
                            if emu.restoreBackup(d) { dismiss() } else { restoreFailed = true }
                        } else { restoreFailed = true }
                    }
                    .ignoresSafeArea()
                }
            }
            .alert("That backup doesn't fit this device", isPresented: $restoreFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("Pick a .tamaios backup made from this same device (same ROM version).") }
        }
    }

    private func rename(_ toy: Toy) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard toy.id == nameFor, !n.isEmpty, n != toy.name else { return }
        var t = toy; t.name = n; model.update(t)
    }

    private func makeBackup() {
        DispatchQueue.global(qos: .userInitiated).async {
            let u = emu.backupFile()
            DispatchQueue.main.async { if let u { sheet = .share(u) } }
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ToysView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var emu: Emulator
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: Toy?
    @State private var resetting: Toy?
    @State private var restoring: Toy?
    @State private var shareURL: ShareItem?
    @State private var message: String?

    var body: some View {
        List {
            ForEach(model.toys) { t in
                HStack(spacing: 10) {
                    Button {
                        model.play(t)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            EggBadge(theme: Theme.of(t.color)).frame(width: 34, height: 42)
                            VStack(alignment: .leading) {
                                Text(LiveTamaName.savedName(t.id) ?? t.name).font(.system(.headline, design: .rounded)).foregroundStyle(.primary)
                                Text(t.romName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if emu.toy?.id == t.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button { backUp(t) } label: { Label("Back Up", systemImage: "square.and.arrow.up") }
                        Button { restoring = t } label: { Label("Restore from Backup…", systemImage: "square.and.arrow.down") }
                        Button(role: .destructive) { resetting = t } label: { Label("Reset…", systemImage: "arrow.counterclockwise") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { deleting = t } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Devices")
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Device and Saves", role: .destructive) {
                if let d = deleting { model.remove(d) }
                deleting = nil
            }
        } message: { Text("This removes the ROM and all saves for it from this iPhone. Make a backup first if you might want it back.") }
        .confirmationDialog("Reset \(resetting.map { LiveTamaName.savedName($0.id) ?? $0.name } ?? "")?", isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }), titleVisibility: .visible) {
            Button("Erase This Tama and Start Fresh", role: .destructive) {
                if let t = resetting {
                    do { try model.reset(t) } catch { message = error.localizedDescription }
                }
                resetting = nil
            }
        } message: { Text("Only this device is erased: its Tama, saves and pickup queue. Other devices and your exported backups are kept. Back it up first if you might want it back.") }
        .sheet(item: $shareURL) { ActivityView(items: [$0.url]) }
        .sheet(item: $restoring) { t in
            DocumentPicker { u in
                restoring = nil
                if let d = try? ToyStore.readPicked(u), model.restoreBackup(d, into: t) {
                    message = "Restored \(t.name)."
                } else {
                    message = "That backup doesn't fit \(t.name). Pick a .tamaios backup made from this same device (same ROM version)."
                }
            }
            .ignoresSafeArea()
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func backUp(_ t: Toy) {
        DispatchQueue.global(qos: .userInitiated).async {
            let u = model.backupFile(for: t)
            DispatchQueue.main.async {
                if let u { shareURL = ShareItem(url: u) } else { message = "Couldn't make a backup of \(t.name)." }
            }
        }
    }
}

struct ConsoleView: View {
    @EnvironmentObject var emu: Emulator
    @ObservedObject var console = Console.shared
    @State private var input = ""
    @State private var copied = false
    @State private var copyToken = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(console.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(white: 0.08))
                .foregroundStyle(Color(red: 0.6, green: 1.0, blue: 0.7))
                .onChange(of: console.output) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(["diag", "status", "log", "perf", "params", "help"], id: \.self) { c in
                        Button(c) { console.runScript(c, emu: emu) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Paste or type commands…", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                Button { run() } label: { Image(systemName: "play.fill").padding(10) }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy output") {
                    UIPasteboard.general.string = console.output
                    let token = UUID(); copyToken = token; copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copyToken == token { copied = false } }
                }.accessibilityLabel("Copy all console output")
                Menu {
                    Button {
                        if let text = UIPasteboard.general.string { input = text; focused = true }
                    } label: { Label("Paste commands", systemImage: "doc.on.clipboard") }
                    Button("Clear output", role: .destructive) { console.output = "" }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
    }

    private func run() {
        let t = input
        input = ""
        console.runScript(t, emu: emu)
    }
}
struct ResetDeviceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var emu: Emulator
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var resetting = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Erase and Start Over", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Erase this Tama’s progress, generation history, saves, and pickup queue. Your variant, other devices, and exported backups are kept.")
                }
                Section("Type RESET to confirm") {
                    TextField("RESET", text: $confirmation).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Erase and Start Over", role: .destructive) {
                        guard confirmation == "RESET", !resetting else { return }
                        resetting = true
                        do { try model.resetCurrentDevice(); dismiss() }
                        catch { errorMessage = error.localizedDescription; resetting = false }
                    }.disabled(confirmation != "RESET" || resetting)
                }
            }
            .navigationTitle("Reset Device").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(resetting) } }
            .interactiveDismissDisabled(resetting)
            .alert("Couldn't reset", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }
}
