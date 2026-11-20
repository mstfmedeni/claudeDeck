import Foundation
import Testing
@testable import ClaudeDeckCore

/// The load monitor (level with hysteresis, the overload episode), build slots, throttling, the
/// `load` / `slot` / `heavy` routes and script, and the phone's load field.
@Suite struct SystemLoadTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var thresholds: LoadThresholds { LoadThresholds.resolve(LoadSettings(), cores: 20) }

    private func sample(_ seconds: Double, load: Double, pressure: MemoryPressure = .normal, compilers: Int = 0,
                        simulators: Int = 0, sessions: Int = 0, swapGB: Double = 0, processes: Int = 0) -> LoadSample {
        LoadSample(at: t0.addingTimeInterval(seconds), load1: load, cores: 20, pressure: pressure,
                   swapUsedBytes: UInt64(swapGB * 1_073_741_824), simulators: simulators, compilers: compilers,
                   processes: processes, sessions: sessions)
    }

    private func thresholds(_ change: (inout LoadSettings) -> Void) -> LoadThresholds {
        var settings = LoadSettings()
        change(&settings)
        return LoadThresholds.resolve(settings, cores: 20)
    }

    // MARK: Thresholds

    @Test func defaultsScaleWithTheCoresAndOnlyCatchFreezes() {
        let t = thresholds
        // Overloaded: a freeze-level load (10 × cores for 3 min), 3,000 processes, critical pressure,
        // swap +2 GB in 5 min under pressure, more than 60 % of the cores in compilers.
        #expect(t.overloadLoad == 200 && t.overloadSustain == 180 && t.maxProcesses == 3000)
        #expect(t.pressureLevel == .critical && t.swapGrowthBytes == 2 << 30 && t.swapGrowthWindow == 300)
        #expect(t.enabled == [.pressure, .swapGrowth, .compilers, .load, .processes])
        // Busy: 2 × cores for a minute, or half the compiler limit.
        #expect(t.busyLoad == 40 && t.busySustain == 60 && t.busyAction == .nothing)
        #expect(t.overloadCompilers == 12 && t.busyCompilers == 6)
        #expect(t.maxSimulators == 4 && t.buildSlots == 3 && t.overloadedBuildSlots == 1)
        #expect(t.maxSlotHold == 3600)
        let small = LoadThresholds.resolve(LoadSettings(), cores: 8)
        #expect(small.overloadLoad == 80 && small.overloadCompilers == 5 && small.maxSimulators == 2 && small.buildSlots == 1)
        let big = LoadThresholds.resolve(LoadSettings(), cores: 64)
        #expect(big.maxSimulators == 10 && big.buildSlots == 8)
        let c = thresholds {
            $0.maxSimulators = 7
            $0.buildSlots = 5
            $0.overloadedBuildSlots = 9 // never above the full count
            $0.maxCompilers = 30
            $0.busyFactor = 30 // never above the overload factor
            $0.overloadMinutes = 1.5
        }
        #expect(c.maxSimulators == 7 && c.buildSlots == 5 && c.overloadedBuildSlots == 5 && c.overloadCompilers == 30)
        #expect(c.busyLoad == 200 && c.overloadSustain == 90)
    }

    @Test func settingsDecodeOldFilesAndClamp() throws {
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data("{}".utf8))
        #expect(old.load == LoadSettings())
        #expect(old.load.throttle && old.load.notify && old.load.maxSimulators == nil)
        let json = #"{"load":{"throttle":false,"overloadFactor":99,"buildSlots":0,"maxSimulators":3,"maxSlotHoldMinutes":1,"maxProcesses":5}}"#
        let decoded = try JSONDecoder().decode(DeckSettings.self, from: Data(json.utf8))
        #expect(!decoded.load.throttle)
        #expect(decoded.load.overloadFactor == 30 && decoded.load.buildSlots == 1 && decoded.load.maxSimulators == 3)
        #expect(decoded.load.maxSlotHoldMinutes == 5 && decoded.load.maxProcesses == 200)
        let back = try JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(decoded))
        #expect(back.load == decoded.load)
        // A broken value doesn't lose the rest of the settings.
        let broken = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"load":7,"notifications":false}"#.utf8))
        #expect(broken.load == LoadSettings() && !broken.notifications)
        // "normal" is no overload level: read as warning.
        let normal = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"version":2,"pressureLevel":"normal"}"#.utf8))
        #expect(normal.pressureLevel == .warning)
    }

    @Test func unchangedFirstDefaultsMigrate() throws {
        // A file the first version wrote with its defaults (it always wrote every value).
        let v1 = #"{"throttle":true,"notify":true,"overloadFactor":2,"busyFactor":1,"maxSlotHoldMinutes":60,"alwaysShowInSidebar":false}"#
        let migrated = try JSONDecoder().decode(LoadSettings.self, from: Data(v1.utf8))
        #expect(migrated.overloadFactor == 10 && migrated.busyFactor == 2 && migrated.version == LoadSettings.currentVersion)
        #expect(migrated == LoadSettings())
        // Values the owner changed stay.
        let changed = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"overloadFactor":3,"busyFactor":1.5,"maxCompilers":20}"#.utf8))
        #expect(changed.overloadFactor == 3 && changed.busyFactor == 1.5 && changed.maxCompilers == 20)
        // Once migrated (version 2), 2 and 1 are the owner's own choice and stay.
        var mine = LoadSettings()
        mine.overloadFactor = 2
        mine.busyFactor = 1
        let again = try JSONDecoder().decode(LoadSettings.self, from: JSONEncoder().encode(mine))
        #expect(again.overloadFactor == 2 && again.busyFactor == 1)
    }

    @Test func triggerSwitchesAndRestoringDefaults() {
        var settings = LoadSettings()
        for trigger in LoadTrigger.allCases {
            let was = settings.isEnabled(trigger)
            settings.setEnabled(trigger, !was)
            #expect(settings.isEnabled(trigger) == !was)
        }
        #expect(LoadThresholds.resolve(settings, cores: 20).enabled == [.swapSize])
        settings.throttle = false
        settings.notify = false
        settings.alwaysShowInSidebar = true
        settings.overloadFactor = 4
        settings.maxProcesses = 900
        settings.busyAction = .holdStarts
        settings.buildSlots = 6
        settings.overloadedBuildSlots = 2
        settings.maxSimulators = 9
        settings.pressureLevel = .warning
        let reset = settings.restoringDefaults()
        var expected = LoadSettings()
        expected.throttle = false
        expected.notify = false
        expected.alwaysShowInSidebar = true
        #expect(reset == expected)
    }

    // MARK: Level and episode

    @Test func theOwnersBusyMacIsFine() {
        // The incident: load 27.9 on 20 cores, memory pressure normal, 18 GB swap, 4 simulators
        // (the cap), no compilers, 2,043 processes. Nothing to see: ok, nothing held back.
        var monitor = LoadMonitor()
        for i in 0..<30 {
            monitor.add(sample(Double(i) * 12, load: 27.9, simulators: 4, swapGB: 18, processes: 2043), thresholds: thresholds)
        }
        #expect(monitor.level == .ok && monitor.fired.isEmpty && monitor.episode == 0)
        // Even 1.95 per core for long, and 2.5 per core: busy at most, never overloaded.
        var high = LoadMonitor()
        for i in 0..<60 { high.add(sample(Double(i) * 12, load: 50, simulators: 4, swapGB: 18, processes: 2043), thresholds: thresholds) }
        #expect(high.level == .busy && !high.overloaded)
        #expect(!LoadThrottle.holdsStarts(level: high.level, busyAction: .nothing, enabled: true))
        #expect(LoadThrottle.slotCapacity(thresholds, level: high.level, enabled: true) == 3)
        #expect(LoadThrottle.simulator(level: high.level, enabled: true, booted: 3, wanted: 1, max: 4) == .allow)
        // 3 × cores for minutes is still only busy.
        var triple = LoadMonitor()
        for i in 0..<60 { triple.add(sample(Double(i) * 12, load: 60), thresholds: thresholds) }
        #expect(triple.level == .busy)
    }

    @Test func simulatorLimitIsNotBusy() {
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 5, simulators: 4), thresholds: thresholds)
        monitor.add(sample(60, load: 5, simulators: 11), thresholds: thresholds)
        #expect(monitor.level == .ok)
        // It only refuses sim acquire.
        #expect(LoadThrottle.simulator(level: .ok, enabled: true, booted: 4, wanted: 1, max: 4) == .tooManyBooted)
    }

    @Test func busyLoadMustLastAMinute() {
        var monitor = LoadMonitor()
        #expect(monitor.add(sample(0, load: 50), thresholds: thresholds).isEmpty)
        #expect(monitor.add(sample(60, load: 50), thresholds: thresholds) == [.level(from: .ok, to: .busy)])
        var dip = LoadMonitor()
        dip.add(sample(0, load: 50), thresholds: thresholds)
        dip.add(sample(30, load: 30), thresholds: thresholds)
        dip.add(sample(70, load: 50), thresholds: thresholds)
        #expect(dip.level == .ok)
        // Memory pressure warning and half the compiler limit are busy at once.
        var warn = LoadMonitor()
        warn.add(sample(0, load: 5, pressure: .warning), thresholds: thresholds)
        #expect(warn.level == .busy)
        var builds = LoadMonitor()
        builds.add(sample(0, load: 5, compilers: 7), thresholds: thresholds)
        #expect(builds.level == .busy)
    }

    @Test func extremeLoadMustLastThreeMinutes() {
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 250), thresholds: thresholds)
        monitor.add(sample(60, load: 250), thresholds: thresholds)
        #expect(monitor.level == .busy)
        monitor.add(sample(120, load: 250), thresholds: thresholds)
        #expect(monitor.level == .busy && monitor.triggers.first { $0.trigger == .load }?.aboveFor == 120)
        let events = monitor.add(sample(180, load: 250), thresholds: thresholds)
        #expect(events == [.level(from: .busy, to: .overloaded), .episodeStarted(1)])
        #expect(monitor.fired == [.load] && monitor.overloaded)
        // A dip resets the three minutes.
        var dip = LoadMonitor()
        dip.add(sample(0, load: 250), thresholds: thresholds)
        dip.add(sample(100, load: 150), thresholds: thresholds)
        dip.add(sample(200, load: 250), thresholds: thresholds)
        #expect(dip.level != .overloaded)
        // Switched off: never.
        let off = thresholds { $0.loadEnabled = false }
        var none = LoadMonitor()
        for i in 0..<30 { none.add(sample(Double(i) * 12, load: 400), thresholds: off) }
        #expect(none.level == .busy)
    }

    @Test func freezeRisksAreImmediate() {
        var critical = LoadMonitor()
        #expect(critical.add(sample(0, load: 5, pressure: .critical), thresholds: thresholds).contains(.episodeStarted(1)))
        #expect(critical.fired == [.pressure])
        var builds = LoadMonitor()
        builds.add(sample(0, load: 5, compilers: 13), thresholds: thresholds)
        #expect(builds.level == .overloaded && builds.fired == [.compilers])
        var twelve = LoadMonitor()
        twelve.add(sample(0, load: 5, compilers: 12), thresholds: thresholds)
        #expect(twelve.level == .busy)
        var processes = LoadMonitor()
        processes.add(sample(0, load: 5, processes: 3001), thresholds: thresholds)
        #expect(processes.level == .overloaded && processes.fired == [.processes])
        var three = LoadMonitor()
        three.add(sample(0, load: 5, processes: 3000), thresholds: thresholds)
        #expect(three.level == .ok)
        // Pressure set to warning: warning is enough.
        var warn = LoadMonitor()
        warn.add(sample(0, load: 5, pressure: .warning), thresholds: thresholds { $0.pressureLevel = .warning })
        #expect(warn.level == .overloaded)
    }

    @Test func eachTriggerHasItsOwnSwitch() {
        let s = sample(0, load: 5, pressure: .critical, compilers: 30, swapGB: 100, processes: 5000)
        var all = LoadMonitor()
        all.add(s, thresholds: thresholds { $0.swapSizeEnabled = true })
        #expect(Set(all.fired) == [.pressure, .compilers, .processes, .swapSize])
        let off = thresholds {
            for trigger in LoadTrigger.allCases { $0.setEnabled(trigger, false) }
        }
        var none = LoadMonitor()
        none.add(s, thresholds: off)
        #expect(none.fired.isEmpty && none.level == .busy)
        #expect(none.triggers.count == LoadTrigger.allCases.count && none.triggers.allSatisfy { !$0.enabled })
        // The live values are there whether a trigger is on or off.
        #expect(none.triggers.first { $0.trigger == .processes }?.current == 5000)
        #expect(none.triggers.first { $0.trigger == .compilers }?.threshold == 12)
    }

    @Test func swapGrowingFastUnderPressure() {
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 5, pressure: .warning, swapGB: 10), thresholds: thresholds)
        monitor.add(sample(120, load: 5, pressure: .warning, swapGB: 11), thresholds: thresholds)
        #expect(monitor.level == .busy)
        monitor.add(sample(240, load: 5, pressure: .warning, swapGB: 12.5), thresholds: thresholds)
        #expect(monitor.level == .overloaded && monitor.fired == [.swapGrowth])
        // The same growth with normal pressure: nothing.
        var calm = LoadMonitor()
        calm.add(sample(0, load: 5, swapGB: 10), thresholds: thresholds)
        calm.add(sample(240, load: 5, swapGB: 12.5), thresholds: thresholds)
        #expect(calm.level == .ok)
        // Slower than 2 GB in 5 minutes: nothing.
        var slow = LoadMonitor()
        slow.add(sample(0, load: 5, pressure: .warning, swapGB: 10), thresholds: thresholds)
        slow.add(sample(200, load: 5, pressure: .warning, swapGB: 11.2), thresholds: thresholds)
        slow.add(sample(400, load: 5, pressure: .warning, swapGB: 12.4), thresholds: thresholds)
        #expect(slow.level == .busy)
        // A big swap on its own is no trigger unless switched on.
        var big = LoadMonitor()
        big.add(sample(0, load: 5, swapGB: 100), thresholds: thresholds)
        #expect(big.level == .ok)
    }

    @Test func hysteresisAndOneEpisodeUntilOK() {
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 5, compilers: 30), thresholds: thresholds)
        #expect(monitor.level == .overloaded && monitor.episode == 1)
        // Under the threshold but not by the exit margin (80 % of 200): stays overloaded.
        monitor.add(sample(10, load: 170), thresholds: thresholds)
        monitor.add(sample(100, load: 170), thresholds: thresholds)
        #expect(monitor.level == .overloaded)
        // Calm for a minute: down to busy (the load still above 40).
        monitor.add(sample(110, load: 100), thresholds: thresholds)
        monitor.add(sample(150, load: 100), thresholds: thresholds)
        #expect(monitor.level == .overloaded)
        #expect(monitor.add(sample(170, load: 100), thresholds: thresholds) == [.level(from: .overloaded, to: .busy)])
        // Throttling ends as soon as it's no longer overloaded; the episode goes on until ok, so
        // overloaded again is no new episode (no second notification or message).
        #expect(!monitor.overloaded && monitor.inEpisode)
        #expect(!LoadThrottle.holdsStarts(level: monitor.level, busyAction: .nothing, enabled: true))
        #expect(monitor.add(sample(180, load: 5, compilers: 20), thresholds: thresholds) == [.level(from: .busy, to: .overloaded)])
        #expect(monitor.episode == 1)
        // Calm all the way: overloaded → ok directly once busy is clear too; the episode ends.
        monitor.add(sample(190, load: 5), thresholds: thresholds)
        let events = monitor.add(sample(250, load: 5), thresholds: thresholds)
        #expect(events == [.level(from: .overloaded, to: .ok), .episodeEnded(1)])
        #expect(!monitor.inEpisode)
        // The next overload is a new episode.
        #expect(monitor.add(sample(260, load: 5, pressure: .critical), thresholds: thresholds).contains(.episodeStarted(2)))
    }

    @Test func overloadedEndsOnItsOwnMarginNotAtOK() {
        // The owner's settings (0.6.12): busy at 2 × cores (40), overloaded at 5 × cores (100).
        // Load 51.3 with normal pressure and 2 compilers is above busy but far below 80 % of 100:
        // overloaded must end after its calm minute, and throttling with it, though still busy.
        let t = thresholds {
            $0.busyFactor = 2
            $0.overloadFactor = 5
        }
        var monitor = LoadMonitor()
        for i in 0...15 { monitor.add(sample(Double(i) * 12, load: 120, compilers: 2), thresholds: t) }
        #expect(monitor.level == .overloaded && monitor.fired == [.load])
        monitor.add(sample(200, load: 51.3, compilers: 2), thresholds: t)
        #expect(monitor.level == .overloaded) // calm for less than a minute
        let events = monitor.add(sample(260, load: 51.3, compilers: 2), thresholds: t)
        #expect(events == [.level(from: .overloaded, to: .busy)])
        #expect(!monitor.overloaded && monitor.fired.isEmpty)
        #expect(!LoadThrottle.holdsStarts(level: monitor.level, busyAction: .nothing, enabled: true))
        #expect(LoadThrottle.drains(level: monitor.level, busyAction: .nothing, enabled: true))
        #expect(LoadThrottle.slotCapacity(t, level: monitor.level, enabled: true) == 3)
        let report = SessionCLILoad(level: monitor.level, settings: LoadSettings(), sample: monitor.latest, thresholds: t,
                                    triggers: monitor.triggers, capacity: 3, slots: [], waiting: 0)
        #expect(report.level == "busy" && !report.throttled)
    }

    @Test func busyNeedsThirtyCalmSecondsToClear() {
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 50), thresholds: thresholds)
        monitor.add(sample(60, load: 50), thresholds: thresholds)
        #expect(monitor.level == .busy)
        monitor.add(sample(70, load: 35), thresholds: thresholds) // under 40 but not under 32
        monitor.add(sample(120, load: 35), thresholds: thresholds)
        #expect(monitor.level == .busy)
        monitor.add(sample(130, load: 10), thresholds: thresholds)
        monitor.add(sample(150, load: 10), thresholds: thresholds)
        #expect(monitor.level == .busy)
        #expect(monitor.add(sample(160, load: 10), thresholds: thresholds) == [.level(from: .busy, to: .ok)])
    }

    @Test func keepsTheLastHourForTheCharts() {
        var monitor = LoadMonitor()
        for i in 0..<(LoadMonitor.keep + 20) { monitor.add(sample(Double(i) * 12, load: 1), thresholds: thresholds) }
        #expect(monitor.samples.count == LoadMonitor.keep && LoadMonitor.keep * 12 >= 3600)
        #expect(monitor.latest?.at == t0.addingTimeInterval(Double(LoadMonitor.keep + 19) * 12))
    }

    @Test func contributorsNameWhatStandsOut() {
        let s = sample(0, load: 120, pressure: .warning, compilers: 30, simulators: 11, sessions: 37, swapGB: 4, processes: 2900)
        #expect(LoadContributor.of(s, thresholds: thresholds) ==
                [.simulators(11), .compilers(30), .sessions(37), .memory(.warning), .swap(4 << 30), .processes(2900), .load(120, cores: 20)])
        #expect(LoadContributor.of(sample(0, load: 3, simulators: 1), thresholds: thresholds) == [.load(3, cores: 20)])
        #expect(LoadContributor.simulators(11).text == "11 simulators booted")
    }

    @Test func processNamesAreCounted() {
        let names = ["launchd_sim", "launchd_sim", "swift-frontend", "clang", "ld", "xcodebuild", "zsh", "claude", "SimMetalHost"]
        let counted = LoadProcesses.count(names)
        #expect(counted.simulators == 2 && counted.compilers == 4)
        #expect(MemoryPressure(kernelLevel: 1) == .normal && MemoryPressure(kernelLevel: 2) == .warning && MemoryPressure(kernelLevel: 4) == .critical)
        #expect(MemoryPressure.normal < .warning && MemoryPressure.warning < .critical)
    }

    // MARK: Throttling

    @Test func busyDoesNotThrottle() {
        // Busy holds nothing back by default: new starts go, the queue drains, every build slot.
        #expect(LoadThrottle.start(level: .busy, busyAction: .nothing, enabled: true, queue: false) == .allow)
        #expect(LoadThrottle.drains(level: .busy, busyAction: .nothing, enabled: true))
        #expect(LoadThrottle.slotCapacity(thresholds, level: .busy, enabled: true) == 3)
        #expect(LoadThrottle.simulator(level: .busy, enabled: true, booted: 0, wanted: 1, max: 4) == .allow)
        // Unless the owner picked "hold new starts" for busy: then only starts wait.
        #expect(LoadThrottle.start(level: .busy, busyAction: .holdStarts, enabled: true, queue: true) == .queue)
        #expect(!LoadThrottle.drains(level: .busy, busyAction: .holdStarts, enabled: true))
        #expect(LoadThrottle.slotCapacity(thresholds { $0.busyAction = .holdStarts }, level: .busy, enabled: true) == 3)
        #expect(LoadThrottle.simulator(level: .busy, enabled: true, booted: 0, wanted: 1, max: 4) == .allow)
    }

    @Test func throttlingWhileOverloaded() {
        #expect(LoadThrottle.start(level: .ok, busyAction: .nothing, enabled: true, queue: false) == .allow)
        #expect(LoadThrottle.start(level: .overloaded, busyAction: .nothing, enabled: true, queue: false) == .refuse)
        #expect(LoadThrottle.start(level: .overloaded, busyAction: .nothing, enabled: true, queue: true) == .queue)
        #expect(LoadThrottle.start(level: .overloaded, busyAction: .holdStarts, enabled: false, queue: false) == .allow)
        #expect(!LoadThrottle.drains(level: .overloaded, busyAction: .nothing, enabled: true))
        #expect(LoadThrottle.drains(level: .overloaded, busyAction: .nothing, enabled: false))
        #expect(LoadThrottle.simulator(level: .overloaded, enabled: true, booted: 0, wanted: 1, max: 4) == .overloaded)
        #expect(LoadThrottle.simulator(level: .ok, enabled: true, booted: 3, wanted: 1, max: 4) == .allow)
        #expect(LoadThrottle.simulator(level: .ok, enabled: true, booted: 3, wanted: 2, max: 4) == .tooManyBooted)
        #expect(LoadThrottle.simulator(level: .overloaded, enabled: false, booted: 1, wanted: 1, max: 4) == .allow)
        #expect(LoadThrottle.slotCapacity(thresholds, level: .overloaded, enabled: true) == 1)
        #expect(LoadThrottle.slotCapacity(thresholds { $0.overloadedBuildSlots = 2 }, level: .overloaded, enabled: true) == 2)
        #expect(LoadThrottle.slotCapacity(thresholds, level: .overloaded, enabled: false) == 3)
    }

    // MARK: Build slots

    @Test func slotsAcquireAndRelease() {
        var book = BuildSlotBook()
        let a = UUID(), b = UUID()
        guard case .acquired(let first) = book.acquire(session: a, ticket: nil, label: "xcodebuild", capacity: 2, now: t0) else {
            Issue.record("no slot"); return
        }
        #expect(first.id.hasPrefix("b_") && first.id.count == 10 && first.label == "xcodebuild")
        guard case .acquired = book.acquire(session: b, ticket: nil, label: nil, capacity: 2, now: t0) else { Issue.record("no slot"); return }
        #expect(book.acquire(session: b, ticket: nil, label: nil, capacity: 2, now: t0) == .full(position: nil))
        #expect(book.release(session: b, id: first.id).isEmpty) // not b's
        #expect(book.release(session: a, id: first.id) == [first])
        #expect(book.held(by: a).isEmpty && book.held(by: b).count == 1)
        #expect(book.release(session: b).count == 1 && book.slots.isEmpty)
    }

    @Test func waitersAreServedInOrder() {
        var book = BuildSlotBook()
        let holder = UUID(), first = UUID(), second = UUID()
        _ = book.acquire(session: holder, ticket: nil, label: nil, capacity: 1, now: t0)
        #expect(book.acquire(session: first, ticket: "t1", label: nil, capacity: 1, now: t0) == .full(position: 1))
        #expect(book.acquire(session: second, ticket: "t2", label: nil, capacity: 1, now: t0.addingTimeInterval(1)) == .full(position: 2))
        book.release(session: holder)
        // The second asks first, but the first is ahead in line; nobody jumps it without a ticket either.
        #expect(book.acquire(session: second, ticket: "t2", label: nil, capacity: 1, now: t0.addingTimeInterval(2)) == .full(position: 2))
        #expect(book.acquire(session: holder, ticket: nil, label: nil, capacity: 1, now: t0.addingTimeInterval(2)) == .full(position: nil))
        guard case .acquired(let slot) = book.acquire(session: first, ticket: "t1", label: nil, capacity: 1, now: t0.addingTimeInterval(3)) else {
            Issue.record("first in line didn't get it"); return
        }
        #expect(slot.session == first && book.waiters.map(\.ticket) == ["t2"])
        // A waiter that stops asking gives up its place.
        book.release(session: first)
        #expect(book.acquire(session: holder, ticket: nil, label: nil, capacity: 1,
                             now: t0.addingTimeInterval(3 + BuildSlotBook.waiterTimeout + 1)) != .full(position: nil))
        #expect(book.waiters.isEmpty)
        // Leaving the line.
        var other = BuildSlotBook()
        _ = other.acquire(session: holder, ticket: nil, label: nil, capacity: 1, now: t0)
        _ = other.acquire(session: first, ticket: "x", label: nil, capacity: 1, now: t0)
        other.leave(ticket: "x", session: first)
        #expect(other.waiters.isEmpty)
    }

    @Test func slotsGoBackWhenTheSessionEndsOrAfterTheLongestHold() {
        var book = BuildSlotBook()
        let alive = UUID(), gone = UUID()
        _ = book.acquire(session: alive, ticket: nil, label: nil, capacity: 3, now: t0)
        _ = book.acquire(session: gone, ticket: nil, label: nil, capacity: 3, now: t0)
        _ = book.acquire(session: alive, ticket: "w", label: nil, capacity: 2, now: t0)
        #expect(book.prune(running: [alive], maxHold: 3600, now: t0.addingTimeInterval(10)).map(\.session) == [gone])
        #expect(book.slots.count == 1)
        #expect(book.prune(running: [alive], maxHold: 3600, now: t0.addingTimeInterval(3600)).count == 1)
        #expect(book.slots.isEmpty)
        var waiting = BuildSlotBook()
        _ = waiting.acquire(session: alive, ticket: nil, label: nil, capacity: 1, now: t0)
        _ = waiting.acquire(session: gone, ticket: "g", label: nil, capacity: 1, now: t0)
        waiting.prune(running: [alive], maxHold: 3600, now: t0)
        #expect(waiting.waiters.isEmpty)
        #expect(BuildSlotBook.isValidTicket("t123-456") && !BuildSlotBook.isValidTicket("") && !BuildSlotBook.isValidTicket("a b"))
    }

    // MARK: API and script

    @Test func routes() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/load") == .route(.load))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/slot/build/acquire") == .route(.slotAcquire("build")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/slot/build/release") == .route(.slotRelease("build")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/slot/build/acquire") == .methodNotAllowed)
        #expect(SessionCLI.Route.load.scope == .list && SessionCLI.Route.slotAcquire("build").scope == .slots)
        // A terminal a session opened runs the builds: it may take a slot, not start sessions.
        #expect(SessionCLI.openedScopes.contains(.slots) && SessionCLI.fullScopes.contains(.slots))
    }

    @Test func loadReport() throws {
        let slot = SessionCLILoad.Slot(id: "b_12345678", session: UUID(), sessionName: "Build bot", label: "xcodebuild", since: Date())
        var monitor = LoadMonitor()
        let s = sample(0, load: 120, pressure: .warning, compilers: 30, simulators: 11, sessions: 37, processes: 2000)
        monitor.add(s, thresholds: thresholds)
        let top = [LoadTopEntry(kind: "session", session: UUID(), name: "backend", project: "Wakeroo", cpuPercent: 85.04,
                                memoryBytes: 2140 << 20, processes: 14, agent: true, topProcesses: ["node 40%"])]
        let report = SessionCLILoad(level: monitor.level, settings: LoadSettings(), sample: s, thresholds: thresholds,
                                    triggers: monitor.triggers, capacity: 1, slots: [slot], waiting: 2, maxStartedSessions: 8,
                                    runningStartedSessions: 5, top: top, topProjects: [])
        #expect(report.text.contains("level: overloaded (new sessions and simulators are held back; 1 build slot)"))
        #expect(report.text.contains("simulators: 11 booted") && report.text.contains("build slots: 1/1 used, 2 waiting (3 when not overloaded)"))
        #expect(report.text.contains("b_12345678  Build bot"))
        #expect(report.text.contains("FIRE compilers > 12 (now 30)") && report.text.contains("off  swap > 64.0 GB"))
        #expect(report.text.contains("5/8 agent-started"))
        #expect(!report.text.contains("top sessions"))
        let detail = report.text(detail: true)
        #expect(detail.contains("top sessions") && detail.contains("85.0%") && detail.contains("Wakeroo / backend") && detail.contains("[agent]"))
        let json = try #require(String(data: AgentJSON.encode(report), encoding: .utf8))
        #expect(json.contains(#""level":"overloaded""#) && json.contains(#""slots_available":0"#) && json.contains(#""load_per_core":6"#))
        #expect(json.contains(#""fired":["compilers"]"#) && json.contains(#""trigger":"swap_growth""#) && json.contains(#""enabled":false"#))
        #expect(json.contains(#""limits":{"build_slots":3,"build_slots_overloaded":1,"max_simulators":4,"max_started_sessions":8,"running_started_sessions":5}"#))
        #expect(json.contains(#""top":[{"#) && json.contains(#""memory_mb":2140"#) && json.contains(#""busy_action":"nothing""#))
        #expect(json.contains(#""holds_starts":true"#))
        // Busy: informational.
        let busy = SessionCLILoad(level: .busy, settings: LoadSettings(), sample: s, thresholds: thresholds, triggers: [],
                                  capacity: 3, slots: [], waiting: 0)
        #expect(busy.text.hasPrefix("level: busy (informational: nothing is held back)") && !busy.throttled && !busy.holdsStarts)
        let empty = SessionCLILoad(level: .ok, settings: LoadSettings(), sample: nil, thresholds: thresholds, triggers: [],
                                   capacity: 3, slots: [], waiting: 0)
        #expect(empty.text == "level: ok\nno sample yet")
    }

    @Test func statusListsSlots() {
        let status = SessionCLIStatus(id: UUID(), name: "a", kind: "claude", state: "working", detail: nil, project: "p", startedBy: nil,
                                      stall: nil, simulators: [], slots: ["b_1"])
        #expect(status.text.contains("build slots: b_1"))
    }

    @Test func remoteLoadIsOptional() throws {
        let old = #"{"hostName":"Mac","sessions":[]}"#
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(old.utf8))
        #expect(decoded.load == nil)
        var snapshot = RemoteSnapshot(hostName: "Mac", sessions: [])
        snapshot.features = RemoteSnapshot.Feature.all
        snapshot.load = RemoteLoad(level: "overloaded", throttled: true, loadPerCore: 2.345, cores: 20, memoryPercent: 81,
                                   memoryPressure: "warning", simulators: 11, builds: 30, sessions: 37, slotsUsed: 1, slots: 1)
        #expect(snapshot.load?.loadPerCore == 2.3)
        let back = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(back.load == snapshot.load && back.supports(RemoteSnapshot.Feature.load))
        #expect(back.supports(RemoteSnapshot.Feature.loadDetail) && back.load?.top == nil)
        // The detail lists are optional both ways.
        snapshot.load?.top = [RemoteLoad.Top(session: UUID(), name: "a", project: "p", cpuPercent: 40, memoryMB: 500, agent: true)]
        snapshot.load?.bootedSimulators = [RemoteLoad.BootedSimulator(udid: "U", name: "iPhone", holder: nil, memoryMB: 1200)]
        snapshot.load?.fired = ["compilers"]
        let detailed = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(detailed.load == snapshot.load)
        struct OldLoad: Decodable { var level: String; var slots: Int }
        #expect(try JSONDecoder().decode(OldLoad.self, from: JSONEncoder().encode(snapshot.load)).slots == 1)
        // An older phone (no `load` key in its model) still decodes the snapshot: unknown keys are ignored.
        struct OldSnapshot: Decodable { var hostName: String; var sessions: [RemoteSession] }
        #expect(try JSONDecoder().decode(OldSnapshot.self, from: JSONEncoder().encode(snapshot)).hostName == "Mac")
    }

    // MARK: The script (a stand-in curl)

    private struct Run {
        var code: Int32
        var out: String
        var err: String
        var calls: [[String]]
    }

    private func run(_ args: [String], answers: [(body: String, status: String)] = [], session: Bool = true) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claudedeck-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "claudedeck")
        try Data(SessionCLI.script.utf8).write(to: script)
        for (index, answer) in answers.enumerated() {
            try Data(answer.body.utf8).write(to: dir.appending(path: "body\(index)"))
            try Data(answer.status.utf8).write(to: dir.appending(path: "status\(index)"))
        }
        let curl = dir.appending(path: "curl")
        try Data(#"""
        #!/bin/sh
        d=$(dirname "$0")
        n=$(cat "$d/count" 2>/dev/null || echo 0)
        echo $((n + 1)) > "$d/count"
        for a in "$@"; do printf '%s\037' "$a"; done >> "$d/calls"
        printf '\036' >> "$d/calls"
        [ -f "$d/status$n" ] || { printf '\n000 '; exit 7; }
        cat "$d/body$n"; printf '\n'; cat "$d/status$n"
        """#.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + args
        var env = ["PATH": dir.path + ":/usr/bin:/bin", "HOME": dir.path]
        if session {
            env["CLAUDEDECK_CLI_TOKEN"] = "tok-123"
            env["CLAUDEDECK_CLI_URL"] = "http://127.0.0.1:47832/v1/cli"
        }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let raw = (try? String(contentsOf: dir.appending(path: "calls"), encoding: .utf8)) ?? ""
        let calls = raw.split(separator: "\u{1E}").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty } }
        return Run(code: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self), calls: calls)
    }

    @Test func scriptLoad() throws {
        let load = try run(["load"], answers: [("level: ok", "200 0")])
        #expect(load.code == 0 && load.out == "level: ok\n")
        #expect(load.calls.first?.last == "http://127.0.0.1:47832/v1/cli/load" && load.calls.first?.contains("format=text") == true)
        #expect(try run(["load", "--json"], answers: [("{}", "200 0")]).calls.first?.contains("format=json") == true)
        #expect(load.calls.first?.contains("detail=0") == true)
        #expect(try run(["load", "--detail"], answers: [("level: ok", "200 0")]).calls.first?.contains("detail=1") == true)
        #expect(try run(["load", "extra"]).code == 2)
    }

    @Test func scriptSlot() throws {
        let acquired = try run(["slot", "acquire", "build", "--label", "ios build"], answers: [("b_12345678", "200 0")])
        #expect(acquired.code == 0 && acquired.out == "b_12345678\n")
        let call = try #require(acquired.calls.first)
        #expect(call.last == "http://127.0.0.1:47832/v1/cli/slot/build/acquire")
        #expect(call.contains("label=ios build") && call.contains("ticket=") && call.contains("timeout=0"))
        // --wait: the same ticket again until a slot is free.
        let waited = try run(["slot", "acquire", "build", "--wait", "60"],
                             answers: [(#"{"error":"no_slot"}"#, "429 124"), ("b_aaaabbbb", "200 0")])
        #expect(waited.code == 0 && waited.out == "b_aaaabbbb\n" && waited.calls.count == 2)
        let ticket = waited.calls.map { $0.first { $0.hasPrefix("ticket=t") } }
        #expect(ticket[0] != nil && ticket[0] == ticket[1])
        let full = try run(["slot", "acquire"], answers: [(#"{"error":"no_slot"}"#, "429 124")])
        #expect(full.code == 124 && full.err.contains("every build slot is taken"))
        let release = try run(["slot", "release", "build", "b_12345678"], answers: [("released b_12345678", "200 0")])
        #expect(release.code == 0 && release.calls.first?.contains("id=b_12345678") == true)
        #expect(release.calls.first?.last == "http://127.0.0.1:47832/v1/cli/slot/build/release")
        #expect(try run(["slot", "grab"]).code == 2)
        #expect(try run(["slot", "acquire", "--wait", "soon"]).code == 2)
    }

    @Test func scriptHeavy() throws {
        // A slot, the command, the release; the command's code comes through.
        let ran = try run(["heavy", "--", "sh", "-c", "echo built; exit 3"], answers: [("b_12345678", "200 0"), ("released", "200 0")])
        #expect(ran.code == 3 && ran.out == "built\n")
        #expect(ran.calls.count == 2)
        #expect(ran.calls[0].last == "http://127.0.0.1:47832/v1/cli/slot/build/acquire" && ran.calls[0].contains("label=sh -c echo built; exit 3"))
        #expect(ran.calls[1].last == "http://127.0.0.1:47832/v1/cli/slot/build/release" && ran.calls[1].contains("id=b_12345678"))
        // No slot in time: the command doesn't run, the place in line is given up, 124.
        let late = try run(["heavy", "--wait", "0", "--", "sh", "-c", "echo should-not-run"],
                           answers: [(#"{"error":"no_slot"}"#, "429 124"), ("ok", "200 0")])
        #expect(late.code == 124 && !late.out.contains("should-not-run"))
        #expect(late.calls.last?.contains { $0.hasPrefix("ticket=t") } == true)
        // ClaudeDeck not answering: it runs anyway.
        let down = try run(["heavy", "--", "sh", "-c", "echo anyway"])
        #expect(down.code == 0 && down.out == "anyway\n" && down.err.contains("without a build slot"))
        // Outside ClaudeDeck: just runs it, no curl.
        let outside = try run(["heavy", "sh", "-c", "exit 5"], session: false)
        #expect(outside.code == 5 && outside.calls.isEmpty)
        #expect(try run(["heavy"]).code == 2)
    }

    @Test func scriptHints() throws {
        let new = try run(["new", "--prompt", "x"], answers: [(#"{"error":"overloaded"}"#, "429 4")])
        #expect(new.code == 4 && new.err.contains("new --queue"))
        let sim = try run(["sim", "acquire"], answers: [(#"{"error":"too_many_booted"}"#, "429 4")])
        #expect(sim.code == 4 && sim.err.contains("too many simulators are booted"))
        #expect(SessionCLI.skill.contains("claudedeck heavy --") && SessionCLI.skill.contains("claudedeck load"))
    }
}
