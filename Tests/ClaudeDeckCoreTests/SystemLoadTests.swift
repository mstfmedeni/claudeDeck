import Foundation
import Testing
@testable import ClaudeDeckCore

/// The load monitor (level with hysteresis, the overload episode), build slots, throttling, the
/// `load` / `slot` / `heavy` routes and script, and the phone's load field.
@Suite struct SystemLoadTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var thresholds: LoadThresholds { LoadThresholds.resolve(LoadSettings(), cores: 20) }

    private func sample(_ seconds: Double, load: Double, pressure: MemoryPressure = .normal, compilers: Int = 0, builds: Int = 0,
                        simulators: Int = 0, sessions: Int = 0, swapGB: Double = 0, processes: Int = 0) -> LoadSample {
        LoadSample(at: t0.addingTimeInterval(seconds), load1: load, cores: 20, pressure: pressure,
                   swapUsedBytes: UInt64(swapGB * 1_073_741_824), simulators: simulators, compilers: compilers,
                   builds: builds, processes: processes, sessions: sessions)
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
        // swap +2 GB in 5 min under pressure, more builds than a third of the cores.
        #expect(t.overloadLoad == 200 && t.overloadSustain == 180 && t.maxProcesses == 3000)
        #expect(t.pressureLevel == .critical && t.swapGrowthBytes == 2 << 30 && t.swapGrowthWindow == 300)
        #expect(t.enabled == [.pressure, .swapGrowth, .compilers, .load, .processes])
        // Busy: 2 × cores for a minute, or half the build limit; only shown by default.
        #expect(t.busyLoad == 40 && t.busySustain == 60 && t.busyAction == .nothing)
        #expect(t.overloadBuilds == 7 && t.busyBuilds == 3)
        #expect(t.maxSimulators == 4 && t.buildSlots == 3 && t.overloadedBuildSlots == 1)
        #expect(t.maxSlotHold == 3600)
        let small = LoadThresholds.resolve(LoadSettings(), cores: 8)
        #expect(small.overloadLoad == 80 && small.overloadBuilds == 3 && small.maxSimulators == 2 && small.buildSlots == 1)
        #expect(LoadThresholds.defaultBuilds(cores: 4) == 3 && LoadThresholds.defaultBuilds(cores: 12) == 4)
        let big = LoadThresholds.resolve(LoadSettings(), cores: 64)
        #expect(big.maxSimulators == 10 && big.buildSlots == 8)
        let c = thresholds {
            $0.maxSimulators = 7
            $0.buildSlots = 5
            $0.overloadedBuildSlots = 9 // never above the full count
            $0.maxCompilers = 9
            $0.busyFactor = 30 // never above the overload factor
            $0.overloadMinutes = 1.5
        }
        #expect(c.maxSimulators == 7 && c.buildSlots == 5 && c.overloadedBuildSlots == 5 && c.overloadBuilds == 9)
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
        #expect(changed.overloadFactor == 3 && changed.busyFactor == 1.5 && changed.maxCompilers == nil)
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
        settings.busyAction = .nothing
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
        #expect(LoadThrottle.slotCapacity(thresholds { $0.busyAction = .nothing }, level: high.level, enabled: true) == 3)
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
        // Memory pressure warning and more than half the build limit (3 of 7) are busy at once.
        var warn = LoadMonitor()
        warn.add(sample(0, load: 5, pressure: .warning), thresholds: thresholds)
        #expect(warn.level == .busy)
        var builds = LoadMonitor()
        builds.add(sample(0, load: 5, compilers: 60, builds: 4), thresholds: thresholds)
        #expect(builds.level == .busy)
        var three = LoadMonitor()
        three.add(sample(0, load: 5, compilers: 60, builds: 3), thresholds: thresholds)
        #expect(three.level == .ok)
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
        builds.add(sample(0, load: 5, pressure: .warning, compilers: 40, builds: 8), thresholds: thresholds)
        #expect(builds.level == .overloaded && builds.fired == [.compilers])
        // The owner's case: 2 builds fanning out into 45 compiler processes is neither overloaded nor busy.
        var twoBuilds = LoadMonitor()
        twoBuilds.add(sample(0, load: 30, compilers: 45, builds: 2), thresholds: thresholds)
        #expect(twoBuilds.level == .ok && twoBuilds.fired.isEmpty)
        // Many builds while the Mac copes (load under busy, memory normal): busy, not overloaded.
        var eight = LoadMonitor()
        eight.add(sample(0, load: 5, compilers: 100, builds: 8), thresholds: thresholds)
        #expect(eight.level == .busy)
        // With a busy load they fire.
        var loaded = LoadMonitor()
        loaded.add(sample(0, load: 50, compilers: 100, builds: 8), thresholds: thresholds)
        #expect(loaded.level == .overloaded && loaded.fired == [.compilers])
        // At the limit (7, not more): no.
        var seven = LoadMonitor()
        seven.add(sample(0, load: 50, pressure: .warning, builds: 7), thresholds: thresholds)
        #expect(seven.fired.isEmpty)
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
        let s = sample(0, load: 5, pressure: .critical, compilers: 30, builds: 30, swapGB: 100, processes: 5000)
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
        #expect(none.triggers.first { $0.trigger == .compilers }?.threshold == 7)
        #expect(none.triggers.first { $0.trigger == .compilers }?.unit == "builds")
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
        monitor.add(sample(0, load: 5, pressure: .warning, builds: 30), thresholds: thresholds)
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
        #expect(monitor.add(sample(180, load: 5, pressure: .critical), thresholds: thresholds) == [.level(from: .busy, to: .overloaded)])
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
        // Busy with the default "do nothing": nothing waits, every build slot.
        #expect(LoadThrottle.slotCapacity(t, level: monitor.level, enabled: true) == 3)
        let report = SessionCLILoad(level: monitor.level, settings: LoadSettings(), sample: monitor.latest, thresholds: t,
                                    triggers: monitor.triggers, capacity: 3, slots: [], waiting: 0)
        #expect(report.level == "busy" && !report.holdsStarts && report.text.hasPrefix("level: busy (informational: nothing is held back)"))
        // With "hold new work": new work still waits, half the build slots, rounded up.
        var hold = LoadSettings()
        hold.busyAction = .holdStarts
        let held = LoadThresholds.resolve(hold, cores: 20)
        #expect(LoadThrottle.slotCapacity(held, level: monitor.level, enabled: true) == 2)
        let heldReport = SessionCLILoad(level: monitor.level, settings: hold, sample: monitor.latest, thresholds: held,
                                        triggers: monitor.triggers, capacity: 2, slots: [], waiting: 0)
        #expect(heldReport.holdsStarts && heldReport.text.hasPrefix("level: busy (new work waits"))
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
        let s = sample(0, load: 120, pressure: .warning, compilers: 90, builds: 5, simulators: 11, sessions: 37, swapGB: 4, processes: 2900)
        #expect(LoadContributor.of(s, thresholds: thresholds) ==
                [.simulators(11), .builds(5), .sessions(37), .memory(.warning), .swap(4 << 30), .processes(2900), .load(120, cores: 20)])
        #expect(LoadContributor.builds(5).text == "5 builds" && LoadContributor.builds(1).text == "1 build")
        #expect(LoadContributor.of(sample(0, load: 3, simulators: 1), thresholds: thresholds) == [.load(3, cores: 20)])
        #expect(LoadContributor.simulators(11).text == "11 simulators booted")
    }

    /// A process table from (pid, ppid, name) rows.
    private func table(_ rows: [(Int32, Int32, String)]) -> [LoadProcess] {
        rows.map { LoadProcess(pid: $0.0, ppid: $0.1, name: $0.2) }
    }

    /// `count` workers named `name` under `parent`, pids from `first`.
    private func workers(_ count: Int, _ name: String = "swift-frontend", parent: Int32, first: Int32) -> [(Int32, Int32, String)] {
        (0..<Int32(count)).map { (first + $0, parent, name) }
    }

    @Test func processNamesAreCounted() {
        let counted = LoadProcesses.count(table([(1, 0, "launchd"), (10, 1, "launchd_sim"), (11, 1, "launchd_sim"), (20, 1, "zsh"),
                                                 (21, 20, "claude"), (30, 1, "SimMetalHost")]))
        #expect(counted.simulators == 2 && counted.compilers == 0 && counted.builds == 0 && counted.processes == 6)
        #expect(LoadProcesses.simulators(["launchd_sim", "zsh", "launchd_sim"]) == 2)
        #expect(MemoryPressure(kernelLevel: 1) == .normal && MemoryPressure(kernelLevel: 2) == .warning && MemoryPressure(kernelLevel: 4) == .critical)
        #expect(MemoryPressure.normal < .warning && MemoryPressure.warning < .critical)
    }

    @Test func buildsAreCountedByProcessTree() {
        let shell: [(Int32, Int32, String)] = [(1, 0, "launchd"), (100, 1, "claude"), (101, 100, "zsh"), (102, 100, "zsh")]
        // xcodebuild → SWBBuildService → swift-frontend × 20 (and a clang and ld): one build.
        let one = LoadProcesses.count(table(shell + [(200, 101, "xcodebuild"), (201, 200, "SWBBuildService")]
                                            + workers(20, parent: 201, first: 300) + [(400, 201, "clang"), (401, 400, "ld")]))
        #expect(one.builds == 1 && one.compilers == 23)
        // Two xcodebuilds in two shells: two builds.
        let two = LoadProcesses.count(table(shell + [(200, 101, "xcodebuild"), (201, 200, "SWBBuildService"), (210, 102, "xcodebuild"),
                                                     (211, 210, "SWBBuildService")]
                                            + workers(20, parent: 201, first: 300) + workers(20, parent: 211, first: 500)))
        #expect(two.builds == 2 && two.compilers == 42)
        // An xcodebuild that is only resolving packages (no compiler yet) is a build already.
        #expect(LoadProcesses.count(table(shell + [(200, 101, "xcodebuild")])).builds == 1)
        // A plain swiftc with its frontend and linker: one.
        let swiftc = LoadProcesses.count(table(shell + [(200, 101, "swiftc"), (201, 200, "swift-frontend"), (202, 200, "ld")]))
        #expect(swiftc.builds == 1 && swiftc.compilers == 3)
        // swift build → swiftc → swift-frontend: one.
        let spm = LoadProcesses.count(table(shell + [(200, 101, "swift-build"), (201, 200, "swiftc"), (202, 201, "swift-driver")]
                                            + workers(12, parent: 202, first: 300)))
        #expect(spm.builds == 1 && spm.compilers == 15)
        // Xcode.app: its build service counts while it compiles, and not while idle.
        let xcode: [(Int32, Int32, String)] = [(1, 0, "launchd"), (50, 1, "Xcode"), (51, 50, "SWBBuildService")]
        #expect(LoadProcesses.count(table(xcode)).builds == 0)
        #expect(LoadProcesses.count(table(xcode + workers(20, parent: 51, first: 300))).builds == 1)
        // The owner's Mac: two xcodebuilds and Xcode building at once, 45 compiler processes: 3 builds.
        let mixed = LoadProcesses.count(table(shell + xcode.dropFirst() + [(200, 101, "xcodebuild"), (201, 200, "SWBBuildService"),
                                                                           (210, 102, "xcodebuild"), (211, 210, "SWBBuildService")]
                                              + workers(20, parent: 201, first: 300) + workers(20, parent: 211, first: 500)
                                              + workers(3, parent: 51, first: 700)))
        #expect(mixed.builds == 3 && mixed.compilers == 45)
        // swift test → swiftc × 4 (one per module) → swift-frontend: one; running the tests afterwards: none.
        let swiftTest = LoadProcesses.count(table(shell + [(200, 101, "swift-test")] + workers(4, "swiftc", parent: 200, first: 300)
                                                  + workers(8, parent: 300, first: 400)))
        #expect(swiftTest.builds == 1 && swiftTest.compilers == 12)
        #expect(LoadProcesses.count(table(shell + [(200, 101, "swift-test"), (201, 200, "ClaudeDeckPackageTests")])).builds == 0)
        // make -j: one build however many clangs.
        #expect(LoadProcesses.count(table(shell + [(200, 101, "make")] + workers(8, "clang", parent: 200, first: 300))).builds == 1)
        // Two separate clangs from a shell: two; compiler processes some other tool runs: one per parent.
        #expect(LoadProcesses.count(table(shell + [(200, 101, "clang"), (201, 101, "clang")])).builds == 2)
        #expect(LoadProcesses.count(table(shell + [(200, 101, "cargo")] + workers(3, "ld", parent: 200, first: 300))).builds == 1)
        // A parent missing from the table (exited) or a loop doesn't hang or crash.
        #expect(LoadProcesses.count(table([(300, 999, "swift-frontend"), (301, 999, "swift-frontend")])).builds == 1)
        #expect(LoadProcesses.count(table([(10, 11, "xcodebuild"), (11, 10, "xcodebuild")])).builds >= 1)
    }

    @Test func buildLimitMigratesFromTheProcessCount() throws {
        // The owner's 0.6.24 settings: 30 compiler processes. Meaningless as builds: back to the default.
        let owner = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"version":3,"maxCompilers":30,"compilersEnabled":true,"maxProcesses":4000}"#.utf8))
        #expect(owner.maxCompilers == nil && owner.version == LoadSettings.currentVersion && owner.maxProcesses == 4000)
        #expect(LoadThresholds.resolve(owner, cores: 20).overloadBuilds == 7)
        // Switched off stays off.
        let off = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"version":3,"maxCompilers":30,"compilersEnabled":false}"#.utf8))
        #expect(!off.compilersEnabled && off.maxCompilers == nil)
        // A build limit set after the change stays (clamped to 1–64).
        let mine = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"version":4,"maxCompilers":5}"#.utf8))
        #expect(mine.maxCompilers == 5)
        let huge = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"version":4,"maxCompilers":400}"#.utf8))
        #expect(huge.maxCompilers == 64)
        var set = LoadSettings()
        set.maxCompilers = 4
        #expect(try JSONDecoder().decode(LoadSettings.self, from: JSONEncoder().encode(set)).maxCompilers == 4)
        // An injected sample from before builds were counted reads as 0 builds.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(LoadSample.self, from: Data(#"{"at":"2026-11-23T10:00:00Z","load1":4,"load5":3,"cores":20,"pressure":"normal","memoryUsedPercent":50,"swapUsedBytes":0,"simulators":1,"compilers":45,"processes":900,"sessions":3}"#.utf8))
        #expect(old.builds == 0 && old.compilers == 45)
    }

    /// The owner's Mac: overloaded with every trigger ok (memory normal, swap +0.0, compilers 5,
    /// load 0.91 per core, 856 processes). It must leave overloaded after `overloadCalm`, say how
    /// long is left meanwhile, and not stay frozen when the next sample is late.
    @Test func overloadedWithNothingFiringEndsAfterTheCalmAndSaysWhen() {
        let t = thresholds
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 18.2, pressure: .critical, compilers: 5, processes: 856), thresholds: t)
        #expect(monitor.level == .overloaded && monitor.fired == [.pressure])
        var ended: [LoadEvent] = []
        for i in 1...6 {
            let events = monitor.add(sample(Double(i) * 12, load: 18.2, compilers: 5, processes: 856), thresholds: t)
            #expect(monitor.fired.isEmpty && monitor.exitBlockedBy == nil)
            if i < 6 {
                #expect(monitor.level == .overloaded)
                #expect(monitor.exitSecondsLeft(now: t0.addingTimeInterval(Double(i) * 12)) == 60 - Double(i - 1) * 12)
            } else {
                ended = events
            }
        }
        #expect(monitor.level == .ok)
        #expect(ended == [.level(from: .overloaded, to: .ok), .episodeEnded(1)])

        // The text says why it is still overloaded.
        var m2 = LoadMonitor()
        m2.add(sample(0, load: 18.2, pressure: .critical, compilers: 5, processes: 856), thresholds: t)
        m2.add(sample(12, load: 18.2, compilers: 5, processes: 856), thresholds: t)
        m2.add(sample(24, load: 18.2, compilers: 5, processes: 856), thresholds: t)
        var report = SessionCLILoad(level: m2.level, settings: LoadSettings(), sample: m2.latest, thresholds: t,
                                    triggers: m2.triggers, capacity: 1, slots: [], waiting: 0)
        report.explainExit(m2, now: t0.addingTimeInterval(24))
        #expect(report.exitIn == 48 && report.lastFired == ["pressure"] && report.lastFiredAgo == 24)
        #expect(report.text.contains("exiting: 48 s left"))
        #expect(report.text.contains("last fired 24 s ago: pressure"))

        // A sampler that stalls after one calm sample: the level counts as ended once the calm ran out.
        var m3 = LoadMonitor()
        m3.add(sample(0, load: 18.2, pressure: .critical, compilers: 5, processes: 856), thresholds: t)
        m3.add(sample(12, load: 18.2, compilers: 5, processes: 856), thresholds: t)
        #expect(m3.level == .overloaded)
        #expect(m3.effectiveLevel(now: t0.addingTimeInterval(50)) == .overloaded)
        #expect(m3.effectiveLevel(now: t0.addingTimeInterval(73)) == .ok)
        // The next sample, however late, ends it.
        m3.add(sample(600, load: 18.2, compilers: 5, processes: 856), thresholds: t)
        #expect(m3.level == .ok)
    }

    /// Nothing fires but the load is still within the exit margin: it stays, and says so.
    @Test func overloadedHeldByTheExitMarginSaysSo() {
        let t = thresholds
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 100, pressure: .critical), thresholds: t)
        monitor.add(sample(12, load: 170), thresholds: t)
        #expect(monitor.level == .overloaded && monitor.fired.isEmpty && monitor.exitSecondsLeft(now: t0.addingTimeInterval(12)) == nil)
        var report = SessionCLILoad(level: monitor.level, settings: LoadSettings(), sample: monitor.latest, thresholds: t,
                                    triggers: monitor.triggers, capacity: 1, slots: [], waiting: 0)
        report.explainExit(monitor, now: t0.addingTimeInterval(12))
        #expect(report.text.contains("exit held: load 170.0 not yet under 160.0 (exit margin)"))
    }

    // MARK: Throttling

    @Test func busyHoldsNewWorkOnly() {
        // Busy with "hold new work" (no longer the default): new starts queue, the queue doesn't
        // drain, sim acquire waits, build slots drop to half (never below the overloaded count).
        let hold = thresholds { $0.busyAction = .holdStarts }
        #expect(LoadThrottle.start(level: .busy, busyAction: .holdStarts, enabled: true, queue: true) == .queue)
        #expect(LoadThrottle.start(level: .busy, busyAction: .holdStarts, enabled: true, queue: false) == .refuse)
        #expect(!LoadThrottle.drains(level: .busy, busyAction: .holdStarts, enabled: true))
        #expect(LoadThrottle.simulator(level: .busy, busyAction: .holdStarts, enabled: true, booted: 0, wanted: 1, max: 4) == .busy)
        #expect(LoadThrottle.slotCapacity(hold, level: .busy, enabled: true) == 2)
        #expect(LoadThrottle.slotCapacity(thresholds { $0.busyAction = .holdStarts; $0.buildSlots = 8 }, level: .busy, enabled: true) == 4)
        #expect(LoadThrottle.slotCapacity(thresholds { $0.busyAction = .holdStarts; $0.buildSlots = 8; $0.overloadedBuildSlots = 5 },
                                          level: .busy, enabled: true) == 6)
        // Overloaded adds the calming rules: fewer slots still.
        #expect(LoadThrottle.slotCapacity(thresholds { $0.buildSlots = 8 }, level: .overloaded, enabled: true) == 1)
        // Busy never sends agents anything: an episode (and its one message) starts only at overloaded.
        var monitor = LoadMonitor()
        for i in 0..<10 { monitor.add(sample(Double(i) * 12, load: 50), thresholds: thresholds) }
        #expect(monitor.level == .busy && !monitor.inEpisode && monitor.episode == 0)
        // "Do nothing (only show it)", the default: busy holds nothing back, every build slot.
        #expect(LoadThrottle.slotCapacity(thresholds, level: .busy, enabled: true) == 3)
        #expect(LoadThrottle.start(level: .busy, busyAction: .nothing, enabled: true, queue: false) == .allow)
        #expect(LoadThrottle.drains(level: .busy, busyAction: .nothing, enabled: true))
        #expect(LoadThrottle.slotCapacity(thresholds { $0.busyAction = .nothing }, level: .busy, enabled: true) == 3)
        #expect(LoadThrottle.simulator(level: .busy, busyAction: .nothing, enabled: true, booted: 0, wanted: 1, max: 4) == .allow)
        // The brake off: nothing waits at any level.
        #expect(LoadThrottle.simulator(level: .busy, busyAction: .holdStarts, enabled: false, booted: 0, wanted: 1, max: 4) == .allow)
        #expect(LoadThrottle.slotCapacity(hold, level: .busy, enabled: false) == 3)
    }

    @Test func busyDefaultMigratesFromOlderSettings() throws {
        // 0.6.20 (version 3) forced "hold new work" on everyone; version 4 makes busy only shown
        // again, so every older file reads as "nothing".
        #expect(LoadSettings().busyAction == .nothing)
        let forced = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"version":3,"busyAction":"hold_starts"}"#.utf8))
        #expect(forced.busyAction == .nothing)
        let old = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"version":2,"busyAction":"nothing"}"#.utf8))
        #expect(old.busyAction == .nothing)
        let none = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"busyAction":"hold_starts"}"#.utf8))
        #expect(none.busyAction == .nothing)
        // Chosen after the change, either stays.
        let kept = try JSONDecoder().decode(LoadSettings.self, from: Data(#"{"version":4,"busyAction":"hold_starts"}"#.utf8))
        #expect(kept.busyAction == .holdStarts)
        var settings = LoadSettings()
        settings.busyAction = .holdStarts
        let roundTrip = try JSONDecoder().decode(LoadSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.busyAction == .holdStarts)
    }

    @Test func buildsAreCountedSteady() {
        // Short builds (a lone swiftc, a link) show in one sample only: the rules use the median
        // of the last 3 samples, so one spike neither fires nor makes busy.
        let t = thresholds
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 50, compilers: 40, builds: 2), thresholds: t)
        monitor.add(sample(12, load: 50, compilers: 90, builds: 9), thresholds: t)
        #expect(monitor.fired.isEmpty)
        #expect(monitor.triggers.first { $0.trigger == .compilers }?.current == 2)
        monitor.add(sample(24, load: 50, compilers: 40, builds: 2), thresholds: t)
        #expect(monitor.fired.isEmpty)
        // Builds that last (two of the last three samples) count, with a busy load.
        monitor.add(sample(36, load: 50, compilers: 40, builds: 2), thresholds: t)
        monitor.add(sample(48, load: 50, compilers: 90, builds: 8), thresholds: t)
        #expect(monitor.fired.isEmpty)
        monitor.add(sample(60, load: 50, compilers: 120, builds: 9), thresholds: t)
        #expect(monitor.fired == [.compilers] && monitor.level == .overloaded)
        #expect(monitor.triggers.first { $0.trigger == .compilers }?.current == 8)
        // Old samples (over a minute) don't count.
        #expect(LoadMonitor.steadyBuilds(sample(200, load: 0, builds: 3),
                                         history: [sample(100, load: 0, builds: 30), sample(110, load: 0, builds: 30)]) == 3)
        // The text shows the builds, the steady count and the compiler processes.
        let report = SessionCLILoad(level: monitor.level, settings: LoadSettings(), sample: monitor.latest, thresholds: t,
                                    triggers: monitor.triggers, capacity: 1, slots: [], waiting: 0)
        #expect(report.text.contains("builds: 9 now, 8 steady (median of the last 3 samples), 120 compiler processes"))
        #expect(report.text.contains("FIRE builds > 7 (now 8)"))
        #expect(report.builds == 9 && report.maxBuilds == 7 && report.compilerProcesses == 120)
        // `compilers` / `max_compilers` stay and mean the same as `builds` / `max_builds`.
        #expect(report.compilers == 9 && report.maxCompilers == 7)
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
        let s = sample(0, load: 120, pressure: .warning, compilers: 45, builds: 8, simulators: 11, sessions: 37, processes: 2000)
        monitor.add(s, thresholds: thresholds)
        let top = [LoadTopEntry(kind: "session", session: UUID(), name: "backend", project: "Wakeroo", cpuPercent: 85.04,
                                memoryBytes: 2140 << 20, processes: 14, agent: true, topProcesses: ["node 40%"])]
        let report = SessionCLILoad(level: monitor.level, settings: LoadSettings(), sample: s, thresholds: thresholds,
                                    triggers: monitor.triggers, capacity: 1, slots: [slot], waiting: 2, maxStartedSessions: 8,
                                    runningStartedSessions: 5, top: top, topProjects: [])
        #expect(report.text.contains("level: overloaded (calming down: new sessions and simulators wait, 1 build slot, agents asked once to put heavy work off)"))
        #expect(report.text.contains("simulators: 11 booted") && report.text.contains("build slots: 1/1 used, 2 waiting (3 when not overloaded)"))
        #expect(report.text.contains("b_12345678  Build bot"))
        #expect(report.text.contains("FIRE builds > 7 (now 8)") && report.text.contains("off  swap > 64.0 GB"))
        #expect(report.text.contains("builds: 8 now, 45 compiler processes"))
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
        #expect(json.contains(#""builds":8"#) && json.contains(#""max_builds":7"#) && json.contains(#""compiler_processes":45"#))
        #expect(json.contains(#""compilers":8"#) && json.contains(#""max_compilers":7"#) && json.contains(#""unit":"builds""#))
        // Busy: informational (the default), or new work waits with "hold new work".
        let informational = SessionCLILoad(level: .busy, settings: LoadSettings(), sample: s, thresholds: thresholds, triggers: [],
                                           capacity: 3, slots: [], waiting: 0)
        #expect(informational.text.hasPrefix("level: busy (informational: nothing is held back)") && !informational.throttled)
        var hold = LoadSettings()
        hold.busyAction = .holdStarts
        let busy = SessionCLILoad(level: .busy, settings: hold, sample: s, thresholds: thresholds, triggers: [],
                                  capacity: 1, slots: [], waiting: 0)
        #expect(busy.text.hasPrefix("level: busy (new work waits: new sessions, simulators and builds beyond 1 slot; running agents go on)"))
        #expect(busy.holdsStarts)
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

    @Test func remoteLoadHistoryIsPerMinuteAndBounded() throws {
        // An hour and a half at one sample every 12 s (5 a minute), starting on a minute.
        let start = Date(timeIntervalSinceReferenceDate: 60 * 1_000_000)
        let samples = (0..<450).map { i in
            LoadSample(at: start.addingTimeInterval(Double(i) * 12), load1: Double(i % 5) * 4, cores: 20,
                       memoryUsedPercent: 50, simulators: i % 5 == 2 ? 3 : 1, compilers: (i % 5) * 20, builds: i % 5)
        }
        let history = RemoteLoad.history(from: samples)
        #expect(history.count == RemoteLoad.maxHistory)
        // Finished minutes only: the last sample's minute (89) is left out.
        #expect(history.last?.at == start.addingTimeInterval(88 * 60))
        #expect(history.first?.at == start.addingTimeInterval(29 * 60))
        // Averages for load and memory, the highest for simulators and builds.
        #expect(history.last?.loadPerCore == 0.4 && history.last?.memoryPercent == 50)
        #expect(history.last?.simulators == 3 && history.last?.builds == 4)
        #expect(RemoteLoad.history(from: Array(samples.prefix(3))).isEmpty)

        // The new fields are optional: an older Mac's load decodes with them nil, and they round-trip.
        var load = RemoteLoad(level: "ok", throttled: false, loadPerCore: 0.4, cores: 20, memoryPercent: 50, memoryPressure: "normal",
                              simulators: 1, builds: 0, sessions: 2, slotsUsed: 0, slots: 3)
        let old = try JSONDecoder().decode(RemoteLoad.self, from: JSONEncoder().encode(load))
        #expect(old.history == nil && old.topProjects == nil && old.slotHolders == nil && old.runningBuilds == nil)
        #expect(old.maxBuilds == nil && old.compilerProcesses == nil)
        load.maxBuilds = 7
        load.compilerProcesses = 45
        load.history = history
        load.topProjects = [RemoteLoad.ProjectUse(name: "p", cpuPercent: 120, memoryMB: 900)]
        load.slotHolders = [RemoteLoad.SlotHolder(id: "b_1", session: UUID(), name: "a", label: "xcodebuild", since: start)]
        load.runningBuilds = [RemoteLoad.Build(pid: 42, name: "swift-frontend", session: nil, cpuPercent: 95)]
        #expect(try JSONDecoder().decode(RemoteLoad.self, from: JSONEncoder().encode(load)) == load)
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.loadHistory))
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
