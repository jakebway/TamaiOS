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
    let pick: (Toy) -> Void
    let cancel: () -> Void
}

final class AppModel: ObservableObject {
    static weak var current: AppModel?
    let emu = Emulator()
    @Published var toys: [Toy] = []
    @Published var showAdd = false
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
        Town.shared.loadIfPresent()
        if let t = currentToy { emu.load(t) }
    }

    var currentToy: Toy? {
        let id = Prefs.d.string(forKey: "currentToy")
        return toys.first { $0.id == id } ?? toys.first
    }

    func play(_ toy: Toy) {
        Prefs.d.set(toy.id, forKey: "currentToy")
        emu.load(toy)
        objectWillChange.send()
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
        if emu.toy?.id == toy.id { emu.unload(); emu.toy = nil }
        ToyStore.delete(toy.id)
        toys = ToyStore.list()
        if let t = currentToy { play(t) }
    }

    func resetCurrentDevice() throws {
        guard let toy = emu.toy, !emu.loading, !AppLink.shared.busy else { throw ImportError.unreadable("Finish the current operation before resetting.") }
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
            DaytimeClock.disable(toy.id)
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
                BundledDevicePicker(firstRun: true)
            } else {
                DeviceView()
                    .onAppear { Town.shared.loadIfPresent() }   // Tamatown ready before it's needed
                    .sheet(isPresented: $model.showAdd) {
                        BundledDevicePicker(firstRun: false).environmentObject(model).environmentObject(model.emu)
                    }
            }
        }
        .preferredColorScheme(nil)
        .confirmationDialog("Link with which device?", isPresented: Binding(get: { model.irChoice != nil }, set: { _ in }), titleVisibility: .visible) {
            if let c = model.irChoice {
                ForEach(c.candidates) { t in
                    Button(t.name) { model.irChoice = nil; c.pick(t) }
                }
                Button("Cancel", role: .cancel) { model.irChoice = nil; c.cancel() }
            }
        } message: {
            Text("It wakes up, joins your connection, and goes back to sleep afterwards.")
        }
    }
}
struct BundledDevicePicker: View {
    var firstRun: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var installing = false
    @State private var errorMessage: String?
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
                }.padding(24)
            }
            .background(LinearGradient(colors: [Color.pink.opacity(0.08), Color.purple.opacity(0.06)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .toolbar { if !firstRun { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(installing) } } }
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
