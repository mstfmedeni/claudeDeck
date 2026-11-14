import AuthenticationServices
import Foundation
import Observation
import TailscaleKit
import UIKit

/// The app's own Tailscale node (Settings › In-App Tailscale): reaches the paired Mac's tailnet
/// address without the Tailscale app's VPN. Off by default; while off, TailscaleKit is never
/// started. Userspace networking: it works next to any VPN profile.
///
/// Only the remote connection (RemoteHostConnection) goes through it. Mac Screen
/// (open-screen-sharing) still uses the system's network: to cover it, a loopback forwarder
/// (a 127.0.0.1 listener whose connections are spliced to `tailscale_dial` sockets) would sit
/// between ScreenTab's NWConnection and this node.
@MainActor
@Observable
final class InAppTailnet {
    enum Status: Equatable {
        /// The setting is off.
        case off
        /// On, never signed in (or signed out).
        case signedOut
        /// Signed in before; the node starts when a connection needs it.
        case idle
        case starting
        /// Waiting for the browser login.
        case signingIn
        case connected(ip: String?, name: String?)
        case failed(String, tagRejected: Bool)
    }

    static let enabledKey = "tailscale.inApp"

    var enabled: Bool = UserDefaults.standard.bool(forKey: InAppTailnet.enabledKey) {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled {
                status = hasState ? .idle : .signedOut
            } else {
                stop()
                status = .off
            }
            onChange?()
        }
    }

    private(set) var status: Status = .off
    /// Called when the node becomes usable or the setting changes (the store reconnects).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored let dialer = Dialer()

    @ObservationIgnored private var node: TailscaleNode?
    @ObservationIgnored private var startTask: Task<TailscaleNode?, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var login: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = LoginAnchor()
    /// The user tapped Sign In: open the login page when the node has one.
    @ObservationIgnored private var wantsSignIn = false
    @ObservationIgnored private var inForeground = true
    /// Bumped when the node stops: late results from the old one are ignored.
    @ObservationIgnored private var generation = 0

    init() {
        dialer.owner = self
        if enabled { status = hasState ? .idle : .signedOut }
    }

    // MARK: State on disk

    /// Application Support/Tailscale (not backed up: a restored node would clash with this one).
    nonisolated static var stateDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Tailscale", directoryHint: .isDirectory)
    }

    /// Written once the node first runs: tsnet writes its own state file as soon as it starts,
    /// signed in or not.
    private static var signedInMarker: URL { stateDirectory.appending(path: "claudedeck-signed-in") }

    /// Signed in (the node ran) and not signed out since.
    private var hasState: Bool { FileManager.default.fileExists(atPath: Self.signedInMarker.path) }

    private func forgetState() { try? FileManager.default.removeItem(at: Self.stateDirectory) }

    nonisolated private static func prepareDirectory() throws -> URL {
        var directory = stateDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    /// The name in the tailnet: `claudedeck-<device name>`. iOS gives apps the device's own
    /// name only with an entitlement this app doesn't have, so this is usually `claudedeck-iphone`.
    static var hostname: String {
        InAppTailscale.hostname(deviceName: UIDevice.current.name, model: UIDevice.current.model)
    }

    // MARK: Actions

    func signIn() {
        guard enabled else { return }
        wantsSignIn = true
        if case .failed = status { stop() }
        status = .starting
        Task { await startNode() }
    }

    func cancelSignIn() {
        wantsSignIn = false
        login?.cancel()
        login = nil
        stop()
        // Never got in: start clean next time.
        if !hasState { forgetState() }
        status = enabled ? (hasState ? .idle : .signedOut) : .off
    }

    /// Logs the node out of the tailnet (best effort), stops it and deletes its state.
    func signOut() {
        let node = self.node
        self.node = nil
        stop()
        status = enabled ? .signedOut : .off
        Task {
            if let node { await Self.logout(node) }
            self.forgetState()
            self.onChange?()
        }
    }

    /// A connection is coming that may need the node: start it now (signed in before only).
    func prewarm() {
        guard enabled, hasState, node == nil, startTask == nil else { return }
        Task { await startNode() }
    }

    func setForeground(_ foreground: Bool) {
        inForeground = foreground
        if foreground, node != nil { startPolling() } else { pollTask?.cancel(); pollTask = nil }
    }

    // MARK: Node

    @discardableResult
    private func startNode() async -> TailscaleNode? {
        if let node { return node }
        if let startTask { return await startTask.value }
        let generation = self.generation
        if status != .signingIn { status = .starting }
        let hostname = Self.hostname
        let task = Task.detached { () -> Result<TailscaleNode, Error> in
            do {
                let directory = try Self.prepareDirectory()
                let config = Configuration(hostName: hostname, path: directory.path, authKey: nil,
                                           controlURL: kDefaultControlURL, ephemeral: false,
                                           advertiseTags: InAppTailscale.advertiseTags)
                // Starting with no login asks control for a login URL (tsnet does it itself).
                return .success(try TailscaleNode(config: config, logger: QuietLog()))
            } catch {
                return .failure(error)
            }
        }
        startTask = Task { [weak self] in
            let result = await task.value
            guard let self, self.generation == generation else { return nil }
            self.startTask = nil
            switch result {
            case .success(let node):
                self.node = node
                self.watchLogin(node)
                self.startPolling()
                return node
            case .failure(let error):
                self.status = .failed(Self.message(error), tagRejected: false)
                return nil
            }
        }
        return await startTask?.value
    }

    /// `up` returns once the node runs, or with the backend's error (a refused tag shows here).
    private func watchLogin(_ node: TailscaleNode) {
        let generation = self.generation
        Task { [weak self] in
            do {
                try await node.up()
            } catch {
                guard let self, self.generation == generation else { return }
                let message = Self.message(error)
                self.login?.cancel()
                self.login = nil
                self.wantsSignIn = false
                self.stop()
                // A login that never finished leaves nothing worth keeping.
                if !self.hasState || InAppTailscale.isTagRejection(message) { self.forgetState() }
                self.status = .failed(message, tagRejected: InAppTailscale.isTagRejection(message))
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        guard inForeground, let node else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let data = try? await node.statusJSON() else { break }
                guard let self, self.node === node else { return }
                self.apply(NodeStatus(data))
                let fast = self.status == .signingIn || self.status == .starting
                try? await Task.sleep(for: .seconds(fast ? 0.5 : 5))
            }
        }
    }

    private func apply(_ node: NodeStatus) {
        switch node.backendState {
        case "Running":
            let wasConnected = { if case .connected = status { true } else { false } }()
            status = .connected(ip: node.ips.first { $0.contains(".") } ?? node.ips.first, name: node.dnsName)
            if !hasState { FileManager.default.createFile(atPath: Self.signedInMarker.path, contents: Data()) }
            if wantsSignIn {
                wantsSignIn = false
                login?.cancel()
                login = nil
            }
            if !wasConnected { onChange?() }
        case "NeedsLogin":
            if wantsSignIn {
                status = .signingIn
                if login == nil, let url = node.authURL { openLogin(url) }
            } else if node.authURL != nil {
                // Logged out elsewhere (removed in the admin console, key expired): sign in again.
                stop()
                forgetState()
                status = .signedOut
                onChange?()
            }
        case "NeedsMachineAuth":
            status = .failed(String(localized: "Waiting for the tailnet's admin to approve this device."), tagRejected: false)
        default:
            if status != .signingIn { status = .starting }
        }
    }

    private func openLogin(_ url: URL) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            // Closed by the user (Cancel) or by us once the node runs.
            MainActor.assumeIsolated {
                guard let self, self.login != nil else { return }
                self.login = nil
                if self.status == .signingIn { self.cancelSignIn() }
            }
        }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        login = session
        session.start()
    }

    private func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        startTask?.cancel()
        startTask = nil
        if let node {
            self.node = nil
            Task.detached { try? await node.close() }
        }
    }

    /// The handle once the node runs (a connection waiting for it), nil if it can't.
    fileprivate func runningHandle(timeout: TimeInterval) async -> TailscaleHandle? {
        guard enabled, hasState || node != nil else { return nil }
        guard let node = await startNode() else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, self.node === node {
            if let data = try? await node.statusJSON(), NodeStatus(data).backendState == "Running" {
                apply(NodeStatus(data))
                return await node.tailscale
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// POST /localapi/v0/logout through the node's loopback LocalAPI, then closes the node.
    nonisolated private static func logout(_ node: TailscaleNode) async {
        guard let loopback = try? await node.loopback(), let ip = loopback.ip, let port = loopback.port,
              let url = URL(string: "http://\(ip):\(port)/localapi/v0/logout") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        let credential = Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        _ = try? await URLSession(configuration: .ephemeral).data(for: request)
        try? await node.close()
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? TailscaleError {
            switch error {
            case .internalError(let details?), .cannotFetchIps(let details?), .unknownPosixError(_, let details?), .posixError(_, let details?):
                return details.replacingOccurrences(of: "tsnet.Up: backend: ", with: "")
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Dialer

    /// Opens connections through the node (RemoteHostConnection's in-app route).
    final class Dialer: RemoteDialer, @unchecked Sendable {
        @MainActor weak var owner: InAppTailnet?

        func dial(host: String, port: UInt16, completion: @escaping @Sendable (Result<Int32, Error>) -> Void) {
            Task { @MainActor [weak self] in
                guard let handle = await self?.owner?.runningHandle(timeout: 12) else {
                    completion(.failure(DialError(message: String(localized: "In-app Tailscale isn't connected"))))
                    return
                }
                // IPv6 literals need brackets in host:port.
                let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
                // tailscale_dial blocks until connected.
                Task.detached {
                    var connection: Int32 = 0
                    if tailscale_dial(handle, "tcp", address, &connection) == 0 {
                        completion(.success(connection))
                    } else {
                        completion(.failure(DialError(message: String(localized: "Couldn't reach the Mac through in-app Tailscale"))))
                    }
                }
            }
        }
    }

    struct DialError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// The parts of `tailscale_status_json` (ipnstate.Status) the settings show.
private struct NodeStatus {
    var backendState: String?
    var authURL: URL?
    var ips: [String] = []
    var dnsName: String?

    init(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        backendState = root["BackendState"] as? String
        if let auth = root["AuthURL"] as? String, !auth.isEmpty { authURL = URL(string: auth) }
        let me = root["Self"] as? [String: Any]
        ips = me?["TailscaleIPs"] as? [String] ?? root["TailscaleIPs"] as? [String] ?? []
        if let name = me?["DNSName"] as? String, !name.isEmpty { dnsName = name.hasSuffix(".") ? String(name.dropLast()) : name }
    }
}

/// tsnet's own logs stay out of the console (-1 discards them).
private struct QuietLog: LogSink {
    var logFileHandle: Int32? = -1
    func log(_ message: String) {}
}

/// Where the login sheet appears.
private final class LoginAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}
