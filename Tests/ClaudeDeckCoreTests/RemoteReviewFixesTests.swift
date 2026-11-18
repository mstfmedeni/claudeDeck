import CryptoKit
import Foundation
import Network
import Testing
@testable import ClaudeDeckCore

/// Push registrations by device, the Tailscale peer check, quiet phones and pushes, bounded caches.
@Suite struct RemotePushAndPeerTests {
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private func device(_ token: UInt8, name: String = "iPhone", environment: String = "production") -> PushDevice {
        PushDevice(token: Data(repeating: token, count: 32), topic: "co.example.app", environment: environment, name: name, addedAt: Date())
    }

    @Test func twoPhonesWithTheSameNameKeepTheirPushes() throws {
        // iOS calls every iPhone "iPhone": the second one must not push the first out.
        let first = try #require([PushDevice]().registering(device(1)))
        let both = try #require(first.registering(device(2)))
        #expect(both.map(\.token) == [device(1).token, device(2).token])
        // The same token again: nothing to save.
        #expect(both.registering(device(1)) == nil)
        // The same token with a change: updated in place, not added.
        let renamed = try #require(both.registering(device(1, name: "Work phone", environment: "development")))
        #expect(renamed.count == 2)
        #expect(renamed[0].name == "Work phone" && renamed[0].environment == "development")
    }

    // MARK: Tailscale peers

    private let interfaces: [(name: String, ip: String)] = [
        ("lo0", "127.0.0.1"), ("en0", "192.168.1.20"), ("utun0", "100.81.1.1"), ("utun0", "fd7a:115c:a1e0::1"),
        // A hotspot handing out carrier-grade NAT addresses to this Mac too.
        ("en1", "100.70.3.4"), ("utun5", "100.99.0.2"), ("utun3", "10.8.0.2"),
    ]

    private func decide(_ remote: String, local: String?, lan: Bool = false, loopback: Bool = false) -> RemotePeerPolicy.Decision {
        RemotePeerPolicy.decide(remoteIP: remote, localIP: local, interfaces: interfaces, lan: lan, loopback: loopback)
    }

    @Test func tailscaleAddressesMustArriveOnTheTailscaleInterface() {
        // A phone through the system VPN, and through the in-app node (100.81.1.200/29).
        #expect(decide("100.81.1.7", local: "100.81.1.1") == .init(accept: true))
        #expect(decide("100.81.1.201", local: "100.81.1.1") == .init(accept: true))
        // The listener reports IPv4 as IPv4-mapped IPv6.
        #expect(decide("::ffff:100.81.1.201", local: "::ffff:100.81.1.1") == .init(accept: true))
        #expect(decide("fd7a:115c:a1e0::5", local: "fd7a:115c:a1e0::1%utun0") == .init(accept: true))
        // Same range, but in through Wi-Fi (carrier-grade NAT, a hotspot): not Tailscale.
        #expect(decide("100.70.3.9", local: "100.70.3.4") == .init(accept: false))
        #expect(decide("100.81.1.7", local: "192.168.1.20") == .init(accept: false))
        #expect(decide("100.81.1.7", local: "192.168.1.20", lan: true) == .init(accept: false))
        // Tailscale's utun number varies: any utun with a tailnet address counts. A utun of
        // another VPN with another range doesn't.
        #expect(decide("100.81.1.7", local: "100.99.0.2") == .init(accept: true))
        #expect(decide("100.81.1.7", local: "10.8.0.2") == .init(accept: false))
    }

    @Test func anUnknownArrivalFallsBackToTheAddress() {
        // Never lock the owner out over a lookup: accepted, and said so.
        #expect(decide("100.81.1.7", local: nil) == .init(accept: true, fellBack: true))
        #expect(decide("100.81.1.7", local: "100.81.1.99") == .init(accept: true, fellBack: true))
    }

    @Test func localNetworkAndLoopbackAreUnchanged() {
        #expect(decide("192.168.1.30", local: "192.168.1.20", lan: true) == .init(accept: true))
        #expect(decide("192.168.1.30", local: "192.168.1.20", lan: false) == .init(accept: false))
        #expect(decide("127.0.0.1", local: "127.0.0.1", loopback: true) == .init(accept: true))
        #expect(decide("127.0.0.1", local: "127.0.0.1", loopback: false) == .init(accept: false))
        #expect(decide("8.8.8.8", local: "192.168.1.20", lan: true, loopback: true) == .init(accept: false))
        #expect(RemotePeerPolicy.acceptsSource("100.81.1.7", lan: false, loopback: false))
        #expect(!RemotePeerPolicy.acceptsSource("192.168.1.30", lan: false, loopback: false))
        #expect(RemotePeerPolicy.acceptsSource("192.168.1.30", lan: true, loopback: false))
    }

    @Test func addressesAreNormalized() {
        #expect(Tailscale.normalized("::ffff:100.81.1.1") == "100.81.1.1")
        #expect(Tailscale.normalized("fe80::1%en0") == "fe80::1")
        #expect(Tailscale.normalized("::1") == "::1")
        #expect(!Tailscale.allInterfaceAddresses().isEmpty)
        #expect(Tailscale.allInterfaceAddresses().contains { $0.name.hasPrefix("lo") && $0.ip == "127.0.0.1" })
    }

    @Test func theServerChecksWhereAConnectionArrived() async throws {
        let queue = DispatchQueue(label: "remote-path-check")
        let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        let seen = Box<[String?]>([])
        let allow = Box(false)
        server.acceptsPath = { _, local in
            seen.value.append(local)
            return allow.value
        }
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        func attempt() async throws -> Bool {
            let client = RemoteHostConnection(pairing: RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date()),
                                              deviceName: "Phone", queue: queue)
            queue.sync { client.start() }
            defer { queue.sync { client.close() } }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                switch queue.sync(execute: { client.state }) {
                case .connected: return true
                case .disconnected, .refused: return false
                case .connecting: try await Task.sleep(for: .milliseconds(20))
                }
            }
            return false
        }
        #expect(try await attempt() == false)
        // The local address is known when the connection comes in.
        #expect(queue.sync { seen.value.first.flatMap { $0 }.map(Tailscale.normalized) } == "127.0.0.1")
        queue.sync { allow.value = true }
        #expect(try await attempt() == true)
    }

    // MARK: Quiet phones

    @Test func aPhoneThatWentQuietGetsPushesAgain() async throws {
        let queue = DispatchQueue(label: "remote-push-quiet")
        let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        let client = RemoteHostConnection(pairing: RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date()),
                                          deviceName: "Phone", queue: queue)
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        let token = Data(repeating: 7, count: 32)
        try await waitUntil { queue.sync { if case .connected = client.state { true } else { false } } }
        queue.sync { _ = client.send(.registerPush(token: token, topic: "co.example.app", environment: "production", deviceName: "iPhone")) }
        try await waitUntil { queue.sync { server.connectedPushTokens.contains(token) } }
        // Heard from just now: connected, no push.
        #expect(queue.sync { server.pushTokensHeard(within: RemoteServer.pushSilence) } == [token])
        // Silent for longer than its pings allow (seen from a later clock): still connected,
        // but it gets the push.
        let later = Date().addingTimeInterval(RemoteServer.pushSilence + 1)
        #expect(queue.sync { server.connectedPushTokens } == [token])
        #expect(queue.sync { server.pushTokensHeard(within: RemoteServer.pushSilence, now: later) }.isEmpty)
        // Longer than the phone's 20 s ping, shorter than the keepalive's 75 s.
        #expect(RemoteServer.pushSilence > 20 && RemoteServer.pushSilence < 75)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite struct RemoteBoundedCacheTests {
    @Test func recentCacheKeepsTheMostRecentlyUsed() {
        var cache = RecentCache<Int, String>(limit: 3)
        cache[1] = "a"
        cache[2] = "b"
        cache[3] = "c"
        // Reading 1 makes it recent: 2 is the oldest now.
        #expect(cache[1] == "a")
        cache[4] = "d"
        #expect(cache.count == 3)
        #expect(cache.peek(2) == nil)
        #expect(cache.keys == [3, 1, 4])
        // Replacing keeps one entry; nil removes.
        cache[3] = "C"
        #expect(cache.count == 3 && cache.keys == [1, 4, 3])
        cache[1] = nil
        #expect(cache.count == 2 && cache.peek(1) == nil)
        // Peeking doesn't count as use.
        _ = cache.peek(4)
        cache[5] = "e"
        cache[6] = "f"
        #expect(cache.peek(4) == nil)
        #expect(cache.keys == [3, 5, 6])
    }

    @MainActor
    @Test func failedDownloadsLeaveNoFolderAndPreviewsGo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "transfer-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteTransferClient()
        client.downloadsRoot = root
        client.failedPreviewLife = 0.05
        client.finishedPreviewLife = 0.05
        client.send = { _ in true }
        let project = UUID()
        func folders() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] }

        // A preview that fails: its folder goes at once, its entry a moment later.
        client.download(project, path: "a/big.bin") { _ in }
        #expect(folders().count == 1)
        client.received(project, path: "a/big.bin", offset: 0, total: 100, data: Data(count: 10), error: nil)
        client.received(project, path: "a/big.bin", offset: 10, total: 100, data: Data(), error: "Can't read this file")
        #expect(folders().isEmpty)
        #expect(client.preview(project, path: "a/big.bin")?.error == "Can't read this file")
        try await Task.sleep(for: .milliseconds(300))
        #expect(client.preview(project, path: "a/big.bin") == nil)

        // A finished preview's entry goes too (the file is the caller's).
        let got = RemoteBoundedCacheTests.Box<URL?>(nil)
        client.download(project, path: "b.txt") { got.value = $0 }
        client.received(project, path: "b.txt", offset: 0, total: 2, data: Data("hi".utf8), error: nil)
        #expect(got.value.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? nil } == "hi")
        try await Task.sleep(for: .milliseconds(300))
        #expect(client.preview(project, path: "b.txt") == nil)

        // A plain download lost with the connection: no folder left either.
        client.download(project, path: "c.bin")
        #expect(folders().count == 2)
        client.connectionLost()
        #expect(folders().count == 1)
        #expect(client.downloadsInFlight == 0)
    }

    @MainActor
    @Test func previewsAreCapped() {
        let root = FileManager.default.temporaryDirectory.appending(path: "transfer-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteTransferClient()
        client.downloadsRoot = root
        // Not connected: each fails at once and stays a minute to show why.
        client.send = { _ in false }
        let project = UUID()
        for index in 0..<(RemoteTransferClient.maxPreviews + 10) {
            client.download(project, path: "f\(index)") { _ in }
        }
        #expect(client.previews.count == RemoteTransferClient.maxPreviews)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)
    }

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
}

@Suite struct RemoteDiscoveryStopTests {
    @Test func noRestartAfterStop() async throws {
        let queue = DispatchQueue(label: "discovery-stop")
        let discovery = RemoteDiscovery(queue: queue)
        queue.sync { discovery.start() }
        #expect(queue.sync { discovery.isBrowsing })
        // A failure while running restarts it.
        queue.sync { discovery.restart(after: 0.05) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(queue.sync { discovery.isBrowsing })
        // A failure reported as it stops (or a restart already scheduled) doesn't bring it back.
        queue.sync {
            discovery.restart(after: 0.05)
            discovery.stop()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(queue.sync { !discovery.isBrowsing && !discovery.isRunning })
        queue.sync { discovery.stop() }
    }
}

@Suite struct RemoteSmallFixesTests {
    @Test func theAgentsAPILeavesTheRemotePortAlone() {
        #expect(RemotePairing.listenPort(environment: [:]) == RemotePairing.defaultPort)
        #expect(RemotePairing.listenPort(environment: ["CLAUDEDECK_REMOTE_PORT": "47833"]) == 47833)
        #expect(RemotePairing.listenPort(environment: ["CLAUDEDECK_REMOTE_PORT": "nope"]) == RemotePairing.defaultPort)
        #expect(RemotePairing.reservedPorts(environment: [:]) == [47821])
        #expect(RemotePairing.reservedPorts(environment: ["CLAUDEDECK_REMOTE_PORT": "47833"]) == [47821, 47833])
    }

    @Test func providerTokenIDsAreEncodedNotInterpolated() throws {
        let key = P256.Signing.PrivateKey()
        let credentials = APNsCredentials(keyID: #"AB"C\D"#, teamID: #"T","x":"1"#, keyPEM: key.pemRepresentation)
        let token = try APNs.token(credentials, issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let parts = token.split(separator: ".").map(String.init)
        func json(_ s: String) throws -> [String: Any] {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            b += String(repeating: "=", count: (4 - b.count % 4) % 4)
            let data = try #require(Data(base64Encoded: b))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let header = try json(parts[0])
        let claims = try json(parts[1])
        #expect(header.count == 2 && header["alg"] as? String == "ES256" && header["kid"] as? String == #"AB"C\D"#)
        #expect(claims.count == 2 && claims["iss"] as? String == #"T","x":"1"# && claims["iat"] as? Int == 1_700_000_000)
    }
}
