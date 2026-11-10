import Network
import os
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
    /// Picked automatically while ClaudeDeck isn't connected (the Mac logged out, the app not running,
    /// away from home), there's no address known to work: the first one Screen Sharing answers on wins
    /// instead of always the first in the list, which may be this network's while away.
    @MainActor static func connect(_ store: RemoteStore, host: String? = nil) async {
        var host = host ?? macHost(store)
        if !hasKnownHost(store) {
            host = await firstAnswering(hosts(store)) ?? host
        }
        guard let host else { return }
        UserDefaults.standard.set(host, forKey: usedHostKey)
        ScreenSharingStore.shared.connect(host: host, name: store.snapshot?.hostName ?? store.pairing?.hostName)
    }

    /// An address picked by hand, or the one ClaudeDeck is connected on: no need to look.
    @MainActor static func hasKnownHost(_ store: RemoteStore) -> Bool {
        let preferred = UserDefaults.standard.string(forKey: preferredHostKey) ?? ""
        if !preferred.isEmpty, hosts(store).contains(preferred) { return true }
        if let via = store.connectedVia, RemoteBonjour.serviceName(of: via) == nil { return true }
        return false
    }

    /// The first of `hosts` taking a TCP connection on Screen Sharing's port, tried in order a moment
    /// apart (like ClaudeDeck's own connection); nil when none answers within `timeout`.
    static func firstAnswering(_ hosts: [String], port: UInt16 = 5900, timeout: Duration = .seconds(5)) async -> String? {
        guard hosts.count > 1, let port = NWEndpoint.Port(rawValue: port) else { return hosts.first }
        return await withTaskGroup(of: String?.self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(300 * index))
                    guard !Task.isCancelled else { return nil }
                    return await answers(host, port: port, timeout: timeout) ? host : nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout + .milliseconds(300 * hosts.count))
                return nil
            }
            var finished = 0
            for await result in group {
                finished += 1
                if let result { group.cancelAll(); return result }
                if finished == hosts.count { break }   // every address failed; don't wait for the timer
            }
            group.cancelAll()
            return nil
        }
    }

    /// Whether `host` takes a TCP connection on `port` within `timeout`.
    private static func answers(_ host: String, port: NWEndpoint.Port, timeout: Duration) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let result: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let done = OSAllocatedUnfairLock(initialState: false)
                let finish: @Sendable (Bool) -> Void = { value in
                    guard done.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    continuation.resume(returning: value)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .cancelled: finish(false)
                    case .waiting: finish(false)   // no route / refused: not this one
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
        connection.cancel()
        return result
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
/// a small button goes back to the list; on a wide iPad it shows and hides the list beside the
/// screen (put away when a session starts). The session's own × disconnects.
struct ScreenDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(RemoteStore.self) private var store
    @AppStorage(ScreenTab.preferredHostKey) private var preferredHost = ""
    /// Connect pressed while ClaudeDeck is away: the addresses are being tried.
    @State private var finding = false
    let back: () -> Void
    /// Wide iPad: show / hide the session list beside the screen.
    var toggleList: (() -> Void)?

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
                if live {
                    let goesBack = sizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone || toggleList == nil
                    Button(action: goesBack ? back : { toggleList?() }) {
                        Image(systemName: goesBack ? "chevron.left" : "sidebar.left")
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
                        // Not connected and automatic: whichever answers first, found on Connect.
                        let label = host.map { ScreenTab.hasKnownHost(store) ? $0 : String(localized: "Automatic") }
                        Text(label ?? String(localized: "No address")).font(.callout.monospaced())
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .disabled(hosts.isEmpty)
            }
            Button {
                finding = true
                Task {
                    await ScreenTab.connect(store)
                    finding = false
                }
            } label: {
                if finding {
                    Label { Text("Finding the Mac…") } icon: { ProgressView() }.frame(maxWidth: .infinity)
                } else {
                    Label("Connect to This Mac", systemImage: "play.display").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(host == nil || finding)
            // In Screen Sharing's own list it opens with a tap even while ClaudeDeck can't reach the Mac.
            if let host {
                if hosts.contains(where: { ScreenSharingStore.shared.isSaved(host: $0) }) {
                    Label("In Connections: tap it there even when ClaudeDeck isn't connected", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button {
                        ScreenSharingStore.shared.add(host: host, name: name)
                    } label: {
                        Label("Add to Connections", systemImage: "plus.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(finding)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("The Mac needs Screen Sharing on: System Settings › General › Sharing.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // Staying connected in the background, quality and the rest (also in a session's More menu).
                Button {
                    ScreenSharingStore.shared.showSettings()
                } label: {
                    Label("Screen Sharing Settings", systemImage: "gearshape").font(.caption)
                }
                .buttonStyle(.borderless)
            }
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
