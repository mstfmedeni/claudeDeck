import ClaudeDeckCore
import Foundation

/// `claudedeck sim acquire|release|list` (SimulatorAllocation.swift): a session reserves
/// simulators of its own. Needs Settings › Agents › "Sessions may reserve simulators" (off by
/// default). Only devices ClaudeDeck created are reused, shut down or handed out; holds end with
/// `release`, when the session ends or is closed, and are kept across a restart.
extension AppModel {
    private var simHoldsURL: URL { DeckDataStore.default().url.deletingLastPathComponent().appending(path: "simulator-holds.json") }

    func loadSimulatorHolds() {
        if let data = try? Data(contentsOf: simHoldsURL), let book = try? JSONDecoder().decode(SimulatorHoldBook.self, from: data) {
            simHolds = book
        }
        // Holds of sessions that are gone (closed while the app wasn't running).
        let gone = simHolds.prune(sessions: Set(deck.sessions.map(\.id)), devices: nil)
        for hold in gone { logAgent("ClaudeDeck", inbound: false, "claudedeck sim: released \(hold.name) (its session is gone)") }
        // Their plain pool names back.
        if !gone.isEmpty {
            Task.detached(priority: .utility) {
                for hold in gone { _ = SimulatorsController.xcrun(["simctl", "rename", hold.udid, hold.name], timeout: 30) }
            }
        }
        if !gone.isEmpty { saveSimulatorHolds() }
    }

    func saveSimulatorHolds() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(simHolds) else { return }
        try? data.write(to: simHoldsURL, options: .atomic)
    }

    /// What a session holds is free again: each gets its plain pool name back, devices ClaudeDeck
    /// created are shut down (setting). The simslim overrides stay (harmless, and the next acquire
    /// is fast); `unslim` (`sim release --unslim`) restores them to stock with `simslim off`.
    func releaseSimulators(of session: UUID, udid: String? = nil, reason: String, unslim: Bool = false) {
        guard !simHolds.held(by: session).isEmpty else { return }
        let released = simHolds.release(session: session, udid: udid)
        guard !released.isEmpty else { return }
        saveSimulatorHolds()
        let name = deck.session(session)?.name ?? "a closed session"
        let shutDown = deck.settings.simulatorsShutDownOnRelease ? released.filter(\.created) : []
        for hold in released {
            logAgent(name, inbound: true, "claudedeck sim: released \(hold.name) (\(reason))"
                + (unslim ? ", restoring it to stock" : "") + (shutDown.contains(hold) ? ", shutting it down" : ""))
        }
        let runner = unslim ? SimulatorsController.simslimRunner() : nil
        Task {
            for hold in released {
                // Only if nobody took it in the meantime.
                guard simHolds.holder(of: hold.udid) == nil else { continue }
                let off = shutDown.contains(hold)
                let logLine = await Task.detached { () -> String? in
                    // The plain pool name again ("ClaudeDeck · iPhone Duo · 4").
                    _ = SimulatorsController.xcrun(["simctl", "rename", hold.udid, hold.name], timeout: 30)
                    var line: String?
                    if off { _ = SimulatorsController.xcrun(["simctl", "shutdown", hold.udid], timeout: 60) }
                    if let runner {
                        let args = SimSlim.offArguments(udid: hold.udid, preserveBootState: off)
                        let result = runner(args, SimSlim.onTimeout)
                        line = "simslim \(args.joined(separator: " "))" + (result.status == 0 ? "" : " failed: \(result.message.prefix(200))")
                    }
                    return line
                }.value
                if let logLine { logAgent(name, inbound: true, "claudedeck sim release · " + logLine) }
            }
            await SimulatorsController.shared.reloadList()
        }
    }

    /// Every minute: shuts down pool simulators nobody has held for the setting's minutes
    /// (SimulatorIdleShutdown). Only ClaudeDeck's own devices, and never one a session's process
    /// is using.
    func startSimulatorIdleWatch() {
        Task { @MainActor [weak self] in
            var unheldSince: [String: Date] = [:]
            while let self, !Task.isCancelled {
                let minutes = self.deck.settings.simulatorsIdleShutdownMinutes
                let sims = SimulatorsController.shared
                if minutes > 0 {
                    await sims.reloadList()
                    // Fresh `uses` (which session processes use which device).
                    await sims.sampleForRemote(model: self, every: .seconds(50))
                    let booted = sims.booted.filter { $0.state == "Booted" }.map { device in
                        SimulatorIdleShutdown.Device(udid: device.udid, name: device.name,
                                                     held: self.simHolds.holder(of: device.udid) != nil,
                                                     inUse: !(sims.uses[device.udid] ?? []).isEmpty)
                    }
                    let due = SimulatorIdleShutdown.due(booted: booted, unheldSince: &unheldSince, now: Date(), minutes: minutes)
                    for udid in due {
                        let name = booted.first { $0.udid == udid }?.name ?? udid
                        unheldSince[udid] = nil
                        _ = await Task.detached { SimulatorsController.xcrun(["simctl", "shutdown", udid], timeout: 60) }.value
                        self.logAgent("ClaudeDeck", inbound: false, "claudedeck sim: shut down \(name) (nobody held it for \(minutes) min)")
                    }
                    if !due.isEmpty { await sims.reloadList() }
                } else {
                    unheldSince = [:]
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: Routes

    func cliSimulators(_ caller: UUID, route: SessionCLI.Route, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        switch route {
        case .simList:
            return await cliSimList(caller, json: json)
        case .simRelease:
            return cliSimRelease(caller, form: form, json: json)
        case .simPrune:
            return await cliSimPrune(caller, form: form, json: json)
        case .simAcquire:
            guard deck.settings.sessionsMayUseSimulators else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
            // One acquire at a time: each picks among the devices the previous one left.
            let previous = simAcquireChain
            var answer: AgentHTTPResponse?
            let task = Task { @MainActor in
                await previous?.value
                answer = await self.cliSimAcquire(caller, form: form, json: json)
            }
            simAcquireChain = task
            await task.value
            return answer ?? SessionCLI.failure(500, "failed", exit: .failed)
        default:
            return SessionCLI.failure(404, "not_found", exit: .unknown)
        }
    }

    private struct SimCatalog: Sendable {
        var devices: [Simulator]
        var types: [SimulatorDeviceType]
        var runtimes: [SimulatorRuntimeInfo]
    }

    private enum CatalogRead: Sendable {
        case success(SimCatalog)
        case failure(String)
    }

    private nonisolated static func readCatalog() -> CatalogRead {
        let devices = SimulatorsController.xcrun(["simctl", "list", "-j", "devices"], timeout: 30)
        let types = SimulatorsController.xcrun(["simctl", "list", "-j", "devicetypes"], timeout: 30)
        let runtimes = SimulatorsController.xcrun(["simctl", "list", "-j", "runtimes"], timeout: 30)
        guard devices.status == 0, types.status == 0, runtimes.status == 0 else {
            return .failure([devices, types, runtimes].first { $0.status != 0 }?.message ?? "xcrun simctl failed")
        }
        do {
            return .success(SimCatalog(devices: try SimulatorList.parse(Data(devices.stdout.utf8)),
                                       types: try SimulatorAllocation.parseDeviceTypes(Data(types.stdout.utf8)),
                                       runtimes: try SimulatorAllocation.parseRuntimes(Data(runtimes.stdout.utf8))))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func simInfo(_ hold: SimulatorHold, device: Simulator?, caller: UUID, new: Bool? = nil) -> SessionCLISimulator {
        SessionCLISimulator(udid: hold.udid, name: device?.name ?? hold.name, runtime: device?.runtime.displayName, state: device?.state ?? "unknown",
                            holder: hold.session, holderName: deck.session(hold.session)?.name, mine: hold.session == caller,
                            created: hold.created, new: new)
    }

    private func cliSimList(_ caller: UUID, json: Bool) async -> AgentHTTPResponse {
        let devices = await Task.detached { () -> [Simulator] in
            let result = SimulatorsController.xcrun(["simctl", "list", "-j", "devices"], timeout: 30)
            return (try? SimulatorList.parse(Data(result.stdout.utf8))) ?? []
        }.value
        let byUDID = Dictionary(devices.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })
        // Held ones, then the free devices of ClaudeDeck's pool.
        var items = simHolds.holds.map { simInfo($0, device: byUDID[$0.udid], caller: caller) }
        let held = simHolds.heldUDIDs
        for device in devices where !held.contains(device.udid) && (simHolds.created.contains(device.udid) || device.name.hasPrefix(SimulatorAllocation.namePrefix)) {
            items.append(SessionCLISimulator(udid: device.udid, name: device.name, runtime: device.runtime.displayName, state: device.state,
                                             holder: nil, holderName: nil, mine: false, created: true))
        }
        // simslim's view of ClaudeDeck's devices only (read, never changed here).
        let slim = await SimulatorsController.readSlimStatus()
        for index in items.indices {
            guard let status = slim[items[index].udid] else { continue }
            items[index].slimStatus = status.text
            items[index].memoryBytes = status.memoryBytes
        }
        return SessionCLI.answer(200, items, text: SimulatorAllocation.listText(items), exit: .ok, json: json)
    }

    private func cliSimRelease(_ caller: UUID, form: [String: String], json: Bool) -> AgentHTTPResponse {
        let udid = (form["udid"] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if !udid.isEmpty {
            guard let holder = simHolds.holder(of: udid) else { return SessionCLI.failure(404, "not_held", exit: .unknown) }
            guard holder == caller else { return SessionCLI.failure(403, "not_yours", exit: .refused) }
        }
        let names = simHolds.held(by: caller).filter { udid.isEmpty || $0.udid == udid }.map(\.udid)
        releaseSimulators(of: caller, udid: udid.isEmpty ? nil : udid, reason: "claudedeck sim release", unslim: form["unslim"] == "1")
        let text = names.isEmpty ? "nothing to release" : "released " + names.joined(separator: ", ")
        return SessionCLI.answer(200, ["released": names], text: text, exit: .ok, json: json)
    }

    private func cliSimAcquire(_ caller: UUID, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        let wanted = SimulatorAllocation.requested(device: form["device"], duo: form["duo"] == "1")
        guard simHolds.held(by: caller).count + wanted.count <= SimulatorAllocation.maxPerSession else {
            logAgent(callerName, inbound: true, "claudedeck sim acquire: refused (at most \(SimulatorAllocation.maxPerSession) per session)", ok: false)
            return SessionCLI.failure(429, "too_many_simulators", exit: .refused)
        }
        // Settings › Resources: not while the Mac is overloaded or busy holding new work, nor past the cap on booted
        // simulators (counted now, not from the last sample: acquires run one after another).
        if deck.settings.load.throttle {
            await systemLoad.sampleIfStale()
            let booted = await Task.detached(priority: .utility) { SystemLoadSampler.bootedSimulators() }.value
            switch LoadThrottle.simulator(level: systemLoad.level, busyAction: deck.settings.load.busyAction, enabled: true,
                                          booted: booted, wanted: wanted.count,
                                          max: systemLoad.thresholds.maxSimulators) {
            case .allow: break
            case .overloaded:
                logAgent(callerName, inbound: true, "claudedeck sim acquire: refused (the Mac is overloaded)", ok: false)
                return SessionCLI.failure(429, "overloaded", exit: .refused)
            case .busy:
                logAgent(callerName, inbound: true, "claudedeck sim acquire: refused (the Mac is busy: new work waits)", ok: false)
                return SessionCLI.failure(429, "busy", exit: .refused)
            case .tooManyBooted:
                logAgent(callerName, inbound: true, "claudedeck sim acquire: refused (\(booted) simulators booted, at most \(systemLoad.thresholds.maxSimulators))", ok: false)
                return SessionCLI.failure(429, "too_many_booted", exit: .refused)
            }
        }
        let catalog: SimCatalog
        switch await Task.detached(operation: { Self.readCatalog() }).value {
        case .failure(let message):
            logAgent(callerName, inbound: true, "claudedeck sim acquire: simctl failed: \(message)", ok: false)
            return SessionCLI.failure(500, "simctl_failed", exit: .failed)
        case .success(let read): catalog = read
        }
        // Holds of devices that were deleted meanwhile go.
        simHolds.prune(sessions: Set(deck.sessions.map(\.id)), devices: Set(catalog.devices.map(\.udid)))

        // Plan every device first (nothing changes if one type is unknown).
        var plan: [(type: SimulatorDeviceType, reuse: Simulator?, runtime: SimulatorRuntimeInfo?)] = []
        var taken: Set<String> = []
        for name in wanted {
            guard let type = SimulatorAllocation.deviceType(name, in: catalog.types) else {
                return SessionCLI.failure(404, "unknown_device", exit: .unknown)
            }
            if let reuse = SimulatorAllocation.reusable(type, devices: catalog.devices, book: simHolds, excluding: taken) {
                taken.insert(reuse.udid)
                plan.append((type, reuse, nil))
            } else {
                guard let runtime = SimulatorAllocation.runtime(for: type, in: catalog.runtimes) else {
                    return SessionCLI.failure(404, "no_runtime", exit: .unknown)
                }
                plan.append((type, nil, runtime))
            }
        }

        // simslim (SimSlim.swift): the project's simslim.json or the default, plus --keep;
        // --full-slim, --stock and the setting change it. Never fails the acquire.
        // The caller's project (or `--project P`): its simslim.json and the holder name. A session
        // without a project still acquires (default profile, plain name); only a given P must exist.
        var callerProject: Project?
        let projectRef = (form["project"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch SessionCLI.project(projectRef, callerProject: deck.session(caller)?.projectID, projects: deck.projects) {
        case .found(let id): callerProject = deck.project(id)
        case .unknown: if !projectRef.isEmpty { return SessionCLI.failure(404, "unknown_project", exit: .unknown) }
        case .ambiguous: return SessionCLI.failure(400, "ambiguous", exit: .usage)
        }
        var slimOptions = SimSlim.Options(form: form)
        if !deck.settings.simulatorsSlim { slimOptions.mode = .stock }
        let folder = callerProject?.path
        let slimPlan = slimOptions.mode == .slim
            ? await Task.detached { SimSlim.plan(slimOptions, profile: SimSlim.profile(folder: folder)) }.value
            : SimSlim.plan(slimOptions, profile: .builtIn)
        let slimRunner = slimPlan == nil ? nil : SimulatorsController.simslimRunner()
        var notes: [String] = []

        // Plain pool names, including those of held devices that carry their holder's project.
        var names = catalog.devices.map(\.name) + simHolds.holds.map(\.name)
        var acquired: [SessionCLISimulator] = []
        var failure: String?
        for step in plan {
            var udid: String
            var name: String
            let isNew = step.reuse == nil
            if let device = step.reuse {
                udid = device.udid
                // A name left with a project in it (the app quit before it could rename it back).
                name = SimulatorAllocation.poolName(device.name, type: step.type.name) ?? device.name
            } else {
                name = SimulatorAllocation.newName(for: step.type, existing: names)
                names.append(name)
                let args = ["simctl", "create", name, step.type.identifier, step.runtime!.runtime.identifier]
                let created = await Task.detached { SimulatorsController.xcrun(args, timeout: 120) }.value
                guard created.status == 0 else { failure = created.message; break }
                udid = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                simHolds.noteCreated(udid)
            }
            // Held before booting: the next acquire never picks it.
            simHolds.hold(SimulatorHold(udid: udid, name: name, session: caller, created: true))
            saveSimulatorHolds()
            let device = udid
            let wasBooted = step.reuse.map { $0.state != "Shutdown" } ?? false
            // Its holder's project in its name, so Simulator.app and Activity Monitor show whose it is.
            var shownName = name
            if let held = SimulatorAllocation.heldName(name, project: callerProject?.name) {
                let renamed = await Task.detached { SimulatorsController.xcrun(["simctl", "rename", device, held], timeout: 30) }.value
                if renamed.status == 0 { shownName = held }
            }
            // Slim first: a slim boot (shut down) or reboot (booted, profile differs) by simslim itself.
            let keepState = slimOptions.keepState
            let slim = await Task.detached {
                SimSlim.apply(udid: device, booted: wasBooted, plan: slimPlan, keepState: keepState, run: slimRunner)
            }.value
            if slimPlan != nil { logAgent(callerName, inbound: true, "claudedeck sim acquire · \(name): " + slim.log, ok: slim.state == .on) }
            for note in slim.warnings where !notes.contains(note) { notes.append(note) }
            let booted = await Task.detached { () -> SimulatorsController.CommandResult in
                if !slim.booted {
                    let boot = SimulatorsController.xcrun(["simctl", "boot", device], timeout: 120)
                    // "Unable to boot device in current state: Booted" is fine.
                    if boot.status != 0, !boot.message.contains("current state: Booted") { return boot }
                }
                return SimulatorsController.xcrun(["simctl", "bootstatus", device, "-b"], timeout: 240)
            }.value
            guard booted.status == 0 else {
                failure = booted.message
                simHolds.release(session: caller, udid: udid)
                saveSimulatorHolds()
                if shownName != name {
                    let plain = name
                    _ = await Task.detached { SimulatorsController.xcrun(["simctl", "rename", device, plain], timeout: 30) }.value
                }
                break
            }
            // From `simslim measure` whenever simslim is installed (stock devices too).
            let memory = await Task.detached { SimSlim.measure(udid: device, run: slimRunner ?? SimulatorsController.simslimRunner()) }.value
            logAgent(callerName, inbound: true, "claudedeck sim acquire · \(shownName) (\(udid))" + (isNew ? ", created" : ", reused")
                + ", slim \(slim.state.rawValue)" + (memory.map { String(format: ", %.1f GB", Double($0) / 1_073_741_824) } ?? ""))
            let runtime = step.reuse?.runtime.displayName ?? step.runtime?.runtime.displayName
            var item = SessionCLISimulator(udid: udid, name: shownName, runtime: runtime, state: "Booted", holder: caller,
                                           holderName: callerName, mine: true, created: true, new: isNew)
            item.slim = slim.state.rawValue
            item.slimProfile = slim.profile
            item.memoryBytes = memory
            acquired.append(item)
        }
        await SimulatorsController.shared.reloadList()
        if let failure {
            // All or nothing: what this call got goes back.
            for item in acquired { releaseSimulators(of: caller, udid: item.udid, reason: "acquire failed") }
            logAgent(callerName, inbound: true, "claudedeck sim acquire failed: \(failure.prefix(200))", ok: false)
            var response = AgentHTTPResponse.json(500, ["error": "simctl_failed", "message": String(failure.prefix(500))])
            response.headers[SessionCLI.exitHeader] = String(SessionCLI.Exit.failed.rawValue)
            return response
        }
        var response = SessionCLI.answer(200, acquired, text: SimulatorAllocation.acquireText(acquired), exit: .ok, json: json)
        // Warnings for stderr (codes without spaces; the script prints them).
        if !notes.isEmpty { response.headers[Decisions.noteHeader] = notes.joined(separator: ",") }
        return response
    }

    // MARK: Prune (SimulatorPrune.swift)

    /// The automatic prune: a minute after launch, then every 24 hours. Logged only when it
    /// deleted (or failed to delete) something. Never in demo mode.
    func startSimulatorPoolPruning() {
        guard !Self.isDemo, simPruneTask == nil else { return }
        simPruneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                guard let self else { return }
                let days = deck.settings.load.simulatorPruneDays
                _ = await pruneSimulatorPool(dryRun: false, olderThan: days > 0 ? Double(days) * 86_400 : nil,
                                             actor: "ClaudeDeck", automatic: true)
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    /// Deletes ClaudeDeck's unused pool simulators (or, `dryRun`, only lists them). Runs on the
    /// acquire chain, so it never deletes a device an acquire is picking. nil: simctl failed.
    func pruneSimulatorPool(dryRun: Bool, olderThan: TimeInterval?, actor: String, automatic: Bool = false) async -> SimulatorPrune.Answer? {
        let previous = simAcquireChain
        var answer: SimulatorPrune.Answer?
        let task = Task { @MainActor in
            await previous?.value
            answer = await self.runSimulatorPrune(dryRun: dryRun, olderThan: olderThan, actor: actor, automatic: automatic)
        }
        simAcquireChain = task
        await task.value
        return answer
    }

    private func runSimulatorPrune(dryRun: Bool, olderThan: TimeInterval?, actor: String, automatic: Bool) async -> SimulatorPrune.Answer? {
        let read = await Task.detached(priority: .utility) { () -> [Simulator]? in
            let result = SimulatorsController.xcrun(["simctl", "list", "-j", "devices"], timeout: 30)
            guard result.status == 0 else { return nil }
            return try? SimulatorList.parse(Data(result.stdout.utf8))
        }.value
        guard let devices = read else {
            if !automatic { logAgent(actor, inbound: true, "claudedeck sim prune: simctl failed", ok: false) }
            return nil
        }
        // Holds of deleted devices go; pool devices without any date start aging now.
        simHolds.prune(sessions: Set(deck.sessions.map(\.id)), devices: Set(devices.map(\.udid)))
        for udid in SimulatorPrune.undated(devices: devices, book: simHolds) { simHolds.noteUsed(udid) }
        let maxPerType = systemLoad.thresholds.maxSimulators + SimulatorPrune.spare
        let candidates = SimulatorPrune.select(devices: devices, book: simHolds, now: Date(),
                                               olderThan: olderThan, maxPerType: maxPerType)
        var items: [SimulatorPrune.Item] = []
        for candidate in candidates {
            guard !dryRun else { items.append(SimulatorPrune.Item(candidate, deleted: false)); continue }
            // Taken meanwhile, or booted since the list was read (Simulator.app): kept.
            guard simHolds.holder(of: candidate.device.udid) == nil else { continue }
            let udid = candidate.device.udid
            guard await !Task.detached(priority: .utility, operation: { SimulatorsController.isBootedNow(udid) }).value else { continue }
            let result = await Task.detached(priority: .utility) { SimulatorsController.xcrun(["simctl", "delete", udid], timeout: 120) }.value
            if result.status == 0 {
                simHolds.forget(udid)
                items.append(SimulatorPrune.Item(candidate, deleted: true))
            } else {
                items.append(SimulatorPrune.Item(candidate, deleted: false, error: String(result.message.prefix(200))))
            }
        }
        saveSimulatorHolds()
        let answer = SimulatorPrune.Answer(dryRun: dryRun, olderThanSeconds: olderThan, maxPerType: maxPerType, items: items)
        if !dryRun, !items.isEmpty {
            for item in items {
                logAgent(actor, inbound: !automatic, "claudedeck sim prune" + (automatic ? " (automatic)" : "") + ": "
                    + (item.deleted ? "deleted" : "couldn't delete") + " \(item.name) (\(item.udid), \(item.reason.rawValue))"
                    + (item.error.map { ": \($0)" } ?? ""), ok: item.deleted)
            }
            await SimulatorsController.shared.reloadList()
        } else if !automatic {
            logAgent(actor, inbound: true, "claudedeck sim prune" + (dryRun ? " --dry-run" : "") + ": "
                + (items.isEmpty ? "nothing to delete" : "\(items.count) would be deleted"))
        }
        return answer
    }

    private func cliSimPrune(_ caller: UUID, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard deck.settings.sessionsMayUseSimulators else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        let dryRun = form["dry_run"] == "1"
        var olderThan: TimeInterval?
        let given = (form["older_than"] ?? "").trimmingCharacters(in: .whitespaces)
        if !given.isEmpty {
            guard let age = SimulatorPrune.parseAge(given) else { return SessionCLI.failure(400, "bad_age", exit: .usage) }
            olderThan = age
        } else if deck.settings.load.simulatorPruneDays > 0 {
            olderThan = Double(deck.settings.load.simulatorPruneDays) * 86_400
        }
        let name = deck.session(caller)?.name ?? "claudedeck"
        guard let answer = await pruneSimulatorPool(dryRun: dryRun, olderThan: olderThan, actor: name) else {
            return SessionCLI.failure(500, "simctl_failed", exit: .failed)
        }
        return SessionCLI.answer(200, answer, text: SimulatorPrune.text(answer), exit: .ok, json: json)
    }
}
