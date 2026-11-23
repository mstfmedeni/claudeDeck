import ClaudeDeckCore
import Foundation
import Testing

@Suite struct SimulatorIdleShutdownTests {
    private let pool = SimulatorAllocation.namePrefix + "iPhone Duo · 1"

    @Test func unheldPoolDeviceShutsDownAfterTheWait() {
        var since: [String: Date] = [:]
        let t0 = Date(timeIntervalSince1970: 0)
        let free = [SimulatorIdleShutdown.Device(udid: "A", name: pool, held: false, inUse: false)]
        #expect(SimulatorIdleShutdown.due(booted: free, unheldSince: &since, now: t0, minutes: 10).isEmpty)
        #expect(SimulatorIdleShutdown.due(booted: free, unheldSince: &since, now: t0 + 9 * 60, minutes: 10).isEmpty)
        #expect(SimulatorIdleShutdown.due(booted: free, unheldSince: &since, now: t0 + 10 * 60, minutes: 10) == ["A"])
    }

    @Test func heldInUseOwnersAndOffAreLeftAlone() {
        var since: [String: Date] = [:]
        let t0 = Date(timeIntervalSince1970: 0)
        let devices = [
            SimulatorIdleShutdown.Device(udid: "H", name: pool, held: true, inUse: false),
            SimulatorIdleShutdown.Device(udid: "U", name: pool, held: false, inUse: true),
            SimulatorIdleShutdown.Device(udid: "O", name: "iPhone 17 Pro", held: false, inUse: false),
        ]
        _ = SimulatorIdleShutdown.due(booted: devices, unheldSince: &since, now: t0, minutes: 10)
        #expect(SimulatorIdleShutdown.due(booted: devices, unheldSince: &since, now: t0 + 3600, minutes: 10).isEmpty)
        let free = [SimulatorIdleShutdown.Device(udid: "A", name: pool, held: false, inUse: false)]
        _ = SimulatorIdleShutdown.due(booted: free, unheldSince: &since, now: t0, minutes: 0)
        #expect(SimulatorIdleShutdown.due(booted: free, unheldSince: &since, now: t0 + 3600, minutes: 0).isEmpty)
    }

    @Test func takingItAgainRestartsTheClock() {
        var since: [String: Date] = [:]
        let t0 = Date(timeIntervalSince1970: 0)
        let free = [SimulatorIdleShutdown.Device(udid: "A", name: pool, held: false, inUse: false)]
        let held = [SimulatorIdleShutdown.Device(udid: "A", name: pool, held: true, inUse: false)]
        _ = SimulatorIdleShutdown.due(booted: free, unheldSince: &since, now: t0, minutes: 10)
        _ = SimulatorIdleShutdown.due(booted: held, unheldSince: &since, now: t0 + 8 * 60, minutes: 10)
        #expect(SimulatorIdleShutdown.due(booted: free, unheldSince: &since, now: t0 + 12 * 60, minutes: 10).isEmpty)
    }
}
