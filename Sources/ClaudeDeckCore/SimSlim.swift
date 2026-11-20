import Foundation

// `claudedeck sim acquire` slims the simulators it hands out with simslim
// (github.com/MobAI-App/simslim, MIT): it disables background launchd services a simulator does
// not need, which cuts a booted iPhone's memory several times over. The rules are here (which
// categories stay on, which simslim arguments, how a failure falls back to a stock boot); the app
// runs the commands (AppModel+SessionCLISimulators.swift) through an injected runner.
//
// Only simulators ClaudeDeck holds are ever slimmed or restored. The overrides persist in the
// device's launchd overrides, so a released device stays slim and its next acquire is fast.

public enum SimSlim {
    /// Categories every app keeps on unless told otherwise: `store` (StoreKit sandbox, push) and
    /// `icloud` (Keychain, which the device-id login needs). Widgets/Live Activities (`widgets`),
    /// App Intents (`siri`), Screen Time (`family`), … come only from the app's `simslim.json`
    /// or `--keep`.
    public static let defaultExcept = ["store", "icloud"]
    /// The category ids `simslim profiles` lists (simslim 0.15).
    public static let categories: [String] = ["widgets", "siri", "search", "icloud", "store", "pim", "web", "family",
                                              "health", "photos", "apps", "messaging", "connectivity", "telemetry", "mdm", "other"]
    /// The per-app profile at a project's root: `{"name": "...", "except": [...], "keep": [...]}`.
    public static let profileFileName = "simslim.json"
    /// `simslim on` (a slim boot can take a minute; a first boot longer).
    public static let onTimeout: TimeInterval = 420
    public static let shortTimeout: TimeInterval = 60

    /// "on": slimmed; "off": stock on purpose (`--stock` or the setting); "unavailable": simslim
    /// is missing or failed, so the device was booted stock.
    public enum State: String, Codable, Sendable { case on, off, unavailable }

    /// What `sim acquire` asked for.
    public struct Options: Equatable, Sendable {
        public enum Mode: String, Equatable, Sendable {
            /// The profile's (or the default) except list, plus `keep`.
            case slim
            /// `--full-slim` / `--plain`: every category off (pure screen and pixel checks).
            case full
            /// `--stock`: no simslim.
            case stock
        }
        public var mode: Mode
        /// `--keep` / `--keep-cat`: more categories to leave on.
        public var keep: [String]
        /// `--keep-state`: a booted device whose overrides differ is slimmed without a reboot.
        public var keepState: Bool

        public init(mode: Mode = .slim, keep: [String] = [], keepState: Bool = false) {
            self.mode = mode
            self.keep = keep
            self.keepState = keepState
        }

        /// From the request form (`keep`, `full`, `stock`, `keep_state`). `stock` wins over
        /// `full`, which wins over `keep`.
        public init(form: [String: String]) {
            let stock = form["stock"] == "1", full = form["full"] == "1"
            mode = stock ? .stock : full ? .full : .slim
            keep = SimSlim.split(form["keep"] ?? "")
            keepState = form["keep_state"] == "1"
        }
    }

    /// A project's `simslim.json`, validated.
    public struct Profile: Equatable, Sendable {
        public var name: String?
        public var except: [String]
        /// Individual launchd labels kept running (simslim's own `--keep`).
        public var keepDaemons: [String]
        /// The file it came from; nil for the built-in default.
        public var path: String?
        /// Warning codes for `X-ClaudeDeck-Note` (no spaces): `slim_profile_invalid`,
        /// `slim_unknown_category:<id>`.
        public var warnings: [String] = []

        public static let builtIn = Profile(name: nil, except: SimSlim.defaultExcept, keepDaemons: [], path: nil)

        public init(name: String?, except: [String], keepDaemons: [String], path: String?, warnings: [String] = []) {
            self.name = name
            self.except = except
            self.keepDaemons = keepDaemons
            self.path = path
            self.warnings = warnings
        }

        /// "wakeroo (simslim.json)" or "default".
        public var label: String { path == nil ? "default" : (name ?? "simslim.json") }
    }

    /// `<folder>/simslim.json` if there is one; the built-in default otherwise. A file that isn't
    /// valid JSON falls back to the default; unknown categories are dropped. Both warn.
    public static func profile(folder: String?, read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) -> Profile {
        guard let folder, !folder.isEmpty else { return .builtIn }
        let path = (folder as NSString).appendingPathComponent(profileFileName)
        guard let data = read(path) else { return .builtIn }
        struct File: Decodable { let name: String?; let except: [String]?; let keep: [String]? }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            var fallback = Profile.builtIn
            fallback.warnings = ["slim_profile_invalid"]
            return fallback
        }
        var warnings: [String] = []
        var except: [String] = []
        for raw in file.except ?? [] {
            let id = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if categories.contains(id) {
                if !except.contains(id) { except.append(id) }
            } else {
                warnings.append("slim_unknown_category:" + sanitized(id))
            }
        }
        let daemons = (file.keep ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { isLabel($0) }
        return Profile(name: file.name.map(sanitized), except: except, keepDaemons: daemons, path: path, warnings: warnings)
    }

    /// What simslim is asked to apply.
    public struct Plan: Equatable, Sendable {
        /// Categories left on; nil: none (full slim).
        public var except: [String]?
        public var keepDaemons: [String]
        public var warnings: [String]
        /// For the answer: "default", the profile's name, or "full".
        public var profile: String
    }

    /// nil with `--stock`. `--keep` adds to the profile's except list (unknown ids are dropped
    /// with a warning); `--full-slim` ignores the profile.
    public static func plan(_ options: Options, profile: Profile) -> Plan? {
        switch options.mode {
        case .stock:
            return nil
        case .full:
            return Plan(except: nil, keepDaemons: [], warnings: [], profile: "full")
        case .slim:
            var except = profile.except
            var warnings = profile.warnings
            for raw in options.keep {
                let id = raw.lowercased()
                if !categories.contains(id) {
                    warnings.append("slim_unknown_category:" + sanitized(id))
                } else if !except.contains(id) {
                    except.append(id)
                }
            }
            return Plan(except: except, keepDaemons: profile.keepDaemons, warnings: warnings, profile: profile.label)
        }
    }

    /// `simslim on <udid> [--except a,b] [--keep labels] [--no-reboot]`.
    public static func onArguments(udid: String, plan: Plan, noReboot: Bool) -> [String] {
        ["on", udid] + profileArguments(plan) + (noReboot ? ["--no-reboot"] : [])
    }

    /// `simslim verify <udid> …`: exits 0 when the device's overrides match the plan exactly.
    public static func verifyArguments(udid: String, plan: Plan) -> [String] {
        ["verify", udid] + profileArguments(plan)
    }

    public static func offArguments(udid: String, preserveBootState: Bool) -> [String] {
        ["off", udid] + (preserveBootState ? ["--preserve-boot-state"] : [])
    }

    public static func measureArguments(udid: String) -> [String] { ["measure", udid, "--json"] }

    private static func profileArguments(_ plan: Plan) -> [String] {
        var args: [String] = []
        if let except = plan.except, !except.isEmpty { args += ["--except", except.joined(separator: ",")] }
        if !plan.keepDaemons.isEmpty { args += ["--keep", plan.keepDaemons.joined(separator: ",")] }
        return args
    }

    // MARK: Running

    public struct CommandResult: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var message: String
        public init(status: Int32, stdout: String = "", message: String = "") {
            self.status = status
            self.stdout = stdout
            self.message = message
        }
    }

    /// Runs `simslim <args>` with a timeout (the app: SimulatorsController.run; tests: a fake).
    public typealias Runner = @Sendable (_ args: [String], _ timeout: TimeInterval) -> CommandResult

    public struct Outcome: Equatable, Sendable {
        public var state: State
        /// simslim booted (or rebooted) the device; otherwise the caller boots it.
        public var booted: Bool
        /// Warning codes (see Profile.warnings) plus `slim_unavailable` / `slim_failed`.
        public var warnings: [String]
        /// One line for the activity log.
        public var log: String
        public var profile: String?
    }

    /// Slims one held device. `booted`: its state now. Never throws or fails the acquire: a
    /// missing simslim (`run` nil) or a failing one gives `.unavailable` and the caller boots stock.
    public static func apply(udid: String, booted: Bool, plan: Plan?, keepState: Bool, run: Runner?) -> Outcome {
        guard let plan else { return Outcome(state: .off, booted: false, warnings: [], log: "stock (no simslim)", profile: nil) }
        guard let run else {
            return Outcome(state: .unavailable, booted: false, warnings: plan.warnings + ["slim_unavailable"],
                           log: "simslim isn't installed; booting stock", profile: plan.profile)
        }
        var noReboot = false
        if booted {
            // Already slim with this profile: just stop what still runs. Otherwise a reboot, as a
            // stopped-but-booted device keeps far more memory than a slim boot (unless --keep-state).
            let verified = run(verifyArguments(udid: udid, plan: plan), shortTimeout).status == 0
            noReboot = verified || keepState
        }
        let args = onArguments(udid: udid, plan: plan, noReboot: noReboot)
        let result = run(args, onTimeout)
        guard result.status == 0 else {
            let why = (result.message.isEmpty ? result.stdout : result.message)
                .split(separator: "\n").last.map(String.init) ?? "exit \(result.status)"
            return Outcome(state: .unavailable, booted: false, warnings: plan.warnings + ["slim_failed"],
                           log: "simslim \(args.joined(separator: " ")) failed: \(why.prefix(200)); booting stock", profile: plan.profile)
        }
        return Outcome(state: .on, booted: true, warnings: plan.warnings,
                       log: "simslim \(args.joined(separator: " "))", profile: plan.profile)
    }

    /// `simslim measure <udid> --json` → bytes (nil if it fails).
    public static func measure(udid: String, run: Runner?) -> UInt64? {
        guard let run else { return nil }
        let result = run(measureArguments(udid: udid), shortTimeout)
        guard result.status == 0 else { return nil }
        return parseMeasure(result.stdout)
    }

    public static func parseMeasure(_ stdout: String) -> UInt64? {
        struct Output: Decodable { let bytes: UInt64? }
        return (try? JSONDecoder().decode(Output.self, from: Data(stdout.utf8)))?.bytes
    }

    // MARK: Status (simslim list --json)

    /// One device in `simslim list --json`.
    public struct DeviceStatus: Equatable, Sendable, Codable {
        public var disabled: Int?
        public var total: Int?
        public var memoryBytes: UInt64?

        public init(disabled: Int?, total: Int?, memoryBytes: UInt64?) {
            self.disabled = disabled
            self.total = total
            self.memoryBytes = memoryBytes
        }

        /// "slim 109/173", "stock", or nil when unknown (a shut-down device).
        public var text: String? {
            guard let disabled, let total, total > 0 else { return nil }
            return disabled == 0 ? "stock" : "slim \(disabled)/\(total)"
        }
    }

    /// UDID → status, from `simslim list --json`.
    public static func parseList(_ data: Data) -> [String: DeviceStatus] {
        struct Item: Decodable {
            struct Memory: Decodable { let bytes: UInt64? }
            let udid: String
            let managedDisabled: Int?
            let managedTotal: Int?
            let memory: Memory?
        }
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { return [:] }
        var map: [String: DeviceStatus] = [:]
        for item in items {
            // Shut-down devices list managedTotal only; the overrides are read on boot.
            map[item.udid.uppercased()] = DeviceStatus(disabled: item.managedDisabled ?? (item.memory == nil ? nil : 0),
                                                       total: item.managedTotal, memoryBytes: item.memory?.bytes)
        }
        return map
    }

    // MARK: Helpers

    static func split(_ list: String) -> [String] {
        var out: [String] = []
        for part in list.split(whereSeparator: { $0 == "," || $0 == " " }) {
            let id = part.trimmingCharacters(in: .whitespaces).lowercased()
            if !id.isEmpty, !out.contains(id) { out.append(id) }
        }
        return out
    }

    private static func sanitized(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }.prefix(40))
    }

    private static func isLabel(_ text: String) -> Bool {
        !text.isEmpty && text.count < 200 && text.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }
}

// MARK: - Pool names

extension SimulatorAllocation {
    /// "ClaudeDeck · Wakeroo · iPhone Duo · 4" for the plain pool name "ClaudeDeck · iPhone Duo · 4"
    /// held by a session of project Wakeroo; nil when the name isn't a pool name.
    public static func heldName(_ poolName: String, project: String?) -> String? {
        guard poolName.hasPrefix(namePrefix), let project else { return nil }
        let clean = project.replacingOccurrences(of: " · ", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        return namePrefix + clean + " · " + poolName.dropFirst(namePrefix.count)
    }
}
