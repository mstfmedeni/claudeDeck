import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

// MARK: - Sampling

/// Reads the process table off the main actor: booted simulators (their `launchd_sim`), their
/// memory and the sessions whose processes reference them. Arguments are cached per process
/// (pid, start time and name: an exec changes the name), so each process is read once.
actor SimulatorSampler {
    struct Sample: Sendable {
        /// UDID → its `launchd_sim` pid.
        var launchdSims: [String: pid_t] = [:]
        var memory: [String: SimulatorMemory] = [:]
        var uses: [String: [SimulatorUsage.Use]] = [:]
    }

    private struct Key: Hashable {
        let pid: pid_t
        let started: Int64
        let name: String
    }

    private var cache: [Key: ProcessArguments?] = [:]
    /// Cache keys used by the current sample; the rest are dropped after it.
    private var used: Set<Key> = []

    func sample(roots: [UUID: pid_t], devices: [Simulator]) -> Sample {
        let table = ProcessTable.current()
        used = []
        var sample = Sample()
        sample.launchdSims = SimulatorProcesses.launchdSims(in: table) { arguments(of: $0, in: table) }
        sample.memory = SimulatorMemory.measureAll(roots: sample.launchdSims, in: table, footprint: SimulatorMemory.footprint(of:))
        sample.uses = SimulatorUsage.link(roots: roots, table: table, devices: devices) { arguments(of: $0, in: table) }
        cache = cache.filter { used.contains($0.key) }
        return sample
    }

    private func arguments(of pid: pid_t, in table: ProcessTable) -> ProcessArguments? {
        guard let entry = table.entry(pid) else { return nil }
        let key = Key(pid: pid, started: entry.started, name: entry.name)
        used.insert(key)
        if let cached = cache[key] { return cached }
        let read = ProcessArguments.of(pid)
        cache[key] = read
        return read
    }
}

// MARK: - Controller

/// The Simulators tab's state. Works only while the tab is on screen: `run` is the view's task,
/// and it waits while no window is visible.
@MainActor
@Observable
final class SimulatorsController {
    static let shared = SimulatorsController()

    /// The last sessions seen using a simulator (kept after their process exits).
    struct LastUse: Equatable {
        var sessions: [UUID]
        var processes: [String]
        var at: Date
    }

    private(set) var devices: [Simulator] = []
    private(set) var loaded = false
    private(set) var listError: String?
    private(set) var memory: [String: SimulatorMemory] = [:]
    /// Uses seen in the latest sample.
    private(set) var uses: [String: [SimulatorUsage.Use]] = [:]
    private(set) var lastUse: [String: LastUse] = [:]
    /// UDID → the action running on it.
    private(set) var busy: [String: String] = [:]
    var actionError: String?
    private(set) var simslimPath: String?
    var filter = ""

    @ObservationIgnored private let sampler = SimulatorSampler()
    @ObservationIgnored private var listedAt: Date?
    @ObservationIgnored private var sampledAt: Date = .distantPast
    static let sampleInterval: Duration = .seconds(3)
    /// The device list is re-read when the booted set changes, after an action, and at most this often otherwise.
    static let listInterval: TimeInterval = 30

    private init() {}

    var booted: [Simulator] { devices.filter { $0.state != "Shutdown" } }
    var totalMemory: UInt64 { booted.compactMap { memory[$0.udid]?.bytes }.reduce(0, +) }

    /// The tab's task: one sample right away, then every few seconds while a window is visible.
    func run(model: AppModel) async {
        if simslimPath == nil { simslimPath = await Task.detached { Self.locateSimslim() }.value }
        await reloadList()
        while !Task.isCancelled {
            await AppVisibility.shared.waitUntilVisible()
            guard !Task.isCancelled else { break }
            await sample(model: model)
            try? await Task.sleep(for: Self.sampleInterval)
        }
    }

    func reloadList() async {
        let result = await Task.detached { Self.xcrun(["simctl", "list", "-j", "devices"], timeout: 30) }.value
        listedAt = Date()
        loaded = true
        guard result.status == 0 else {
            listError = result.message.isEmpty ? String(localized: "xcrun simctl failed. Is Xcode installed?") : result.message
            return
        }
        do {
            devices = try SimulatorList.parse(Data(result.stdout.utf8))
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    /// For a connected phone (RemotePhoneFeeds): the list and a sample, unless the tab sampled
    /// less than `every` ago. Runs whether or not a window is visible (the phone is looking).
    func sampleForRemote(model: AppModel, every: Duration) async {
        if !loaded { await reloadList() }
        guard Date().timeIntervalSince(sampledAt) >= Double(every.components.seconds) - 0.5 else { return }
        await sample(model: model)
    }

    private func sample(model: AppModel) async {
        sampledAt = Date()
        let sample = await sampler.sample(roots: model.sessionProcessRoots(), devices: devices)
        memory = sample.memory
        uses = sample.uses
        let now = Date()
        for (udid, list) in sample.uses {
            var sessions: [UUID] = []
            for use in list where !sessions.contains(use.session) { sessions.append(use.session) }
            lastUse[udid] = LastUse(sessions: sessions, processes: Array(Set(list.map(\.process))).sorted(), at: now)
        }
        // Only listed devices count: a booted tvOS (or unavailable) simulator also runs a launchd_sim
        // and would otherwise re-run simctl on every tick.
        let listed = Set(booted.map(\.udid))
        let known = Set(devices.map(\.udid))
        if Set(sample.launchdSims.keys).intersection(known) != listed || now.timeIntervalSince(listedAt ?? .distantPast) > Self.listInterval {
            await reloadList()
        }
    }

    // MARK: Actions

    func boot(_ device: Simulator) { perform(device, String(localized: "Booting…"), ["simctl", "boot", device.udid]) }
    func shutdown(_ device: Simulator) { perform(device, String(localized: "Shutting down…"), ["simctl", "shutdown", device.udid]) }

    /// Simulator.app with this device in front (it boots the device if needed).
    func open(_ device: Simulator) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device.udid]
        do { try process.run() } catch { actionError = error.localizedDescription }
        Task { try? await Task.sleep(for: .seconds(3)); await reloadList() }
    }

    /// Erases contents and settings after a confirmation; a booted device is shut down first.
    func confirmErase(_ device: Simulator) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Erase “\(device.name)”?")
        alert.informativeText = device.state == "Shutdown"
            ? String(localized: "All apps, data and settings on this simulator are deleted. This can’t be undone.")
            : String(localized: "The simulator is shut down first. All apps, data and settings on it are deleted. This can’t be undone.")
        alert.addButton(withTitle: String(localized: "Erase"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runAsSheet() == .alertFirstButtonReturn else { return }
        let steps: [[String]] = (device.state == "Shutdown" ? [] : [["simctl", "shutdown", device.udid]])
            + [["simctl", "erase", device.udid]]
        lastUse[device.udid] = nil
        perform(device, String(localized: "Erasing…"), steps)
    }

    /// simslim categories kept on in slim mode: push notifications are in `store`, widgets and Live
    /// Activities in `widgets`, WatchConnectivity in `connectivity` (from simslim's README; its
    /// `simslim profiles` command lists the categories).
    static let slimKeptCategories = "widgets,store,connectivity"

    func confirmSlim(_ device: Simulator, on: Bool) {
        guard let simslim = simslimPath else { return }
        let alert = NSAlert()
        alert.messageText = on ? String(localized: "Slim “\(device.name)”?") : String(localized: "Restore “\(device.name)” to stock?")
        alert.informativeText = on
            ? String(localized: "simslim turns off background services the simulator doesn’t need and reboots it. Push notifications, widgets and WatchConnectivity stay on.")
            : String(localized: "simslim turns every service back on and reboots the simulator.")
        alert.addButton(withTitle: on ? String(localized: "Slim") : String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runAsSheet() == .alertFirstButtonReturn else { return }
        let args = on ? ["on", device.udid, "--except", Self.slimKeptCategories] : ["off", device.udid]
        perform(device, on ? String(localized: "Slimming…") : String(localized: "Restoring…"), [args], executable: simslim, timeout: 300)
    }

    private func perform(_ device: Simulator, _ label: String, _ args: [String]) {
        perform(device, label, [args])
    }

    private func perform(_ device: Simulator, _ label: String, _ steps: [[String]], executable: String? = nil, timeout: TimeInterval = 120) {
        guard busy[device.udid] == nil else { return }
        busy[device.udid] = label
        Task {
            for args in steps {
                let result = await Task.detached {
                    executable.map { Self.run($0, args, timeout: timeout) } ?? Self.xcrun(args, timeout: timeout)
                }.value
                // Shutting down a device that is already shut down is fine before an erase.
                if result.status != 0, !(args.dropFirst().first == "shutdown" && steps.count > 1) {
                    actionError = result.message.isEmpty ? String(localized: "The command failed.") : result.message
                    break
                }
            }
            busy[device.udid] = nil
            await reloadList()
        }
    }

    // MARK: Helpers

    struct CommandResult: Sendable {
        var status: Int32
        var stdout: String
        var message: String
    }

    nonisolated static func xcrun(_ args: [String], timeout: TimeInterval) -> CommandResult {
        run("/usr/bin/xcrun", args, timeout: timeout)
    }

    nonisolated static func run(_ executable: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return CommandResult(status: -1, stdout: "", message: error.localizedDescription) }
        let errData = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        group.wait()
        let message = String(decoding: errData.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self), message: message)
    }

    /// simslim (github.com/MobAI-App/simslim) on PATH or in the usual install places.
    nonisolated static func locateSimslim() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/go/bin", "\(home)/.local/bin"] + path
        return dirs.lazy.map { ($0 as NSString).appendingPathComponent("simslim") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private final class OutputBox: @unchecked Sendable { var data = Data() }

extension AppModel {
    /// Each running local terminal's top process (claude or the shell).
    func sessionProcessRoots() -> [UUID: pid_t] {
        var roots: [UUID: pid_t] = [:]
        for session in deck.sessions where terminals.isRunning(session.id) {
            if let pid = terminals.view(for: session.id)?.process.shellPid, pid > 0 { roots[session.id] = pid }
        }
        return roots
    }

    /// The Simulators tab (only while it is turned on in Settings).
    func showSimulators() {
        guard deck.settings.simulators else { return }
        tabs.open(.simulators)
        showMainWindow()
    }
}

// MARK: - Views

struct SimulatorsView: View {
    @Environment(AppModel.self) private var model
    @State private var controller = SimulatorsController.shared

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if !model.deck.settings.simulators {
                ContentUnavailableView("Simulators are turned off", systemImage: "iphone.slash",
                                       description: Text("Turn them on in Settings › Simulators."))
            } else if !controller.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = controller.listError, controller.devices.isEmpty {
                ContentUnavailableView("Couldn’t list simulators", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                list
            }
            Divider()
            footer.padding(.horizontal, 12).padding(.vertical, 6)
        }
        .task(id: model.deck.settings.simulators) {
            guard model.deck.settings.simulators else { return }
            await controller.run(model: model)
        }
        .alert("Simulator", isPresented: Binding(get: { controller.actionError != nil }, set: { if !$0 { controller.actionError = nil } })) {
            Button("OK") { controller.actionError = nil }
        } message: {
            Text(controller.actionError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3").foregroundStyle(.secondary)
            Text("Simulators").font(.headline)
            let booted = controller.booted.count
            Text("\(booted) running").foregroundStyle(.secondary)
            if booted > 0 {
                Text(Self.format(controller.totalMemory))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Memory of all running simulators (sum of their processes’ footprint)")
            }
            Spacer()
            TextField("Filter", text: $controller.filter, prompt: Text("Filter"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Button {
                Task { await controller.reloadList() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload the simulator list")
        }
    }

    private var filtered: [Simulator] {
        let q = controller.filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return controller.devices }
        return controller.devices.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.runtime.displayName.localizedCaseInsensitiveContains(q) || $0.udid.localizedCaseInsensitiveContains(q)
        }
    }

    private var list: some View {
        let devices = filtered
        let running = devices.filter { $0.state != "Shutdown" }
        let stopped = devices.filter { $0.state == "Shutdown" }
        var runtimes: [SimulatorRuntime] = []
        for device in stopped where !runtimes.contains(device.runtime) { runtimes.append(device.runtime) }
        return List {
            Section("Running") {
                if running.isEmpty {
                    Text("No simulator is running.").foregroundStyle(.secondary)
                }
                ForEach(running) { SimulatorRow(device: $0, controller: controller) }
            }
            ForEach(runtimes, id: \.identifier) { runtime in
                Section(runtime.displayName) {
                    ForEach(stopped.filter { $0.runtime == runtime }) { SimulatorRow(device: $0, controller: controller) }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        Text("Memory is the footprint of every process the simulator runs, refreshed while this tab is visible. A session is linked when one of its processes (xcodebuild, simctl, axe, a test runner…) names the simulator by UDID, by an unambiguous name, or as the only booted one; commands that already finished, and apps outside ClaudeDeck, can’t be traced.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private struct SimulatorRow: View {
    @Environment(AppModel.self) private var model
    let device: Simulator
    let controller: SimulatorsController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(device.isBooted ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(device.udid)
            Spacer(minLength: 8)
            usage
            if device.state != "Shutdown" {
                memory.frame(minWidth: 70, alignment: .trailing)
            }
            actions
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy UDID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.udid, forType: .string)
            }
        }
    }

    private var icon: String {
        switch device.platform {
        case .iOS: device.name.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone"
        case .watchOS: "applewatch"
        case .visionOS: "vision.pro"
        }
    }

    private var subtitle: String {
        switch device.state {
        case "Booted", "Shutdown": device.runtime.displayName
        default: "\(device.runtime.displayName) · \(device.state)"
        }
    }

    @ViewBuilder private var memory: some View {
        if let memory = controller.memory[device.udid] {
            Text(SimulatorsView.format(memory.bytes))
                .monospacedDigit()
                .help("\(memory.processes) processes")
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// The sessions using the simulator now, else the last ones seen.
    @ViewBuilder private var usage: some View {
        let now = (controller.uses[device.udid] ?? []).map(\.session)
        let last = controller.lastUse[device.udid]
        if !now.isEmpty {
            sessionLinks(now, help: String(localized: "Used now by \((controller.uses[device.udid] ?? []).map(\.process).joined(separator: ", "))"))
        } else if let last {
            HStack(spacing: 4) {
                Text("Last:").foregroundStyle(.secondary)
                sessionLinks(last.sessions, help: String(localized: "Seen \(last.at.formatted(.relative(presentation: .named))) (\(last.processes.joined(separator: ", ")))"))
            }
        } else if device.isBooted {
            Text("No session found")
                .foregroundStyle(.tertiary)
                .help("None of the sessions’ processes names this simulator right now. It may be used by Xcode, another app, or a command that already finished.")
        }
    }

    private func sessionLinks(_ ids: [UUID], help: String) -> some View {
        var seen: [UUID] = []
        for id in ids where !seen.contains(id) { seen.append(id) }
        return HStack(spacing: 6) {
            ForEach(seen, id: \.self) { id in
                if let session = model.deck.session(id) {
                    Button(session.name) { model.selectedSessionID = id }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .help(help)
                } else {
                    Text("Closed session").foregroundStyle(.secondary).help(help)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var actions: some View {
        if let label = controller.busy[device.udid] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                if device.state == "Shutdown" {
                    Button("Boot") { controller.boot(device) }
                } else {
                    Button("Shut Down") { controller.shutdown(device) }
                }
                Button {
                    controller.open(device)
                } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open in Simulator")
                Menu {
                    Button("Open in Simulator") { controller.open(device) }
                    Button("Copy UDID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(device.udid, forType: .string)
                    }
                    if controller.simslimPath != nil {
                        Divider()
                        Button("Slim (keep push, widgets, Watch)…") { controller.confirmSlim(device, on: true) }
                        Button("Restore Stock Services…") { controller.confirmSlim(device, on: false) }
                    }
                    Divider()
                    Button("Erase…", role: .destructive) { controller.confirmErase(device) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.small)
        }
    }
}

struct OpenSimulatorsButton: View {
    let model: AppModel

    var body: some View {
        if model.deck.settings.simulators {
            Button("Simulators…") { model.showSimulators() }
        }
    }
}

struct SimulatorSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Simulators") {
            Toggle("Show the Simulators tab (File › Simulators…)", isOn: Binding(
                get: { model.deck.settings.simulators },
                set: { on in
                    model.mutate { $0.settings.simulators = on }
                    if !on { model.tabs.close(.simulators) }
                }
            ))
            Text("Lists iOS, watchOS and visionOS simulators with their memory and the sessions using them, with Boot, Shut Down, Open and Erase. Nothing is read while the tab is closed or hidden.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
