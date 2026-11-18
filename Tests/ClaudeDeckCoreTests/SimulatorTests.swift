import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct SimulatorTests {
    /// Works under both `swift test` and Xcode (no Bundle.module there).
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/simctl-devices.json")

    static func devices() throws -> [Simulator] {
        try SimulatorList.parse(Data(contentsOf: fixtureURL))
    }

    // MARK: simctl list -j

    @Test func parsesAvailableAndBootedDevicesInOrder() throws {
        let devices = try Self.devices()
        // Unavailable iPad (no runtime) and the tvOS device are left out.
        #expect(!devices.contains { $0.udid == "B9427CA0-3499-416C-8D01-60FEB2D87374" })
        #expect(!devices.contains { $0.name.hasPrefix("Apple TV") })
        #expect(devices.count == 7)
        // Booted first (newest runtime first), then iOS → watchOS → visionOS, newest runtime first.
        #expect(devices.map(\.name) == [
            "iPhone 18 Pro", "iPhone 16 Pro Max",
            "iPhone 16", "iPhone 19", "iPhone 16",
            "Apple Watch Series 11 (46mm)", "Apple Vision Pro",
        ])
        #expect(devices[0].isBooted && devices[1].isBooted && !devices[2].isBooted)
        // UDIDs are normalised to upper case.
        #expect(devices[2].udid == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(devices.last?.state == "Shutting Down")
    }

    @Test func parsesRuntimeIdentifiers() throws {
        let ios = try #require(SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2"))
        #expect(ios.platform == .iOS && ios.version == [27, 2] && ios.variant == nil && ios.displayName == "iOS 27.2")
        let variant = try #require(SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4"))
        #expect(variant.version == [27, 2] && variant.displayName == "iOS 27.2 (iPhone19-4)")
        let vision = try #require(SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.xrOS-2-0"))
        #expect(vision.platform == .visionOS && vision.displayName == "visionOS 2.0")
        #expect(SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.tvOS-27-0") == nil)
        #expect(SimulatorRuntime(identifier: "garbage") == nil)
        #expect(ios.matches(os: "27.2") && ios.matches(os: "27") && ios.matches(os: "27.2.0") && !ios.matches(os: "27.1"))
    }

    @Test func rejectsMalformedOutput() {
        #expect(throws: (any Error).self) { try SimulatorList.parse(Data("{}".utf8)) }
    }

    // MARK: UDID inference

    @Test func findsKnownUDIDsInArgumentsAndEnvironment() throws {
        let devices = try Self.devices()
        let udid = "9C908654-7CBA-48C3-B0E9-4A03E6FEAE7E"
        func infer(_ argv: [String], env: [String] = []) -> Set<String> {
            SimulatorUsageInference.udids(in: ProcessArguments(argv: argv, env: env), devices: devices)
        }
        #expect(infer(["/usr/bin/xcodebuild", "-scheme", "App", "-destination", "platform=iOS Simulator,id=\(udid)", "test"]) == [udid])
        #expect(infer(["xcrun", "simctl", "boot", udid]) == [udid])
        #expect(infer(["/opt/homebrew/bin/axe", "tap", "-x", "10", "-y", "20", "--udid", udid.lowercased()]) == [udid])
        #expect(infer(["xctest"], env: ["SIMULATOR_UDID=\(udid)"]) == [udid])
        #expect(infer(["tail", "-f", "/Users/demo/Library/Logs/CoreSimulator/\(udid)/system.log"]) == [udid])
        // Two devices in one command.
        #expect(infer(["xcrun", "simctl", "pair", "D0D0D0D0-0000-4000-8000-000000000002", udid])
            == ["D0D0D0D0-0000-4000-8000-000000000002", udid])
    }

    @Test func ignoresUUIDsThatAreNotDevices() throws {
        let devices = try Self.devices()
        // A ClaudeDeck session id in the environment, a random UUID and a longer hex run.
        let args = ProcessArguments(argv: ["claude", "--resume", "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"],
                                    env: ["CLAUDEDECK_SESSION_ID=C0000000-0000-0000-0000-000000000001",
                                          "X=19C908654-7CBA-48C3-B0E9-4A03E6FEAE7E0"])
        #expect(SimulatorUsageInference.udids(in: args, devices: devices).isEmpty)
        // An unavailable device's UDID is not in the list either.
        let unavailable = ProcessArguments(argv: ["xcrun", "simctl", "boot", "B9427CA0-3499-416C-8D01-60FEB2D87374"])
        #expect(SimulatorUsageInference.udids(in: unavailable, devices: devices).isEmpty)
    }

    @Test func resolvesDestinationsByNameOnlyWhenUnambiguous() throws {
        let devices = try Self.devices()
        func infer(_ destination: String) -> Set<String> {
            SimulatorUsageInference.udids(in: ProcessArguments(argv: ["xcodebuild", "-destination", destination, "build"]), devices: devices)
        }
        // One booted device has that name.
        #expect(infer("platform=iOS Simulator,name=iPhone 18 Pro") == ["B3AEEB8B-7471-4D32-9BB7-63057108161B"])
        // Two shut-down "iPhone 16"s: ambiguous without an OS, resolved with one.
        #expect(infer("platform=iOS Simulator,name=iPhone 16").isEmpty)
        #expect(infer("platform=iOS Simulator,name=iPhone 16,OS=18.6") == ["11111111-2222-3333-4444-555555555555"])
        #expect(infer("platform=iOS Simulator,name=iPhone 16,OS=latest").isEmpty)
        // Wrong platform, unknown name.
        #expect(infer("platform=watchOS Simulator,name=iPhone 18 Pro").isEmpty)
        #expect(infer("platform=iOS Simulator,name=iPhone 99").isEmpty)
        // `-destination=` form.
        let joined = ProcessArguments(argv: ["xcodebuild", "-destination=platform=iOS Simulator,name=iPhone 19"])
        #expect(SimulatorUsageInference.udids(in: joined, devices: devices) == ["C0C0C0C0-0000-4000-8000-000000000001"])
    }

    @Test func resolvesBootedOnlyWithASingleBootedDevice() throws {
        let devices = try Self.devices()
        let args = ProcessArguments(argv: ["/Applications/Xcode.app/Contents/Developer/usr/bin/simctl", "io", "booted", "screenshot", "/tmp/a.png"])
        // Two devices are booted: "booted" is ambiguous.
        #expect(SimulatorUsageInference.udids(in: args, devices: devices).isEmpty)
        let one = devices.filter { !$0.isBooted || $0.name == "iPhone 18 Pro" }
        #expect(SimulatorUsageInference.udids(in: args, devices: one) == ["B3AEEB8B-7471-4D32-9BB7-63057108161B"])
        // "booted" in a non-simctl command means nothing.
        let other = ProcessArguments(argv: ["echo", "booted"])
        #expect(SimulatorUsageInference.udids(in: other, devices: one).isEmpty)
    }

    @Test func linksSimulatorsToSessionProcessTrees() throws {
        let devices = try Self.devices()
        let a = UUID(), b = UUID()
        let table = ProcessTable([
            .init(pid: 100, ppid: 1, name: "zsh"),         // session a's terminal
            .init(pid: 101, ppid: 100, name: "claude"),
            .init(pid: 102, ppid: 101, name: "xcodebuild"),
            .init(pid: 103, ppid: 102, name: "simctl"),     // grandchild
            .init(pid: 200, ppid: 1, name: "zsh"),         // session b's terminal
            .init(pid: 201, ppid: 200, name: "node"),
            .init(pid: 300, ppid: 1, name: "xcodebuild"),  // outside every session
        ])
        let args: [pid_t: ProcessArguments] = [
            101: ProcessArguments(argv: ["claude"], env: ["CLAUDEDECK_SESSION_ID=\(a.uuidString)"]),
            102: ProcessArguments(argv: ["xcodebuild", "-destination", "id=9C908654-7CBA-48C3-B0E9-4A03E6FEAE7E"]),
            103: ProcessArguments(argv: ["simctl", "launch", "9C908654-7CBA-48C3-B0E9-4A03E6FEAE7E", "com.acme.app"]),
            201: ProcessArguments(argv: ["node", "axe-mcp"], env: ["SIMULATOR_UDID=B3AEEB8B-7471-4D32-9BB7-63057108161B"]),
            300: ProcessArguments(argv: ["xcodebuild", "-destination", "id=B3AEEB8B-7471-4D32-9BB7-63057108161B"]),
        ]
        let links = SimulatorUsage.link(roots: [a: 100, b: 200], table: table, devices: devices) { args[$0] }
        #expect(Set(links["9C908654-7CBA-48C3-B0E9-4A03E6FEAE7E"]?.map(\.session) ?? []) == [a])
        #expect(links["9C908654-7CBA-48C3-B0E9-4A03E6FEAE7E"]?.map(\.process).sorted() == ["simctl", "xcodebuild"])
        // Process 300 isn't in a session: only session b's node counts.
        #expect(links["B3AEEB8B-7471-4D32-9BB7-63057108161B"] == [SimulatorUsage.Use(session: b, pid: 201, process: "node")])
        #expect(links.count == 2)
    }

    // MARK: Processes and memory

    @Test func parsesProcArgs2Buffers() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/usr/bin/xcrun".utf8) + [0, 0, 0, 0]
        for arg in ["xcrun", "simctl", "list"] { bytes += Array(arg.utf8) + [0] }
        for env in ["HOME=/Users/demo", "SIMULATOR_UDID=X"] { bytes += Array(env.utf8) + [0] }
        bytes += [0, 0, 0]
        let parsed = ProcessArguments.parse(procargs2: bytes)
        #expect(parsed == ProcessArguments(argv: ["xcrun", "simctl", "list"], env: ["HOME=/Users/demo", "SIMULATOR_UDID=X"]))
        #expect(ProcessArguments.parse(procargs2: [1, 0]) == nil)
    }

    @Test func findsTheUDIDOfLaunchdSim() {
        let argv = ["launchd_sim", "/Users/demo/Library/Developer/CoreSimulator/Devices/9c908654-7cba-48c3-b0e9-4a03e6feae7e/data/var/run/launchd_bootstrap.plist"]
        #expect(SimulatorProcesses.udid(ofLaunchdSim: argv) == "9C908654-7CBA-48C3-B0E9-4A03E6FEAE7E")
        #expect(SimulatorProcesses.udid(ofLaunchdSim: ["launchd_sim", "/tmp/Devices/not-a-uuid/x"]) == nil)

        let table = ProcessTable([
            .init(pid: 543, ppid: 1, name: "launchd_sim"),
            .init(pid: 544, ppid: 543, name: "SpringBoard"),
            .init(pid: 600, ppid: 1, name: "launchd_sim"),  // arguments unreadable
        ])
        let sims = SimulatorProcesses.launchdSims(in: table) { $0 == 543 ? ProcessArguments(argv: argv) : nil }
        #expect(sims == ["9C908654-7CBA-48C3-B0E9-4A03E6FEAE7E": 543])
    }

    @Test func sumsFootprintsOverTheLaunchdSimTree() {
        let mb: UInt64 = 1 << 20
        let table = ProcessTable([
            .init(pid: 1, ppid: 0, name: "launchd"),
            .init(pid: 543, ppid: 1, name: "launchd_sim"),
            .init(pid: 544, ppid: 543, name: "SpringBoard"),
            .init(pid: 545, ppid: 543, name: "backboardd"),
            .init(pid: 546, ppid: 545, name: "child"),       // grandchild counts too
            .init(pid: 547, ppid: 543, name: "exited"),      // footprint unreadable
            .init(pid: 700, ppid: 1, name: "launchd_sim"),   // another simulator
            .init(pid: 701, ppid: 700, name: "SpringBoard"),
        ])
        let footprints: [pid_t: UInt64] = [543: 35 * mb, 544: 160 * mb, 545: 20 * mb, 546: 5 * mb, 700: 30 * mb, 701: 999 * mb]
        let memory = SimulatorMemory.measure(root: 543, in: table) { footprints[$0] }
        #expect(memory == SimulatorMemory(bytes: 220 * mb, processes: 4, unreadable: 1))
        let other = SimulatorMemory.measure(root: 700, in: table) { footprints[$0] }
        #expect(other.bytes == 1029 * mb && other.processes == 2)
        // A cycle in a stale snapshot can't loop forever.
        let cyclic = ProcessTable([.init(pid: 10, ppid: 11, name: "a"), .init(pid: 11, ppid: 10, name: "b")])
        #expect(SimulatorMemory.measure(root: 10, in: cyclic) { _ in 1 } == SimulatorMemory(bytes: 2, processes: 2))
    }

    @Test func countsEachProcessForOneSimulatorOnly() {
        let gb: UInt64 = 1 << 30
        // Three booted simulators; the third's launchd_sim sits inside the first's tree (as a
        // stale or reparented snapshot can show it). Each device gets only its own processes:
        // per-device values never add up across devices.
        let table = ProcessTable([
            .init(pid: 1, ppid: 0, name: "launchd"),
            .init(pid: 100, ppid: 1, name: "launchd_sim"),
            .init(pid: 101, ppid: 100, name: "SpringBoard"),
            .init(pid: 102, ppid: 101, name: "app"),
            .init(pid: 200, ppid: 1, name: "launchd_sim"),
            .init(pid: 201, ppid: 200, name: "SpringBoard"),
            .init(pid: 300, ppid: 102, name: "launchd_sim"),  // nested in device A's tree
            .init(pid: 301, ppid: 300, name: "SpringBoard"),
            .init(pid: 400, ppid: 101, name: "launchd_sim"),  // a simulator whose UDID wasn't read
            .init(pid: 401, ppid: 400, name: "SpringBoard"),
        ])
        let footprints: [pid_t: UInt64] = [100: 1 * gb, 101: 2 * gb, 102: 1 * gb, 200: 1 * gb, 201: 4 * gb,
                                           300: 1 * gb, 301: 8 * gb, 400: 1 * gb, 401: 16 * gb]
        let roots = ["A": pid_t(100), "B": pid_t(200), "C": pid_t(300)]
        let memory = SimulatorMemory.measureAll(roots: roots, in: table) { footprints[$0] }
        #expect(memory["A"] == SimulatorMemory(bytes: 4 * gb, processes: 3))
        #expect(memory["B"] == SimulatorMemory(bytes: 5 * gb, processes: 2))
        #expect(memory["C"] == SimulatorMemory(bytes: 9 * gb, processes: 2))
        // The sum is every simulator process counted once (the unknown one's tree in none).
        #expect(memory.values.map(\.bytes).reduce(0, +) == 18 * gb)
        // The same devices in any order give the same values.
        let again = SimulatorMemory.measureAll(roots: ["C": 300, "B": 200, "A": 100], in: table) { footprints[$0] }
        #expect(again == memory)
    }

    @Test func readsThisProcessLive() {
        // Smoke test of the Darwin calls against the test runner itself.
        let pid = getpid()
        #expect((SimulatorMemory.footprint(of: pid) ?? 0) > 0)
        #expect(ProcessArguments.of(pid)?.argv.isEmpty == false)
        let table = ProcessTable.current()
        #expect(table.entry(pid) != nil)
    }
}
