import Foundation
import Testing
@testable import ClaudeDeckCore

/// `sim acquire`'s simslim rules (SimSlim.swift) with a fake simslim runner.
@Suite struct SimSlimTests {
    static let udid = "A33E342E-4640-4526-A161-2FC68BC8C933"

    /// Records every call and answers from `answers` (by subcommand), 0 otherwise.
    final class FakeSimslim: @unchecked Sendable {
        var calls: [[String]] = []
        var answers: [String: SimSlim.CommandResult] = [:]
        var runner: SimSlim.Runner {
            { args, _ in
                self.calls.append(args)
                return self.answers[args.first ?? ""] ?? SimSlim.CommandResult(status: 0)
            }
        }
    }

    static func plan(_ form: [String: String], profile: SimSlim.Profile = .builtIn) -> SimSlim.Plan? {
        SimSlim.plan(SimSlim.Options(form: form), profile: profile)
    }

    // MARK: Arguments for every flag

    @Test func defaultKeepsStoreAndICloud() throws {
        let plan = try #require(Self.plan([:]))
        #expect(SimSlim.onArguments(udid: Self.udid, plan: plan, noReboot: false) == ["on", Self.udid, "--except", "store,icloud"])
        #expect(SimSlim.onArguments(udid: Self.udid, plan: plan, noReboot: true) == ["on", Self.udid, "--except", "store,icloud", "--no-reboot"])
        #expect(plan.profile == "default")
    }

    @Test func keepAddsCategories() throws {
        let plan = try #require(Self.plan(["keep": "family,Health, store"]))
        #expect(plan.except == ["store", "icloud", "family", "health"])
        #expect(plan.warnings.isEmpty)
        let unknown = try #require(Self.plan(["keep": "family,bogus"]))
        #expect(unknown.except == ["store", "icloud", "family"])
        #expect(unknown.warnings == ["slim_unknown_category:bogus"])
    }

    @Test func fullSlimKeepsNothing() throws {
        let plan = try #require(Self.plan(["full": "1", "keep": "family"]))
        #expect(plan.except == nil && plan.profile == "full")
        #expect(SimSlim.onArguments(udid: Self.udid, plan: plan, noReboot: false) == ["on", Self.udid])
    }

    @Test func stockWinsOverEverything() {
        #expect(Self.plan(["stock": "1", "full": "1", "keep": "family"]) == nil)
        let outcome = SimSlim.apply(udid: Self.udid, booted: false, plan: nil, keepState: false, run: FakeSimslim().runner)
        #expect(outcome.state == .off && !outcome.booted)
    }

    @Test func offAndMeasureArguments() {
        #expect(SimSlim.offArguments(udid: Self.udid, preserveBootState: false) == ["off", Self.udid])
        #expect(SimSlim.offArguments(udid: Self.udid, preserveBootState: true) == ["off", Self.udid, "--preserve-boot-state"])
        #expect(SimSlim.measureArguments(udid: Self.udid) == ["measure", Self.udid, "--json"])
    }

    // MARK: Profiles (simslim.json)

    static func profile(_ json: String?) -> SimSlim.Profile {
        SimSlim.profile(folder: "/repo") { path in
            #expect(path == "/repo/simslim.json")
            return json.map { Data($0.utf8) }
        }
    }

    @Test func profileFromFile() throws {
        let profile = Self.profile(#"{"name":"wakeroo","except":["store","icloud","widgets","siri","family"],"keep":["com.apple.apsd"]}"#)
        #expect(profile.except == ["store", "icloud", "widgets", "siri", "family"] && profile.warnings.isEmpty)
        let plan = try #require(SimSlim.plan(SimSlim.Options(keep: ["health"]), profile: profile))
        #expect(plan.profile == "wakeroo")
        #expect(SimSlim.onArguments(udid: Self.udid, plan: plan, noReboot: false)
            == ["on", Self.udid, "--except", "store,icloud,widgets,siri,family,health", "--keep", "com.apple.apsd"])
        #expect(SimSlim.verifyArguments(udid: Self.udid, plan: plan)
            == ["verify", Self.udid, "--except", "store,icloud,widgets,siri,family,health", "--keep", "com.apple.apsd"])
    }

    @Test func profileMissingOrInvalid() {
        #expect(Self.profile(nil) == .builtIn)
        #expect(SimSlim.profile(folder: nil) == .builtIn)
        let invalid = Self.profile("{not json")
        #expect(invalid.except == SimSlim.defaultExcept && invalid.warnings == ["slim_profile_invalid"] && invalid.path == nil)
        let unknown = Self.profile(#"{"except":["store","weather"]}"#)
        #expect(unknown.except == ["store"] && unknown.warnings == ["slim_unknown_category:weather"])
        #expect(unknown.label == "simslim.json")
    }

    @Test func plainIgnoresProfile() throws {
        let profile = Self.profile(#"{"name":"x","except":["widgets"]}"#)
        let plan = try #require(SimSlim.plan(SimSlim.Options(mode: .full), profile: profile))
        #expect(plan.except == nil)
        #expect(SimSlim.plan(SimSlim.Options(mode: .stock), profile: profile) == nil)
    }

    // MARK: apply

    @Test func shutDownDeviceGetsSlimBoot() throws {
        let fake = FakeSimslim()
        let plan = try #require(Self.plan([:]))
        let outcome = SimSlim.apply(udid: Self.udid, booted: false, plan: plan, keepState: false, run: fake.runner)
        #expect(outcome.state == .on && outcome.booted)
        #expect(fake.calls == [["on", Self.udid, "--except", "store,icloud"]])
    }

    @Test func bootedDeviceVerifiedSkipsReboot() throws {
        let fake = FakeSimslim()
        let plan = try #require(Self.plan([:]))
        _ = SimSlim.apply(udid: Self.udid, booted: true, plan: plan, keepState: false, run: fake.runner)
        #expect(fake.calls == [["verify", Self.udid, "--except", "store,icloud"], ["on", Self.udid, "--except", "store,icloud", "--no-reboot"]])
    }

    @Test func bootedDeviceOutOfProfileReboots() throws {
        let fake = FakeSimslim()
        fake.answers["verify"] = SimSlim.CommandResult(status: 1, message: "drift")
        let plan = try #require(Self.plan([:]))
        _ = SimSlim.apply(udid: Self.udid, booted: true, plan: plan, keepState: false, run: fake.runner)
        #expect(fake.calls.last == ["on", Self.udid, "--except", "store,icloud"])
        // --keep-state: no reboot.
        let kept = FakeSimslim()
        kept.answers["verify"] = SimSlim.CommandResult(status: 1)
        _ = SimSlim.apply(udid: Self.udid, booted: true, plan: plan, keepState: true, run: kept.runner)
        #expect(kept.calls.last == ["on", Self.udid, "--except", "store,icloud", "--no-reboot"])
    }

    @Test func fallbackWhenMissingOrFailing() throws {
        let plan = try #require(Self.plan(["keep": "nope"]))
        let missing = SimSlim.apply(udid: Self.udid, booted: false, plan: plan, keepState: false, run: nil)
        #expect(missing.state == .unavailable && !missing.booted)
        #expect(missing.warnings == ["slim_unknown_category:nope", "slim_unavailable"])

        let fake = FakeSimslim()
        fake.answers["on"] = SimSlim.CommandResult(status: 1, message: "Booting...\nsimslim: boot timed out")
        let failed = SimSlim.apply(udid: Self.udid, booted: false, plan: plan, keepState: false, run: fake.runner)
        #expect(failed.state == .unavailable && !failed.booted && failed.warnings.last == "slim_failed")
        #expect(failed.log.contains("boot timed out"))
        #expect(SimSlim.measure(udid: Self.udid, run: nil) == nil)
    }

    // MARK: JSON

    @Test func parsesMeasureAndList() {
        #expect(SimSlim.parseMeasure(#"{"processes":80,"bytes":2617565184,"cpu":1.1}"#) == 2_617_565_184)
        #expect(SimSlim.parseMeasure("not json") == nil)
        let fake = FakeSimslim()
        fake.answers["measure"] = SimSlim.CommandResult(status: 0, stdout: #"{"processes":166,"bytes":8078617600,"cpu":667.7}"#)
        #expect(SimSlim.measure(udid: Self.udid, run: fake.runner) == 8_078_617_600)

        let list = Data(#"""
        [{"udid":"a33e342e-4640-4526-a161-2fc68bc8c933","name":"ClaudeDeck · iPhone Duo · 1","state":"Shutdown","managedTotal":173},
         {"udid":"C135A34C-62F5-42B6-9BB5-26283E2CCD74","name":"x","state":"Booted","managedDisabled":109,"managedTotal":173,
          "memory":{"processes":91,"bytes":3147805696,"cpu":8.3}},
         {"udid":"BDCFA972-1AD7-44A7-A9F7-FEBC966F77CA","name":"y","state":"Booted","managedTotal":173,"memory":{"bytes":1}}]
        """#.utf8)
        let map = SimSlim.parseList(list)
        #expect(map[Self.udid]?.text == nil)
        #expect(map["C135A34C-62F5-42B6-9BB5-26283E2CCD74"]?.text == "slim 109/173")
        #expect(map["C135A34C-62F5-42B6-9BB5-26283E2CCD74"]?.memoryBytes == 3_147_805_696)
        #expect(map["BDCFA972-1AD7-44A7-A9F7-FEBC966F77CA"]?.text == "stock")
    }

    @Test func acquireJSONHasSlimFields() throws {
        var item = SessionCLISimulator(udid: Self.udid, name: "ClaudeDeck · Wakeroo · iPhone Duo · 1", runtime: "iOS 27.2", state: "Booted",
                                       holder: nil, holderName: nil, mine: true, created: true, new: false)
        item.slim = SimSlim.State.unavailable.rawValue
        item.slimProfile = "default"
        item.memoryBytes = 42
        let json = try #require(String(data: AgentJSON.encode([item]), encoding: .utf8))
        #expect(json.contains(#""slim":"unavailable""#) && json.contains(#""memory_bytes":42"#) && json.contains(#""slim_profile":"default""#))
        #expect(SimulatorAllocation.acquireText([item]).hasPrefix("\(Self.udid)  ClaudeDeck · Wakeroo · iPhone Duo · 1  slim=unavailable(default)"))
    }

    // MARK: Names and the cap

    @Test func holderNames() {
        #expect(SimulatorAllocation.heldName("ClaudeDeck · iPhone Duo · 4", project: "Wakeroo") == "ClaudeDeck · Wakeroo · iPhone Duo · 4")
        #expect(SimulatorAllocation.heldName("My iPhone", project: "Wakeroo") == nil)
        #expect(SimulatorAllocation.heldName("ClaudeDeck · iPhone Duo · 4", project: nil) == nil)
        #expect(SimulatorAllocation.poolName("ClaudeDeck · Wakeroo · iPhone Duo · 4", type: "iPhone Duo") == "ClaudeDeck · iPhone Duo · 4")
        #expect(SimulatorAllocation.poolName("ClaudeDeck · iPhone Duo · 4", type: "iPhone Duo") == "ClaudeDeck · iPhone Duo · 4")
        #expect(SimulatorAllocation.poolName("ClaudeDeck · iPhone Duo · x", type: "iPhone Duo") == nil)
    }

    @Test func slimRaisesDefaultSimulatorCapOnly() {
        #expect(LoadThresholds.resolve(LoadSettings(), cores: 20).maxSimulators == 4)
        #expect(LoadThresholds.resolve(LoadSettings(), cores: 20, slim: true).maxSimulators == 6)
        var set = LoadSettings()
        set.maxSimulators = 5
        #expect(LoadThresholds.resolve(set, cores: 20, slim: true).maxSimulators == 5)
    }

    @Test func settingDefaultsOn() throws {
        let decoded = try JSONDecoder().decode(DeckSettings.self, from: Data("{}".utf8))
        #expect(decoded.simulatorsSlim)
    }
}
