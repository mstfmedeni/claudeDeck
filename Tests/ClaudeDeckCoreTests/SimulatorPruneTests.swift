import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct SimulatorPruneTests {
    static let runtime = SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2")!
    static let pro = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
    static let duo = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let day: TimeInterval = 86_400

    static func udid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }

    static func device(_ n: Int, name: String? = nil, state: String = "Shutdown", type: String = pro,
                       daysAgo: Double? = nil) -> Simulator {
        Simulator(udid: udid(n), name: name ?? "ClaudeDeck · iPhone 17 Pro · \(n)", state: state,
                  deviceTypeIdentifier: type, runtime: runtime,
                  lastUsedAt: daysAgo.map { now.addingTimeInterval(-$0 * day) })
    }

    static func select(_ devices: [Simulator], book: SimulatorHoldBook = SimulatorHoldBook(),
                       days: Double? = 3, max: Int? = nil) -> [String] {
        SimulatorPrune.select(devices: devices, book: book, now: now, olderThan: days.map { $0 * day }, maxPerType: max)
            .map(\.device.udid)
    }

    @Test func deletesOnlyOldShutDownPoolDevicesOldestFirst() {
        let devices = [Self.device(1, daysAgo: 4), Self.device(2, daysAgo: 1), Self.device(3, daysAgo: 10)]
        #expect(Self.select(devices) == [Self.udid(3), Self.udid(1)])
    }

    @Test func ageBoundaryIsInclusive() {
        #expect(Self.select([Self.device(1, daysAgo: 3)]) == [Self.udid(1)])
        #expect(Self.select([Self.device(1, daysAgo: 2.99)]).isEmpty)
    }

    @Test func neverDeletesBootedOrHeld() {
        var book = SimulatorHoldBook()
        book.hold(SimulatorHold(udid: Self.udid(2), name: "ClaudeDeck · iPhone 17 Pro · 2", session: UUID(), created: true))
        let devices = [Self.device(1, state: "Booted", daysAgo: 30), Self.device(2, daysAgo: 30),
                       Self.device(3, state: "Shutting Down", daysAgo: 30)]
        #expect(Self.select(devices, book: book, max: 0).isEmpty)
    }

    @Test func neverDeletesNonPool() {
        let devices = [Self.device(1, name: "iPhone 17 Pro", daysAgo: 300),
                       Self.device(2, name: "Wakeroo · QA", daysAgo: 300),
                       Self.device(3, name: "Claudedeck iPhone", daysAgo: 300)]
        #expect(Self.select(devices, max: 0).isEmpty)
    }

    @Test func renamedAwayFromThePrefixIsNeverDeleted() {
        var book = SimulatorHoldBook()
        book.noteCreated(Self.udid(1))
        #expect(Self.select([Self.device(1, name: "Renamed by hand", daysAgo: 5)], book: book, max: 0).isEmpty)
        // A held device's project name keeps the prefix.
        #expect(Self.select([Self.device(2, name: "ClaudeDeck · Wakeroo · iPhone 17 Pro · 2", daysAgo: 5)]) == [Self.udid(2)])
    }

    @Test func zeroDaysTurnsTheAgeRuleOff() {
        #expect(Self.select([Self.device(1, daysAgo: 100)], days: nil).isEmpty)
    }

    @Test func releaseTimeWinsOverAnOlderBoot() {
        var book = SimulatorHoldBook()
        book.noteUsed(Self.udid(1), at: Self.now.addingTimeInterval(-Self.day))
        #expect(Self.select([Self.device(1, daysAgo: 20)], book: book).isEmpty)
    }

    @Test func undatedDevicesAreNeverCandidates() {
        let devices = [Self.device(1), Self.device(2), Self.device(3)]
        #expect(Self.select(devices, days: 0.0001, max: 0).isEmpty)
        #expect(SimulatorPrune.undated(devices: devices + [Self.device(4, name: "Mine")], book: SimulatorHoldBook())
                == [Self.udid(1), Self.udid(2), Self.udid(3)])
    }

    @Test func perTypeBoundDeletesOldestFreeOnesAndCountsBootedAndHeld() {
        var book = SimulatorHoldBook()
        book.hold(SimulatorHold(udid: Self.udid(2), name: "x", session: UUID(), created: true))
        // 6 iPhone 17 Pro (1 booted, 1 held, 4 free, all recent) and 2 Duos; at most 4 per type.
        let devices = [Self.device(1, state: "Booted", daysAgo: 0.1), Self.device(2, daysAgo: 0.1),
                       Self.device(3, daysAgo: 0.5), Self.device(4, daysAgo: 1.5), Self.device(5, daysAgo: 0.2),
                       Self.device(6, daysAgo: 1),
                       Self.device(7, name: "ClaudeDeck · iPhone Duo · 1", type: Self.duo, daysAgo: 2),
                       Self.device(8, name: "ClaudeDeck · iPhone Duo · 2", type: Self.duo, daysAgo: 2)]
        let chosen = SimulatorPrune.select(devices: devices, book: book, now: Self.now, olderThan: 3 * Self.day, maxPerType: 4)
        #expect(chosen.map(\.device.udid) == [Self.udid(4), Self.udid(6)])
        #expect(chosen.allSatisfy { $0.reason == .overCap })
    }

    @Test func boundAndAgeTogether() {
        let devices = (1...4).map { Self.device($0, daysAgo: Double($0)) }
        let chosen = SimulatorPrune.select(devices: devices, book: SimulatorHoldBook(), now: Self.now,
                                           olderThan: 3 * Self.day, maxPerType: 3)
        #expect(chosen.map(\.device.udid) == [Self.udid(4), Self.udid(3)])
        #expect(chosen.map(\.reason) == [.overCap, .unused])
    }

    @Test func parsesAges() {
        #expect(SimulatorPrune.parseAge("3d") == 3 * Self.day)
        #expect(SimulatorPrune.parseAge("12h") == TimeInterval(12 * 3600))
        #expect(SimulatorPrune.parseAge("90m") == TimeInterval(90 * 60))
        #expect(SimulatorPrune.parseAge("2") == 2 * Self.day)
        #expect(SimulatorPrune.parseAge("0d") == nil)
        #expect(SimulatorPrune.parseAge("-1d") == nil)
        #expect(SimulatorPrune.parseAge("soon") == nil)
    }

    @Test func sessionProjectFromName() {
        #expect(SimulatorPrune.sessionProject("Wakeroo · QA", projects: ["wakeroo", "Other"]) == "wakeroo")
        #expect(SimulatorPrune.sessionProject("ClaudeDeck · Wakeroo · iPhone 17 Pro · 1", projects: ["Wakeroo"]) == nil)
        #expect(SimulatorPrune.sessionProject("iPhone 17 Pro", projects: ["iPhone 17 Pro"]) == nil)
        #expect(SimulatorPrune.sessionProject("Unknown · QA", projects: ["Wakeroo"]) == nil)
    }

    @Test func holdBookWithoutLastUsedStillDecodes() throws {
        let json = #"{"created":["AAAA"],"holds":[{"udid":"BBBB","name":"n","session":"\#(UUID().uuidString)","at":0,"created":true}]}"#
        let book = try JSONDecoder().decode(SimulatorHoldBook.self, from: Data(json.utf8))
        #expect(book.created == ["AAAA"])
        #expect(book.holds.count == 1)
        #expect(book.lastUsed.isEmpty)
    }

    @Test func releaseRecordsLastUseAndForgetDrops() {
        var book = SimulatorHoldBook()
        let session = UUID()
        book.hold(SimulatorHold(udid: Self.udid(1), name: "n", session: session, created: true))
        book.release(session: session)
        #expect(book.lastUsed[Self.udid(1)] != nil)
        // A hold dropped because its session is gone counts as a release too.
        book.hold(SimulatorHold(udid: Self.udid(2), name: "n", session: UUID(), created: true))
        book.prune(sessions: [], devices: nil)
        #expect(book.lastUsed[Self.udid(2)] != nil)
        book.forget(Self.udid(1))
        #expect(book.lastUsed[Self.udid(1)] == nil)
        #expect(!book.created.contains(Self.udid(1)))
    }

    @Test func unavailableCountAndSimctlDates() throws {
        let data = try Data(contentsOf: SimulatorTests.fixtureURL)
        #expect(try SimulatorList.unavailableCount(data) >= 1)
    }

    /// Read-only check against this Mac's simulators: CLAUDEDECK_REAL_SIMCTL=1 swift test --filter realList.
    /// Prints the plan with an empty book; never deletes anything.
    @Test func realList() throws {
        guard ProcessInfo.processInfo.environment["CLAUDEDECK_REAL_SIMCTL"] == "1" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "-j", "devices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let devices = try SimulatorList.parse(data)
        let chosen = SimulatorPrune.select(devices: devices, book: SimulatorHoldBook(), now: Date(), olderThan: 3 * Self.day, maxPerType: 6)
        print("real: \(devices.count) usable, \(try SimulatorList.unavailableCount(data)) unavailable, pool \(devices.filter { SimulatorPrune.isPool($0, book: SimulatorHoldBook()) }.count)")
        for c in chosen { print("would delete \(c.device.udid) \(c.reason.rawValue) \(c.lastUsed.map { "\($0)" } ?? "-") \(c.device.name)") }
    }
}
