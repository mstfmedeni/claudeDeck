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
        if let via = store.connectedVia, RemoteBonjour.serviceName(of: via) == nil { return via }
        let addresses = store.pairing?.addresses ?? []
        return RemoteHostConnection.raceOrder(addresses).first { RemoteBonjour.serviceName(of: $0) == nil }
    }
}

/// A request to show the screen, from a link (any window picks it up; the frontmost one wins).
struct ScreenRequest: Equatable {
    let token = UUID()
    /// nil: the paired Mac; else a `vnc://` URL.
    let url: URL?
}

/// The screen tab's content: edge to edge, the navigation bar hidden. On iPhone (any orientation:
/// a Max held sideways is a regular width but still has no list beside it) and narrow iPad windows
/// a small button goes back to the list; the session's own × disconnects.
struct ScreenDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let back: () -> Void

    var body: some View {
        ScreenSharingView()
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topLeading) {
                if sizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone {
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

/// The sidebar row for the screen.
struct ScreenTabRow: View {
    var body: some View {
        Label {
            Text("Mac Screen").listFont(.body)
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
