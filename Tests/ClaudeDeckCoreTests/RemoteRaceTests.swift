import Foundation
import Network
import Testing
@testable import ClaudeDeckCore

/// Which ways to the Mac are raced, and in what order (made-up interfaces).
@Suite struct RemoteRoutePlanTests {
    /// The owner's case: away from the Mac's LAN on another 192.168.x network, the Tailscale app's
    /// VPN off, in-app Tailscale on.
    let addresses = ["192.168.8.50", "192.168.38.50", "100.81.1.1", "mac.tail1234.ts.net"]
    let wifi = NetworkInterface(name: "en0", address: "192.168.8.183", prefixLength: 24)
    let cellular = NetworkInterface(name: "pdp_ip0", address: "10.20.30.40", prefixLength: 32)
    let loopback = NetworkInterface(name: "lo0", address: "127.0.0.1", prefixLength: 8)
    /// iOS keeps utuns with only a link-local IPv6 address for its own services.
    let systemUtun = NetworkInterface(name: "utun0", address: "fe80::1", prefixLength: 64)
    let tailscaleVPN = NetworkInterface(name: "utun4", address: "100.101.1.2", prefixLength: 32)

    func c(_ address: String, _ route: RemoteRoute) -> RemoteCandidate { RemoteCandidate(address: address, route: route) }

    @Test func otherSubnetsAndTheSystemTailnetAreSkippedWithoutTheVPN() {
        let plan = RemoteRoutePlan.plan(addresses: addresses, inAppEnabled: true,
                                        interfaces: [loopback, wifi, cellular, systemUtun])
        #expect(plan.candidates == [c("192.168.8.50", .system), c("100.81.1.1", .inApp), c("mac.tail1234.ts.net", .inApp)])
        #expect(plan.skipped.map(\.candidate) == [c("192.168.38.50", .system), c("100.81.1.1", .system), c("mac.tail1234.ts.net", .system)])
        #expect(plan.skipped.map(\.reason) == [.otherNetwork, .noTailscaleVPN, .noTailscaleVPN])
    }

    @Test func theTailscaleVPNKeepsTheSystemRouteAndMayRouteOtherSubnets() {
        let plan = RemoteRoutePlan.plan(addresses: addresses, inAppEnabled: true, interfaces: [wifi, tailscaleVPN])
        #expect(plan.skipped.isEmpty)
        #expect(plan.candidates.count == 6)
    }

    @Test func carrierGradeNATIsNotTailscale() {
        // Cellular in 100.64.0.0/10 (CGNAT): not a Tailscale VPN.
        let cgnat = NetworkInterface(name: "pdp_ip0", address: "100.70.1.2", prefixLength: 32)
        #expect(!RemoteRoutePlan.hasTailscaleVPN([cgnat, systemUtun]))
        #expect(RemoteRoutePlan.hasTailscaleVPN([cgnat, tailscaleVPN]))
        #expect(RemoteRoutePlan.hasTailscaleVPN([NetworkInterface(name: "utun2", address: "fd7a:115c:a1e0::5", prefixLength: 128)]))
    }

    @Test func subnetMatchUsesTheNetmask() {
        let wide = NetworkInterface(name: "en0", address: "10.1.2.3", prefixLength: 8)
        let plan = RemoteRoutePlan.plan(addresses: ["10.200.0.9", "192.168.1.20", "172.16.0.4"], inAppEnabled: false, interfaces: [wide])
        #expect(plan.candidates == [c("10.200.0.9", .system)])
        #expect(plan.skipped.count == 2)
    }

    @Test func rememberedInAppGoesFirst() {
        let plan = RemoteRoutePlan.plan(addresses: addresses, inAppEnabled: true, remembered: c("mac.tail1234.ts.net", .inApp),
                                        interfaces: [wifi])
        #expect(plan.candidates.first == c("mac.tail1234.ts.net", .inApp))
        #expect(plan.candidates.dropFirst() == [c("192.168.8.50", .system), c("100.81.1.1", .inApp)])
    }

    @Test func rememberedThatIsntPlannedChangesNothing() {
        // The in-app node is off now: the remembered in-app way isn't one of them.
        let plan = RemoteRoutePlan.plan(addresses: ["192.168.8.50", "100.81.1.1"], inAppEnabled: false, remembered: c("100.81.1.1", .inApp))
        #expect(plan.candidates == [c("192.168.8.50", .system), c("100.81.1.1", .system)])
    }

    @Test func nothingLeftMeansTryEverything() {
        let plan = RemoteRoutePlan.plan(addresses: ["192.168.38.50", "100.81.1.1"], inAppEnabled: false, interfaces: [wifi])
        #expect(plan.candidates == [c("192.168.38.50", .system), c("100.81.1.1", .system)])
        #expect(plan.skipped.isEmpty)
    }

    @Test func bonjourNamesOnlyWhenAdvertisedHere() {
        let bonjour = RemoteBonjour.addressPrefix + "Mac"
        let away = RemoteRoutePlan.plan(addresses: [bonjour, "100.81.1.1"], inAppEnabled: true, interfaces: [cellular], advertised: [])
        #expect(away.candidates == [c("100.81.1.1", .inApp)])
        #expect(away.skipped.first?.reason == .notAdvertising)
        let home = RemoteRoutePlan.plan(addresses: [bonjour, "100.81.1.1"], inAppEnabled: true, interfaces: [wifi], advertised: [bonjour])
        #expect(home.candidates.first == c(bonjour, .system))
    }

    @Test func noInterfacesMeansNoFiltering() {
        // The Mac's own client passes none: as before.
        let plan = RemoteRoutePlan.plan(addresses: addresses, inAppEnabled: false)
        #expect(plan.candidates.map(\.address) == addresses)
        #expect(plan.skipped.isEmpty)
    }

    @Test func currentInterfacesHaveTheirNetmasks() {
        let lo = NetworkInterface.current().first { $0.address == "127.0.0.1" }
        #expect(lo?.prefixLength == 8)
    }
}

/// Stands in for a network: per host, connect to a local port, fail, or never answer.
final class ScriptedDialer: RemoteDialer, @unchecked Sendable {
    enum Step {
        case connect(port: UInt16, after: TimeInterval)
        case fail(String, after: TimeInterval)
        case hang
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let steps: [String: Step]
    private let lock = NSLock()
    private var _calls: [(host: String, at: Date)] = []
    var calls: [(host: String, at: Date)] { lock.withLock { _calls } }

    init(_ steps: [String: Step]) { self.steps = steps }

    func dial(host: String, port _: UInt16, completion: @escaping @Sendable (Result<Int32, Error>) -> Void) {
        lock.withLock { _calls.append((host, Date())) }
        switch steps[host] ?? .hang {
        case .hang:
            return
        case .fail(let message, let delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(.failure(Failure(message: message))) }
        case .connect(let port, let delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if result == 0 { completion(.success(fd)) } else { close(fd); completion(.failure(POSIXError(.ECONNREFUSED))) }
            }
        }
    }
}

/// The race: every way at once (staggered), the first to prove the pairing wins, the others are
/// called off at once and logged as such.
@Suite(.serialized) struct RemoteRaceTests {
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    struct Logged: Equatable {
        var address: String
        var route: RemoteRoute
        var outcome: RemoteConnectionLog.Outcome
        var duration: TimeInterval
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func isConnected(_ client: RemoteHostConnection, _ queue: DispatchQueue) -> Bool {
        queue.sync { if case .connected = client.state { true } else { false } }
    }

    /// A Mac to connect to, on loopback.
    private func host(_ queue: DispatchQueue, key: Data) async throws -> (RemoteServer, UInt16) {
        let server = RemoteServer(port: 0, queue: queue, key: { key }, acceptsPeer: Tailscale.isLoopback)
        queue.sync {
            server.snapshot = RemoteSnapshot(hostName: "Home", sessions: [])
            server.start()
        }
        return (server, try await RemoteLoopbackTests.listeningPort(server, queue: queue))
    }

    /// Accepts TCP and never says a word (what the owner's LAN address did).
    private func silentListener(_ queue: DispatchQueue) async throws -> (NWListener, Box<[NWConnection]>, UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = Box<[NWConnection]>([])
        listener.newConnectionHandler = { connection in
            accepted.value.append(connection)
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        try await waitUntil { queue.sync { listener.port?.rawValue ?? 0 } != 0 }
        return (listener, accepted, queue.sync { listener.port?.rawValue ?? 0 })
    }

    private func client(_ addresses: [String], port: UInt16, key: Data, queue: DispatchQueue, log: Box<[Logged]>) -> RemoteHostConnection {
        let pairing = RemotePairing(id: UUID(), hostName: "Home", addresses: addresses, port: port, key: key, updatedAt: Date())
        let client = RemoteHostConnection(pairing: pairing, deviceName: "Phone", queue: queue)
        client.onAttemptEnded = { address, route, startedAt, outcome in
            log.value.append(Logged(address: address, route: route, outcome: outcome, duration: Date().timeIntervalSince(startedAt)))
        }
        return client
    }

    /// The log, in time: a LAN address that accepts TCP but never answers no longer holds the
    /// others up for its whole handshake timeout; it's called off once the node gets in.
    @Test func aSilentAddressDoesNotHoldUpTheOthers() async throws {
        let queue = DispatchQueue(label: "race-silent")
        let key = RemotePairing.makeKey()
        let (server, port) = try await host(queue, key: key)
        defer { queue.sync { server.stop() } }
        let (listener, accepted, silentPort) = try await silentListener(queue)
        defer { listener.cancel(); queue.sync { accepted.value.forEach { $0.cancel() } } }
        let log = Box<[Logged]>([])
        let client = client(["192.168.8.50", "100.81.1.1"], port: port, key: key, queue: queue, log: log)
        client.systemDialer = ScriptedDialer(["192.168.8.50": .connect(port: silentPort, after: 0), "100.81.1.1": .hang])
        // The node takes a moment to come up.
        client.inAppDialer = ScriptedDialer(["100.81.1.1": .connect(port: port, after: 0.5)])
        client.handshakeTimeout = 10
        let started = Date()
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { isConnected(client, queue) }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(queue.sync { client.connectedRoute } == .inApp)
        let entries = queue.sync { log.value }
        #expect(entries.first { $0.outcome == .connected }?.address == "100.81.1.1")
        // The others: "not needed", logged when called off (not after their timeouts).
        let cancelled = entries.filter { $0.outcome == .cancelled }
        #expect(Set(cancelled.map(\.address)) == ["192.168.8.50", "100.81.1.1"])
        #expect(cancelled.allSatisfy { $0.duration < 2 })
    }

    /// The way that worked last starts at once; the rest wait their turn in the stagger.
    @Test func rememberedInAppStartsFirst() async throws {
        let queue = DispatchQueue(label: "race-remembered")
        let key = RemotePairing.makeKey()
        let (server, port) = try await host(queue, key: key)
        defer { queue.sync { server.stop() } }
        let log = Box<[Logged]>([])
        let client = client(["192.168.8.50", "mac.tail1234.ts.net"], port: port, key: key, queue: queue, log: log)
        let system = ScriptedDialer([:])
        let inApp = ScriptedDialer(["mac.tail1234.ts.net": .connect(port: port, after: 0)])
        client.systemDialer = system
        client.inAppDialer = inApp
        client.preferred = RemoteCandidate(address: "mac.tail1234.ts.net", route: .inApp)
        client.raceStagger = 1
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { isConnected(client, queue) }
        #expect(queue.sync { client.connectedRoute } == .inApp)
        #expect(inApp.calls.map(\.host) == ["mac.tail1234.ts.net"])
        // In before the next way's turn: the LAN address was never dialled.
        #expect(system.calls.isEmpty)
    }

    /// A way that fails brings the next forward instead of waiting out the stagger.
    @Test func aFailedWayBringsTheNextForward() async throws {
        let queue = DispatchQueue(label: "race-forward")
        let key = RemotePairing.makeKey()
        let (server, port) = try await host(queue, key: key)
        defer { queue.sync { server.stop() } }
        let log = Box<[Logged]>([])
        let client = client(["10.9.9.9", "10.9.9.10"], port: port, key: key, queue: queue, log: log)
        client.systemDialer = ScriptedDialer(["10.9.9.9": .fail("Network is unreachable", after: 0), "10.9.9.10": .connect(port: port, after: 0)])
        client.raceStagger = 5
        let started = Date()
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { isConnected(client, queue) }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(queue.sync { log.value.first }?.outcome == .failed("Network is unreachable"))
    }

    /// Each failure carries its own reason, not the last one seen anywhere.
    @Test func failuresKeepTheirOwnReasons() async throws {
        let queue = DispatchQueue(label: "race-reasons")
        let key = RemotePairing.makeKey()
        let (listener, accepted, silentPort) = try await silentListener(queue)
        defer { listener.cancel(); queue.sync { accepted.value.forEach { $0.cancel() } } }
        let log = Box<[Logged]>([])
        let client = client(["10.9.9.9", "10.9.9.10"], port: silentPort, key: key, queue: queue, log: log)
        client.systemDialer = ScriptedDialer(["10.9.9.9": .connect(port: silentPort, after: 0), "10.9.9.10": .fail("boom", after: 0.6)])
        client.handshakeTimeout = 0.3
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { queue.sync { if case .disconnected = client.state { true } else { false } } }
        let outcomes = Dictionary(uniqueKeysWithValues: queue.sync { log.value }.map { ($0.address, $0.outcome) })
        #expect(outcomes["10.9.9.9"] == .failed(String(localized: "The other Mac didn't answer")))
        #expect(outcomes["10.9.9.10"] == .failed("boom"))
    }

    /// Skipped ways are in the log too, with why.
    @Test func skippedWaysAreLogged() async throws {
        let queue = DispatchQueue(label: "race-skipped")
        let key = RemotePairing.makeKey()
        let (server, port) = try await host(queue, key: key)
        defer { queue.sync { server.stop() } }
        let log = Box<[Logged]>([])
        let client = client(["192.168.38.50", "100.81.1.1"], port: port, key: key, queue: queue, log: log)
        client.interfaces = [NetworkInterface(name: "en0", address: "192.168.8.183", prefixLength: 24)]
        client.systemDialer = ScriptedDialer([:])
        client.inAppDialer = ScriptedDialer(["100.81.1.1": .connect(port: port, after: 0)])
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { isConnected(client, queue) }
        let entries = queue.sync { log.value }
        #expect(entries.contains { $0.address == "192.168.38.50" && $0.outcome == .skipped(String(localized: "Not on this network")) })
        #expect(entries.contains { $0.address == "100.81.1.1" && $0.route == .system && $0.outcome == .skipped(String(localized: "The Tailscale VPN is off")) })
    }

    /// Ways added mid-race (the in-app node just came up) start at once.
    @Test func waysAddedWhileRacingStartAtOnce() async throws {
        let queue = DispatchQueue(label: "race-add")
        let key = RemotePairing.makeKey()
        let (server, port) = try await host(queue, key: key)
        defer { queue.sync { server.stop() } }
        let log = Box<[Logged]>([])
        let client = client(["100.81.1.1"], port: port, key: key, queue: queue, log: log)
        client.systemDialer = ScriptedDialer([:])
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        #expect(queue.sync { client.isTrying(.system) })
        #expect(!queue.sync { client.isTrying(.inApp) })
        client.inAppDialer = ScriptedDialer(["100.81.1.1": .connect(port: port, after: 0)])
        queue.sync { client.add([RemoteCandidate(address: "100.81.1.1", route: .inApp)]) }
        try await waitUntil(timeout: 2) { isConnected(client, queue) }
        #expect(queue.sync { client.connectedRoute } == .inApp)
    }

    /// Two ways reach the same Mac: only one proves the key (one login per race).
    @Test func onlyOneWayLogsIn() async throws {
        let queue = DispatchQueue(label: "race-one-login")
        let key = RemotePairing.makeKey()
        let (server, port) = try await host(queue, key: key)
        defer { queue.sync { server.stop() } }
        let log = Box<[Logged]>([])
        let client = client(["10.9.9.9", "10.9.9.10"], port: port, key: key, queue: queue, log: log)
        client.systemDialer = ScriptedDialer(["10.9.9.9": .connect(port: port, after: 0), "10.9.9.10": .connect(port: port, after: 0)])
        client.raceStagger = 0
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { isConnected(client, queue) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(queue.sync { server.peerNames } == ["Phone"])
        #expect(queue.sync { log.value.filter { $0.outcome == .connected } }.count == 1)
    }

    /// The race gives up after `overallTimeout`, whatever is still trying.
    @Test func theRaceHasAnOverallLimit() async throws {
        let queue = DispatchQueue(label: "race-overall")
        let log = Box<[Logged]>([])
        let client = client(["10.9.9.9"], port: 47821, key: RemotePairing.makeKey(), queue: queue, log: log)
        client.systemDialer = ScriptedDialer([:])
        client.lanConnectTimeout = 30
        client.overallTimeout = 0.4
        let started = Date()
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { queue.sync { if case .disconnected = client.state { true } else { false } } }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(queue.sync { log.value.count } == 1)
    }

    /// After the background: a live connection answers the probe; none, no.
    @Test func probeTellsALiveConnection() async throws {
        let queue = DispatchQueue(label: "race-probe")
        let key = RemotePairing.makeKey()
        let (server, port) = try await host(queue, key: key)
        defer { queue.sync { server.stop() } }
        let log = Box<[Logged]>([])
        let client = client(["127.0.0.1"], port: port, key: key, queue: queue, log: log)
        let idle = Box<Bool?>(nil)
        queue.sync { client.probe(timeout: 0.5) { idle.value = $0 } }
        #expect(idle.value == false)
        queue.sync { client.start() }
        defer { queue.sync { client.close() } }
        try await waitUntil { isConnected(client, queue) }
        let alive = Box<Bool?>(nil)
        queue.sync { client.probe(timeout: 2) { alive.value = $0 } }
        try await waitUntil { queue.sync { alive.value != nil } }
        #expect(alive.value == true)
    }
}
