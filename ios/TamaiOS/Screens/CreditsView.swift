import SwiftUI

/// Thanks to the open-source projects and community work TamaiOS is built on.
struct CreditsView: View {
    private struct Item: Identifiable {
        let name: String, what: String, url: String?
        var id: String { name }
    }
    private let code: [Item] = [
        Item(name: "tg18-emu", what: "by oreo-fox. The emulator core TamaiOS is built on: the toy's processor, memory and screen.", url: "https://github.com/oreo-fox/tg18-emu"),
        Item(name: "Rust", what: "The language the emulator layer is written in.", url: "https://www.rust-lang.org"),
        Item(name: "miniz_oxide", what: "Compression used for saves.", url: "https://github.com/Frommi/miniz_oxide"),
        Item(name: "serde_json", what: "Reading and writing JSON data.", url: "https://github.com/serde-rs/json"),
        Item(name: "XcodeGen", what: "Generates the Xcode project during the build.", url: "https://github.com/yonaskolb/XcodeGen"),
    ]
    private let community: [Item] = [
        Item(name: "MyMeets / WebMeets / TamaDepa", what: "The Tamagotchi community's work on the item and download formats that Tamatown uses.", url: nil),
    ]

    var body: some View {
        List {
            Section {
                ForEach(code) { row($0) }
            } header: { Text("Open source") } footer: {
                Text("Tap one to see its page and licence.")
            }
            Section {
                ForEach(community) { row($0) }
            } header: { Text("Community") }
            Section {
                EmptyView()
            } footer: {
                Text("TamaiOS is an unofficial hobby project. It is not affiliated with or endorsed by Bandai. Tamagotchi is a trademark of Bandai.")
            }
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func row(_ i: Item) -> some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            Text(i.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
            Text(i.what).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        if let u = i.url, let url = URL(string: u) { Link(destination: url) { label } } else { label }
    }
}

/// "beta-v299": the build number the build server stamps on every build.
enum AppVersion {
    static var text: String {
        "beta-v\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")"
    }
}
