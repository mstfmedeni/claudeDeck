import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct InAppTailscaleTests {
    @Test func hostnameIsAppNamePlusDeviceName() {
        #expect(InAppTailscale.hostname(deviceName: "Mustafa's iPhone", model: "iPhone") == "claudedeck-mustafas-iphone")
        #expect(InAppTailscale.hostname(deviceName: "Mustafa’s iPad Pro (M4)", model: "iPad") == "claudedeck-mustafas-ipad-pro-m4")
        #expect(InAppTailscale.hostname(deviceName: "Öykü’nün İPad'i", model: "iPad") == "claudedeck-oykunun-ipadi")
        #expect(InAppTailscale.hostname(deviceName: "Işıl -- phone__2", model: "iPhone") == "claudedeck-isil-phone-2")
    }

    @Test func genericDeviceNameFallsBackToTheModel() {
        // Without the user-assigned-device-name entitlement iOS says just "iPhone" / "iPad".
        #expect(InAppTailscale.hostname(deviceName: "iPhone", model: "iPhone") == "claudedeck-iphone")
        #expect(InAppTailscale.hostname(deviceName: "  🙂 ", model: "iPad") == "claudedeck-ipad")
        #expect(InAppTailscale.hostname(deviceName: "", model: "") == "claudedeck")
    }

    @Test func hostnameIsDNSSafeAndShort() {
        let name = InAppTailscale.hostname(deviceName: String(repeating: "Very Long Name ", count: 10), model: "iPhone")
        #expect(name.count <= 63)
        #expect(name.hasPrefix("claudedeck-very-long-name"))
        #expect(!name.hasSuffix("-") && !name.contains("--"))
        #expect(name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
    }

    @Test func tagIsFixed() {
        #expect(InAppTailscale.advertiseTags == ["tag:claudedeck"])
    }

    @Test func recognisesTagRejection() {
        #expect(InAppTailscale.isTagRejection("tsnet.Up: backend: requested tags [tag:claudedeck] are invalid or not permitted"))
        #expect(InAppTailscale.isTagRejection("tag:claudedeck is not permitted"))
        #expect(!InAppTailscale.isTagRejection("tsnet.Up: backend: invalid key: unable to validate API key"))
        #expect(!InAppTailscale.isTagRejection("context deadline exceeded (stage 2)"))
    }

    @Test func tailnetAddresses() {
        #expect(InAppTailscale.isTailnetAddress("100.81.1.201"))
        #expect(InAppTailscale.isTailnetAddress("fd7a:115c:a1e0::1"))
        #expect(InAppTailscale.isTailnetAddress("Mac.tail1234.ts.net"))
        #expect(!InAppTailscale.isTailnetAddress("192.168.1.20"))
        #expect(!InAppTailscale.isTailnetAddress("100.128.0.1"))
        #expect(!InAppTailscale.isTailnetAddress(RemoteBonjour.addressPrefix + "Mac"))
        #expect(!InAppTailscale.isTailnetAddress("mac.local"))
    }

    @Test func routeChoice() {
        // Setting off: the system only, whatever the address (no change for current users).
        #expect(InAppTailscale.routes(for: "100.81.1.201", inAppEnabled: false, remembered: .inApp) == [.system])
        // This network's addresses never use the node.
        #expect(InAppTailscale.routes(for: "192.168.1.20", inAppEnabled: true, remembered: nil) == [.system])
        #expect(InAppTailscale.routes(for: RemoteBonjour.addressPrefix + "Mac", inAppEnabled: true, remembered: .inApp) == [.system])
        // A tailnet address: the system first (the Tailscale app may be on), then the node.
        #expect(InAppTailscale.routes(for: "100.81.1.201", inAppEnabled: true, remembered: nil) == [.system, .inApp])
        #expect(InAppTailscale.routes(for: "mac.tail1234.ts.net", inAppEnabled: true, remembered: .system) == [.system, .inApp])
        // The node worked on this network: straight to it, the system as the backup.
        #expect(InAppTailscale.routes(for: "100.81.1.201", inAppEnabled: true, remembered: .inApp) == [.inApp, .system])
    }
}

/// Stands in for the in-app Tailscale node: connects to this Mac's loopback instead.
final class LoopbackDialer: RemoteDialer, @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var _hosts: [String] = []
    var hosts: [String] { lock.withLock { _hosts } }

    init(port: UInt16) { self.port = port }

    func dial(host: String, port _: UInt16, completion: @escaping @Sendable (Result<Int32, Error>) -> Void) {
        lock.withLock { _hosts.append(host) }
        let port = self.port
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if result == 0 {
                completion(.success(fd))
            } else {
                close(fd)
                completion(.failure(POSIXError(.ECONNREFUSED)))
            }
        }
    }
}

@Suite(.serialized) struct InAppRouteLoopbackTests {
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A tailnet address the system can't reach goes through the in-app node, and the whole
    /// protocol (handshake, encryption, snapshots, files) runs over its socket.
    @Test func unreachableTailnetAddressFallsBackToTheNode() async throws {
        let queue = DispatchQueue(label: "remote-test-inapp")
        let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        let sessionID = UUID()
        queue.sync {
            server.snapshot = RemoteSnapshot(hostName: "Home", sessions: [RemoteSession(id: sessionID, name: "api", project: "api", state: .needsPermission, permissionStamp: 7)])
            server.start()
        }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        let dialer = LoopbackDialer(port: port)
        // 100.64.0.0/10 test address nobody answers on.
        let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: ["100.127.255.254"], port: port, key: key, updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Phone", queue: queue)
        client.inAppDialer = dialer
        let snapshot = Box<RemoteSnapshot?>(nil)
        let result = Box<Bool?>(nil)
        client.onSnapshot = { snapshot.value = $0 }
        client.onPermissionResult = { _, _, applied in result.value = applied }
        server.onPermission = { _, _, _ in true }
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil(timeout: 10) { queue.sync { snapshot.value != nil } }
        #expect(queue.sync { client.connectedRoute } == .inApp)
        #expect(queue.sync { client.connectedAddress } == "100.127.255.254")
        #expect(dialer.hosts == ["100.127.255.254"])
        #expect(queue.sync { client.sendPermission(sessionID: sessionID, stamp: 7, approve: true) })
        try await waitUntil { queue.sync { result.value != nil } }
        #expect(result.value == true)
    }

    /// Remembered: the node goes first, no wait for the system.
    @Test func rememberedNodeGoesFirst() async throws {
        let queue = DispatchQueue(label: "remote-test-inapp-2")
        let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        queue.sync {
            server.snapshot = RemoteSnapshot(hostName: "Home", sessions: [])
            server.start()
        }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: ["100.127.255.254"], port: port, key: key, updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Phone", queue: queue)
        client.inAppDialer = LoopbackDialer(port: port)
        client.rememberedRoutes = ["100.127.255.254": .inApp]
        let started = Date()
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { queue.sync { if case .connected = client.state { true } else { false } } }
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(queue.sync { client.connectedRoute } == .inApp)
    }

    /// This network's addresses never touch the node, even with it on.
    @Test func localAddressStaysOnTheSystem() async throws {
        let queue = DispatchQueue(label: "remote-test-inapp-3")
        let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        queue.sync {
            server.snapshot = RemoteSnapshot(hostName: "Home", sessions: [])
            server.start()
        }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        let dialer = LoopbackDialer(port: port)
        let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Phone", queue: queue)
        client.inAppDialer = dialer
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { queue.sync { if case .connected = client.state { true } else { false } } }
        #expect(queue.sync { client.connectedRoute } == .system)
        #expect(dialer.hosts.isEmpty)
    }
}
