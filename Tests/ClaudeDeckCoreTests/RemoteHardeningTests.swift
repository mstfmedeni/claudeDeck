import Foundation
import Network
import Testing
@testable import ClaudeDeckCore

/// Limits on what a peer can make the other side do: frame sizes, half-open handshakes,
/// remembered failures, push registrations.
@Suite struct RemoteFrameLimitTests {
    @Test func manySmallFramesInOneReadDecodeInOrder() throws {
        let count = 20_000
        var stream = Data()
        for index in 0..<count {
            stream.append(RemoteTerminalOutput.frame(sessionID: UUID(), bytes: Data([UInt8(index % 256)])).encoded())
        }
        // Half a frame at the end waits for the next read.
        let next = RemoteTerminalOutput.frame(sessionID: UUID(), bytes: Data("tail".utf8)).encoded()
        stream.append(next.prefix(10))
        var decoder = RemoteFrameDecoder()
        let frames = try decoder.append(stream)
        #expect(frames.count == count)
        #expect(frames.enumerated().allSatisfy { RemoteTerminalOutput.decode($1)?.bytes == Data([UInt8($0 % 256)]) })
        let rest = try decoder.append(next.dropFirst(10))
        #expect(rest.count == 1 && RemoteTerminalOutput.decode(rest[0])?.bytes == Data("tail".utf8))
        #expect(try decoder.append(Data()).isEmpty)
    }

    @Test func decoderTakesALowerLimit() throws {
        var decoder = RemoteFrameDecoder()
        decoder.maxPayload = 100
        #expect(try decoder.append(RemoteFrame(kind: 1, payload: Data(count: 100)).encoded()).count == 1)
        // Refused from the header alone, before the payload is buffered.
        #expect(throws: RemoteFrameDecoder.DecodeError.frameTooLarge(101)) {
            try decoder.append(RemoteFrame(kind: 1, payload: Data(count: 101)).encoded().prefix(5))
        }
    }

    @Test func outputIsSplitIntoFramesThePeerTakes() throws {
        let id = UUID()
        let bytes = Data((0..<2_500).map { UInt8($0 % 251) })
        let frames = RemoteTerminalOutput.frames(sessionID: id, bytes: bytes, maxChunk: 1_000)
        #expect(frames.count == 3)
        let decoded = frames.compactMap(RemoteTerminalOutput.decode)
        #expect(decoded.allSatisfy { $0.sessionID == id && $0.bytes.count <= 1_000 })
        #expect(decoded.map(\.bytes).reduce(Data(), +) == bytes)
        // Small output stays one frame, as before.
        #expect(RemoteTerminalOutput.frames(sessionID: id, bytes: Data("ab".utf8), maxChunk: 1_000)
                == [RemoteTerminalOutput.frame(sessionID: id, bytes: Data("ab".utf8))])
        #expect(RemoteTerminalOutput.frames(sessionID: id, bytes: Data(), maxChunk: 1_000).count == 1)
    }

    @Test func oversizedFramesAreKnownBeforeSealing() {
        let limit = RemoteFrame.maxPayload
        #expect(RemoteChannel.fits(RemoteFrame(kind: 1, payload: Data(count: limit)), sealed: false))
        #expect(!RemoteChannel.fits(RemoteFrame(kind: 1, payload: Data(count: limit)), sealed: true))
        #expect(RemoteChannel.fits(RemoteFrame(kind: 1, payload: Data(count: limit - 17)), sealed: true))
    }

    @Test func oldFailuresAreForgotten() {
        let server = RemoteServer(port: 0, key: { nil }, acceptsPeer: { _ in false })
        let start = Date()
        server.noteFailure("100.64.0.1", at: start)
        server.noteFailure("100.64.0.2", at: start.addingTimeInterval(300))
        server.pruneFailures(now: start.addingTimeInterval(RemoteServer.failureWindow - 1))
        #expect(server.failingAddresses == 2)
        server.pruneFailures(now: start.addingTimeInterval(RemoteServer.failureWindow + 1))
        #expect(server.failingAddresses == 1)
        server.pruneFailures(now: start.addingTimeInterval(RemoteServer.failureWindow + 301))
        #expect(server.failingAddresses == 0)
    }
}

@Suite(.serialized) struct RemoteLimitLoopbackTests {
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    /// A raw TCP connection to the server: whether the server closed it.
    final class RawPeer: @unchecked Sendable {
        let connection: NWConnection
        let closed = Box(false)
        init(port: UInt16, queue: DispatchQueue) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: queue)
            read()
        }
        private func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, isComplete, error in
                guard let self else { return }
                if isComplete || error != nil { self.closed.value = true; return }
                self.read()
            }
        }
        func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    }

    private func connected(_ client: RemoteHostConnection, queue: DispatchQueue) -> Bool {
        queue.sync { if case .connected = client.state { true } else { false } }
    }

    @Test func handshakeFramesAreSmall() async throws {
        let queue = DispatchQueue(label: "remote-limit-1")
        let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)

        // Announcing a 1 MB frame before proving the key: dropped at the header.
        let peer = RawPeer(port: port, queue: queue)
        defer { peer.connection.cancel() }
        var header = Data([RemoteFrameKind.message.rawValue])
        withUnsafeBytes(of: UInt32(1 << 20).bigEndian) { header.append(contentsOf: $0) }
        peer.send(header)
        try await waitUntil { queue.sync { peer.closed.value } }

        // A real device still pairs, and gets a snapshot far larger than the limit right behind
        // `welcome` (likely in the same read, before its cipher is on).
        let big = RemoteSnapshot(hostName: "Home", sessions: (0..<2_000).map {
            RemoteSession(id: UUID(), name: "session \($0)", project: "project", state: .idle, detail: String(repeating: "x", count: 200))
        })
        queue.sync { server.snapshot = big }
        let client = RemoteHostConnection(pairing: RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date()), deviceName: "Phone", queue: queue)
        let snapshot = Box<RemoteSnapshot?>(nil)
        client.onSnapshot = { snapshot.value = $0 }
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { queue.sync { snapshot.value?.sessions.count == 2_000 } }
        #expect(connected(client, queue: queue))
    }

    @Test func halfOpenHandshakesAreLimitedPerAddress() async throws {
        let queue = DispatchQueue(label: "remote-limit-2")
        let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        server.maxPendingPerAddress = 2
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)

        let first = RawPeer(port: port, queue: queue), second = RawPeer(port: port, queue: queue)
        defer { first.connection.cancel(); second.connection.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        let third = RawPeer(port: port, queue: queue)
        defer { third.connection.cancel() }
        try await waitUntil { queue.sync { third.closed.value } }
        #expect(queue.sync { !first.closed.value && !second.closed.value })

        // Once those go, a device gets in again.
        first.connection.cancel()
        second.connection.cancel()
        try await Task.sleep(for: .milliseconds(300))
        let client = RemoteHostConnection(pairing: RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date()), deviceName: "Phone", queue: queue)
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { connected(client, queue: queue) }
    }

    @Test func messagesTooLargeToSendAreLeftOutAndTheConnectionStays() async throws {
        let queue = DispatchQueue(label: "remote-limit-3")
        let key = RemotePairing.makeKey()
        let sessionID = UUID()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        server.onTerminalOpen = { _ in .init(cols: 80, rows: 24, screen: Data()) }
        queue.sync {
            server.snapshot = RemoteSnapshot(hostName: "Home", sessions: [])
            server.start()
        }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)

        let client = RemoteHostConnection(pairing: RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date()), deviceName: "Phone", queue: queue)
        let snapshot = Box<RemoteSnapshot?>(nil)
        let output = Box(0)
        let started = Box(false)
        client.onSnapshot = { snapshot.value = $0 }
        client.onTerminalStart = { _, _, _, _ in started.value = true }
        client.onTerminalOutput = { _, bytes in output.value += bytes.count }
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { queue.sync { snapshot.value != nil } }

        // A snapshot larger than a frame may be: left out, not sent to make the phone hang up.
        let huge = RemoteSession(id: sessionID, name: "huge", project: "p", state: .idle, detail: String(repeating: "y", count: RemoteFrame.maxPayload))
        queue.sync { server.snapshot = RemoteSnapshot(hostName: "Home", sessions: [huge]) }
        queue.sync { server.snapshot = RemoteSnapshot(hostName: "Home", sessions: [RemoteSession(id: sessionID, name: "small", project: "p", state: .idle)]) }
        try await waitUntil { queue.sync { snapshot.value?.sessions.first?.name == "small" } }
        #expect(connected(client, queue: queue))

        // A burst of output larger than a frame goes in pieces (or as a fresh screen).
        queue.sync { _ = client.openTerminal(sessionID) }
        try await waitUntil { queue.sync { started.value } }
        queue.sync { server.sendOutput(sessionID: sessionID, bytes: Data(repeating: 0x41, count: RemoteFrame.maxPayload + 1)) }
        try await waitUntil(timeout: 10) { queue.sync { output.value > 0 } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(connected(client, queue: queue))
        queue.sync { server.snapshot = RemoteSnapshot(hostName: "Home", sessions: []) }
        try await waitUntil { queue.sync { snapshot.value?.sessions.isEmpty == true } }
    }

    @Test func pushRegistrationsOfImplausibleSizeAreIgnored() async throws {
        let queue = DispatchQueue(label: "remote-limit-4")
        let key = RemotePairing.makeKey()
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        let registered = Box<[PushDevice]>([])
        server.onRegisterPush = { registered.value.append($0) }
        queue.sync { server.start() }
        defer { queue.sync { server.stop() } }
        let port = try await RemoteLoopbackTests.listeningPort(server, queue: queue)
        let client = RemoteHostConnection(pairing: RemotePairing(id: UUID(), hostName: "Home", addresses: ["127.0.0.1"], port: port, key: key, updatedAt: Date()), deviceName: "Phone", queue: queue)
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { connected(client, queue: queue) }

        queue.sync {
            _ = client.send(.registerPush(token: Data(count: 4_096), topic: "co.example.app", environment: "production", deviceName: "Phone"))
            _ = client.send(.registerPush(token: Data(count: 32), topic: String(repeating: "t", count: 4_096), environment: "production", deviceName: "Phone"))
            _ = client.send(.registerPush(token: Data(count: 32), topic: "co.example.app", environment: "production", deviceName: "Phone"))
        }
        try await waitUntil { queue.sync { !registered.value.isEmpty } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(queue.sync { registered.value.map(\.token) } == [Data(count: 32)])
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
