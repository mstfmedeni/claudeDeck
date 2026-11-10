import ScreenSharingKit
import SwiftUI

/// The Mac's screen (open-screen-sharing, GPL-3.0): a sidebar entry next to the sessions. The live
/// session belongs to `ScreenSharingStore`, not the view, so switching back to a session and
/// returning picks the picture up again without reconnecting.
enum ScreenTab {
    /// The sidebar selection for the screen (never a session's id).
    static let id = UUID(uuidString: "5C4EE000-5C4E-5C4E-5C4E-5C4EE0000001")!

    /// `claudedeck://screen` (stable; Shortcuts, widgets, links).
    static func isScreenLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "claudedeck" && url.host?.lowercased() == "screen"
    }

    /// `vnc://host`, handed to the screen-sharing store as is.
    static func isVNCLink(_ url: URL) -> Bool { url.scheme?.lowercased() == "vnc" }

    /// Where to reach the paired Mac's screen: the address the ClaudeDeck connection uses when it
    /// is a real host, else this network's addresses before Tailscale's (Bonjour names only find
    /// ClaudeDeck, not Screen Sharing).
    @MainActor static func macHost(_ store: RemoteStore) -> String? {
        let preferred = UserDefaults.standard.string(forKey: preferredHostKey) ?? ""
        if !preferred.isEmpty, hosts(store).contains(preferred) { return preferred }
        if let via = store.connectedVia, RemoteBonjour.serviceName(of: via) == nil { return via }
        return hosts(store).first
    }

    /// The Mac's addresses Screen Sharing can use (Bonjour names find ClaudeDeck only), in order.
    @MainActor static func hosts(_ store: RemoteStore) -> [String] {
        var list = store.addressesInOrder.filter { RemoteBonjour.serviceName(of: $0) == nil }
        if list.count > 1 { list.removeAll { $0 == "127.0.0.1" } }   // the demo Mac's loopback, only when it's all there is
        if let via = store.connectedVia, RemoteBonjour.serviceName(of: via) == nil, !list.contains(via) { list.insert(via, at: 0) }
        return list
    }

    /// The paired Mac's screen at `host` (nil: `macHost`); the address used is remembered for the sidebar.
    @MainActor static func connect(_ store: RemoteStore, host: String? = nil) {
        guard let host = host ?? macHost(store) else { return }
        UserDefaults.standard.set(host, forKey: usedHostKey)
        ScreenSharingStore.shared.connect(host: host, name: store.snapshot?.hostName ?? store.pairing?.hostName)
    }

    /// The address picked by hand in the screen tab ("" = automatic).
    static let preferredHostKey = "screen.preferredHost"
    /// The address the last connection went to.
    static let usedHostKey = "screen.usedHost"
}

/// A request to show the screen, from a link (any window picks it up; the frontmost one wins).
struct ScreenRequest: Equatable {
    let token = UUID()
    /// nil: the paired Mac; else a `vnc://` URL.
    let url: URL?
    /// false: only show the tab (its Connect card).
    var connect = true
}

/// The screen tab's content: edge to edge, the navigation bar hidden. On iPhone (any orientation:
/// a Max held sideways is a regular width but still has no list beside it) and narrow iPad windows
/// a small button goes back to the list; the session's own × disconnects.
struct ScreenDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(RemoteStore.self) private var store
    @AppStorage(ScreenTab.preferredHostKey) private var preferredHost = ""
    let back: () -> Void

    var body: some View {
        let live = ScreenSharingStore.shared.hasSession
        ScreenSharingView()
            // Only while a session fills the screen: the computer list's own bar has its + and settings.
            .toolbar(live ? .hidden : .automatic, for: .navigationBar)
            // iPhone's tab bar: out of the way while the Mac's screen fills it (the button below goes back).
            .toolbar(live ? .hidden : .automatic, for: .tabBar)
            // No session yet: the paired Mac one tap away, on the address shown (or one picked).
            .safeAreaInset(edge: .bottom) {
                if !ScreenSharingStore.shared.hasSession, store.pairing != nil {
                    connectCard
                }
            }
            .overlay(alignment: .topLeading) {
                if live, sizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                    .padding(.top, 6)
                    .accessibilityLabel(Text("Sessions"))
                }
            }
    }
}

extension ScreenDetailView {
    private var connectCard: some View {
        let hosts = ScreenTab.hosts(store)
        let host = ScreenTab.macHost(store)
        let name = store.snapshot?.hostName ?? store.pairing?.hostName ?? "Mac"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "display").foregroundStyle(Color.accentColor)
                Text(name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    Picker("Address", selection: $preferredHost) {
                        Text("Automatic (\(ScreenTab.automaticHost(store) ?? "–"))").tag("")
                        ForEach(hosts, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(host ?? String(localized: "No address")).font(.callout.monospaced())
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .disabled(hosts.isEmpty)
            }
            Button {
                ScreenTab.connect(store)
            } label: {
                Label("Connect to This Mac", systemImage: "play.display").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(host == nil)
            Text("The Mac needs Screen Sharing on: System Settings › General › Sharing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

extension ScreenTab {
    /// What "automatic" picks right now (shown next to it in the address menu).
    @MainActor static func automaticHost(_ store: RemoteStore) -> String? {
        if let via = store.connectedVia, RemoteBonjour.serviceName(of: via) == nil { return via }
        return hosts(store).first
    }
}

/// The sidebar row for the screen.
struct ScreenTabRow: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Screen").listFont(.body)
                if ScreenSharingStore.shared.hasSession, let host = UserDefaults.standard.string(forKey: ScreenTab.usedHostKey) {
                    Text(host).listFont(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "display")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ScreenSharingStore.shared.isConnected ? Color.accentColor : .secondary)
        }
        .tag(ScreenTab.id)
    }
}

/// Settings › Licenses: the GPL and every third-party notice the app ships (bundled text files).
struct LicensesView: View {
    private static let files = [
        ("GNU General Public License v3", "GPL-3.0"),
        ("Mac Screen (open-screen-sharing and its components)", "SCREEN_SHARING_LICENSES"),
        ("Other components", "THIRD_PARTY_LICENSES"),
    ]

    var body: some View {
        List(Self.files, id: \.1) { title, name in
            NavigationLink(LocalizedStringKey(title)) { LicenseText(title: title, name: name) }
        }
        .navigationTitle("Licenses")
    }
}

private struct LicenseText: View {
    let title: String
    let name: String

    var body: some View {
        ScrollView {
            Text(Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(LocalizedStringKey(title))
        .navigationBarTitleDisplayMode(.inline)
    }
}
