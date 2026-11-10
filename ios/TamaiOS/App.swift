import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@main
struct TamaiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() { Prefs.register() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.emu)
                .onOpenURL { model.open($0) }
        }
        .onChange(of: phase) { p in
            switch p {
            case .background: model.emu.enterBackground()
            case .active:
                model.emu.enterForeground()
                UIApplication.shared.isIdleTimerDisabled = Prefs.flag("keepAwake")
            default: break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            if let id = response.notification.request.content.userInfo["deviceID"] as? String,
               let model = AppModel.current, let toy = model.toys.first(where: { $0.id == id }), model.emu.toy?.id != id {
                model.play(toy)
            }
            CareAlerts.shared.cancelAll()
            completionHandler()
        }
    }
    func applicationWillTerminate(_ application: UIApplication) {
        AppModel.current?.emu.willTerminate()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])  // Always suppress foreground banners and notification sounds.
    }
}

/// The toys and which one is in play.
struct IRChoice {
    let candidates: [Toy]
    var blocked: [String: String] = [:]      // device id → why it can't be chosen (shown greyed out)
    let pick: (Toy) -> Void
    let cancel: () -> Void
}

final class AppModel: ObservableObject {
    static weak var current: AppModel?
    let emu = Emulator()
    @Published var toys: [Toy] = []
    @Published var showAdd = false
    /// Saved devices to switch between. Only one runs live (one more wakes briefly for a link), so this is about
    /// memory, start-up checks and keeping the list tidy rather than speed.
    static let maxDevices = 6
    var devicesFull: Bool { toys.count >= AppModel.maxDevices }
    @Published var pendingImport: URL?
    @Published var pendingBackup: URL?
    /// Ask the toy screen to open Tamatown.
    @Published var openTown = false
    @Published var openPickup = false
    /// Several other devices could answer an infrared connection: ask which one.
    @Published var irChoice: IRChoice?

    init() {
        toys = ToyStore.list()
        AppModel.current = self
        // Pictures saved by older builds had see-through holes in the face; take them again.
        if !Prefs.d.bool(forKey: "spriteFormat.v2") {
            for t in toys { try? FileManager.default.removeItem(at: ToyStore.spriteURL(t.id)) }
            Prefs.d.set(true, forKey: "spriteFormat.v2")
        }
        // Tamas born from a marriage were shown as the grown-up picture built from their parts, not the baby the toy draws:
        // take every picture again from the profile page.
        if !Prefs.d.bool(forKey: "spriteSource.v3") {
            for t in toys {
                try? FileManager.default.removeItem(at: ToyStore.spriteURL(t.id))
                Prefs.d.removeObject(forKey: "tamaIdentity.v1." + t.id)
            }
            Prefs.d.set(true, forKey: "spriteSource.v3")
        }
        Town.shared.loadIfPresent()
        if let t = currentToy { emu.load(t) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { IRLink.refreshNames(recheck: false) }   // first fill: right away
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { IRLink.refreshNames() }
        IRLink.watchActiveName()
    }

    var currentToy: Toy? {
        let id = Prefs.d.string(forKey: "currentToy")
        return toys.first { $0.id == id } ?? toys.first
    }

    func play(_ toy: Toy) {
        guard emu.canReplaceDevice else { emu.say("Finish the current operation before changing devices."); return }
        Prefs.d.set(toy.id, forKey: "currentToy")
        emu.load(toy)
        objectWillChange.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { IRLink.refreshNames(recheck: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { IRLink.refreshNames() }
        IRLink.watchActiveName()
    }

    func added(_ toy: Toy) {
        toys = ToyStore.list()
        showAdd = false
        play(toy)
        if Prefs.flag("callAlerts") { Notifier.ask() }
    }

    func update(_ toy: Toy) {
        ToyStore.save(toy)
        toys = ToyStore.list()
        if emu.toy?.id == toy.id { emu.toy = toy }
    }

    func remove(_ toy: Toy) {
        guard emu.canReplaceDevice else { emu.say("Finish the current operation before deleting a device."); return }
        if emu.toy?.id == toy.id { emu.unload(); emu.toy = nil }
        ToyStore.delete(toy.id)
        toys = ToyStore.list()
        if let t = currentToy { play(t) }
    }

    // MARK: per-device backup / restore / reset (any device in the list, without switching to it)

    private func forgetName(_ id: String) {
        Prefs.d.removeObject(forKey: "tamaName.v1." + id)
        Prefs.d.removeObject(forKey: "tamaIdentity.v1." + id)
    }

    /// A backup file for `toy`: its live state if it's the one running, otherwise its last save.
    func backupFile(for toy: Toy) -> URL? {
        if emu.toy?.id == toy.id { return emu.backupFile() }
        guard let d = try? Data(contentsOf: ToyStore.snapURL(toy.id)) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(toy.name.replacingOccurrences(of: "/", with: "-")) \(f.string(from: Date())).tamaios")
        do { try d.write(to: u, options: .atomic) } catch { return nil }
        return u
    }

    /// Restore a backup into `toy`; false if it doesn't fit that device's ROM.
    func restoreBackup(_ data: Data, into toy: Toy) -> Bool {
        guard emu.canReplaceDevice else { emu.say("Finish the current operation before restoring a device."); return false }
        if emu.toy?.id == toy.id { let ok = emu.restoreBackup(data); if ok { forgetName(toy.id) }; return ok }
        guard let rom = try? Data(contentsOf: ToyStore.romURL(toy.id)) else { return false }
        let fits = rom.withUnsafeBytes { r in data.withUnsafeBytes { s in
            tg_check_snapshot(r.bindMemory(to: UInt8.self).baseAddress, r.count, s.bindMemory(to: UInt8.self).baseAddress, s.count)
        } } == 1
        guard fits else { return false }
        let fm = FileManager.default
        let snap = ToyStore.snapURL(toy.id)
        try? fm.removeItem(at: snap.appendingPathExtension("bak"))
        try? fm.copyItem(at: snap, to: snap.appendingPathExtension("bak"))
        guard (try? data.write(to: snap, options: .atomic)) != nil else { return false }
        for u in [ToyStore.flashURL(toy.id), ToyStore.flashMetaURL(toy.id)] {
            try? fm.removeItem(at: u.appendingPathExtension("bak"))
            try? fm.moveItem(at: u, to: u.appendingPathExtension("bak"))
        }
        forgetName(toy.id)
        return true
    }

    /// Erase `toy` and start it fresh, whichever device is running.
    func reset(_ toy: Toy) throws {
        guard emu.canReplaceDevice else { throw ImportError.unreadable("Finish the current operation before resetting.") }
        if emu.toy?.id == toy.id { try resetCurrentDevice(); return }
        guard !IRLink.shared.active else { throw ImportError.unreadable("Finish the infrared link first.") }
        let fm = FileManager.default
        let working = ToyStore.dir(toy.id)
        let staging = ToyStore.root.appendingPathComponent(".reset-" + UUID().uuidString, isDirectory: true)
        let previous = ToyStore.root.appendingPathComponent(".previous-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: ToyStore.romURL(toy.id), to: staging.appendingPathComponent("rom.bin"))
        var fresh = toy
        fresh.created = Date()
        try JSONEncoder().encode(fresh).write(to: staging.appendingPathComponent("toy.json"), options: .atomic)
        try fm.moveItem(at: working, to: previous)
        do { try fm.moveItem(at: staging, to: working) }
        catch { try fm.moveItem(at: previous, to: working); throw error }
        Town.shared.invalidateDeviceCache(toy)
        forgetName(toy.id)
        try? fm.removeItem(at: previous)
        toys = ToyStore.list()
    }

    func resetCurrentDevice() throws {
        guard let toy = emu.toy, emu.canReplaceDevice else { throw ImportError.unreadable("Finish the current operation before resetting.") }
        let fm = FileManager.default
        let working = ToyStore.dir(toy.id)
        let staging = ToyStore.root.appendingPathComponent(".reset-" + UUID().uuidString, isDirectory: true)
        let previous = ToyStore.root.appendingPathComponent(".previous-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        emu.unload()
        do {
            try fm.copyItem(at: ToyStore.romURL(toy.id), to: staging.appendingPathComponent("rom.bin"))
            var fresh = toy
            fresh.created = Date()
            try JSONEncoder().encode(fresh).write(to: staging.appendingPathComponent("toy.json"), options: .atomic)
            try fm.moveItem(at: working, to: previous)
            do { try fm.moveItem(at: staging, to: working) }
            catch { try fm.moveItem(at: previous, to: working); throw error }
            Town.shared.invalidateDeviceCache(toy)
            forgetName(toy.id)
            CareAlerts.shared.cancelAll()
            emu.appWaiting = false
            emu.holdForApp = false
            AppLink.shared.openForDownload = false
            AppLink.shared.closeWith = nil
            AppLink.shared.lastMessage = nil
            toys = ToyStore.list()
            Prefs.d.set(fresh.id, forKey: "currentToy")
            emu.load(fresh)
            try? fm.removeItem(at: previous)
        } catch { emu.load(toy); throw error }
    }

    /// A file shared into the app (Files "Open in", AirDrop, Share sheet).
    func open(_ url: URL) {
        if url.pathExtension.lowercased() == "tamaios" {
            pendingBackup = url
        } else {
            emu.say("All three device variants are included. Choose one with Add Device.")
        }
    }
}

struct Theme: Identifiable, Equatable {
    let id: Int
    let name: String
    let top: Color
    let bottom: Color
    let button: Color
    let ink: Color

    static let all: [Theme] = [
        Theme(id: 0, name: "Bubblegum", top: Color(red: 1.0, green: 0.73, blue: 0.84), bottom: Color(red: 0.96, green: 0.45, blue: 0.66), button: Color(red: 0.99, green: 0.93, blue: 0.62), ink: Color(red: 0.45, green: 0.12, blue: 0.29)),
        Theme(id: 1, name: "Sky", top: Color(red: 0.70, green: 0.88, blue: 1.0), bottom: Color(red: 0.33, green: 0.62, blue: 0.95), button: Color(red: 1.0, green: 0.82, blue: 0.86), ink: Color(red: 0.09, green: 0.23, blue: 0.45)),
        Theme(id: 2, name: "Mint", top: Color(red: 0.76, green: 0.97, blue: 0.86), bottom: Color(red: 0.32, green: 0.80, blue: 0.62), button: Color(red: 0.98, green: 0.80, blue: 0.95), ink: Color(red: 0.06, green: 0.33, blue: 0.24)),
        Theme(id: 3, name: "Lemon", top: Color(red: 1.0, green: 0.96, blue: 0.70), bottom: Color(red: 0.99, green: 0.79, blue: 0.29), button: Color(red: 0.62, green: 0.84, blue: 1.0), ink: Color(red: 0.45, green: 0.30, blue: 0.02)),
        Theme(id: 4, name: "Lilac", top: Color(red: 0.89, green: 0.82, blue: 1.0), bottom: Color(red: 0.63, green: 0.50, blue: 0.95), button: Color(red: 0.70, green: 0.97, blue: 0.86), ink: Color(red: 0.25, green: 0.14, blue: 0.48)),
        Theme(id: 5, name: "Midnight", top: Color(red: 0.32, green: 0.33, blue: 0.48), bottom: Color(red: 0.12, green: 0.12, blue: 0.22), button: Color(red: 0.98, green: 0.62, blue: 0.80), ink: Color(red: 0.92, green: 0.92, blue: 1.0)),
    ]
    static func of(_ i: Int) -> Theme { all[max(0, min(i, all.count - 1))] }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.toys.isEmpty {
                if BundledVariant.anyAvailable { BundledDevicePicker(firstRun: true) }
                else { AddToyView(firstRun: true) }      // no built-in firmware at all: ask for a ROM file
            } else {
                DeviceView()
                    .onAppear { Town.shared.loadIfPresent() }   // Tamatown ready before it's needed
                    .sheet(isPresented: $model.showAdd) {
                        Group {
                            if BundledVariant.anyAvailable { BundledDevicePicker(firstRun: false) }
                            else { AddToyView(firstRun: false) }
                        }.environmentObject(model).environmentObject(model.emu)
                    }
            }
        }
        .preferredColorScheme(nil)
        .sheet(isPresented: Binding(get: { model.irChoice != nil }, set: { if !$0, let c = model.irChoice { model.irChoice = nil; c.cancel() } })) {
            if let c = model.irChoice { LinkPicker(choice: c).environmentObject(model) }
        }
    }
}

/// The Tama's own picture (from its profile page), or the egg until it is known.
struct LinkPortrait: View {
    let toy: Toy
    var body: some View {
        let theme = Theme.of(toy.color)
        // a picture only counts once this Tama's own name has been read (an egg has neither yet)
        if LiveTamaName.savedName(toy.id) != nil, let img = UIImage(contentsOfFile: ToyStore.spriteURL(toy.id).path) {
            Image(uiImage: Self.sharp(img.trimmedToArt())).interpolation(.high).resizable().scaledToFit()
                .padding(10).frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [theme.top, theme.bottom.opacity(0.75)], startPoint: .top, endPoint: .bottom)))
        } else {
            EggBadge(theme: theme).frame(width: 44, height: 55).frame(width: 56, height: 56)
        }
    }
    private static func sharp(_ img: UIImage) -> UIImage {
        let w = max(1, Int(img.size.width * img.scale)), h = max(1, Int(img.size.height * img.scale))
        let k = max(1, Int((300.0 / Double(max(w, h))).rounded(.up)))
        let size = CGSize(width: w * k, height: h * k)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// "Link with which device?": big rows with the device's look, its Tama's name and its firmware.
struct LinkPicker: View {
    let choice: IRChoice
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("Pick the device that joins your connection. It wakes up, links, and goes back to sleep afterwards.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.bottom, 4)
                    ForEach(Array(choice.candidates.enumerated()), id: \.element.id) { i, t in
                        Button {
                            Prefs.d.set(t.id, forKey: "ir.lastPartner")
                            model.irChoice = nil
                            choice.pick(t)
                        } label: {
                            HStack(spacing: 14) {
                                LinkPortrait(toy: t)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LiveTamaName.savedName(t.id) ?? t.name).font(.system(.title3, design: .rounded).weight(.bold))
                                    Text(t.name + " · " + t.romName).font(.caption).foregroundStyle(.secondary)
                                    if let why = choice.blocked[t.id] {
                                        Text(why).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                    } else if i == 0, Prefs.d.string(forKey: "ir.lastPartner") == t.id {
                                        Text("Last used").font(.caption2.weight(.semibold)).foregroundStyle(.pink)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))
                        }.buttonStyle(.plain)
                        .disabled(choice.blocked[t.id] != nil)
                        .opacity(choice.blocked[t.id] != nil ? 0.4 : 1)
                    }
                }.padding(20)
            }
            .navigationTitle("Link with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.irChoice = nil; choice.cancel() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
struct BundledDevicePicker: View {
    var firstRun: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var installing = false
    @State private var errorMessage: String?
    @State private var ownRom = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.pink)
                    Text(firstRun ? "Choose Your Device" : "Add a Device").font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("Three worlds, ready to hatch. Everything you need is included.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    ForEach(BundledVariant.all) { variant in
                        Button { install(variant) } label: {
                            HStack(spacing: 18) {
                                EggBadge(theme: Theme.of(variant.color)).frame(width: 52, height: 65)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(variant.name).font(.system(.title3, design: .rounded).weight(.bold))
                                    Text("English • Included").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.padding(20).background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemBackground)))
                        }.buttonStyle(.plain).disabled(installing)
                    }
                    if installing { ProgressView("Preparing your device…") }
                    if !model.devicesFull || firstRun {
                        Button { ownRom = true } label: {
                            Text("Use my own ROM file…").font(.footnote).foregroundStyle(.secondary).underline()
                        }.buttonStyle(.plain).disabled(installing).padding(.top, 6)
                    }
                }.padding(24)
            }
            .background(LinearGradient(colors: [Color.pink.opacity(0.08), Color.purple.opacity(0.06)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .toolbar { if !firstRun { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(installing) } } }
            .sheet(isPresented: $ownRom) { AddToyView(firstRun: false).environmentObject(model).environmentObject(model.emu) }
            .alert("Couldn't prepare your device", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }
    private func install(_ variant: BundledVariant) {
        guard !installing else { return }
        installing = true
        DispatchQueue.main.async {
            do { model.added(try ToyStore.installBundled(variant)) }
            catch { errorMessage = error.localizedDescription; installing = false }
        }
    }
}
