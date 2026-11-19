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
        if !gone.isEmpty { saveSimulatorHolds() }
    }

    func saveSimulatorHolds() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(simHolds) else { return }
        try? data.write(to: simHoldsURL, options: .atomic)
    }

    /// What a session holds is free again; devices ClaudeDeck created are shut down (setting).
    func releaseSimulators(of session: UUID, udid: String? = nil, reason: String) {
        guard !simHolds.held(by: session).isEmpty else { return }
        let released = simHolds.release(session: session, udid: udid)
        guard !released.isEmpty else { return }
        saveSimulatorHolds()
        let name = deck.session(session)?.name ?? "a closed session"
        let shutDown = deck.settings.simulatorsShutDownOnRelease ? released.filter(\.created) : []
        for hold in released {
            logAgent(name, inbound: true, "claudedeck sim: released \(hold.name) (\(reason))"
                + (shutDown.contains(hold) ? ", shutting it down" : ""))
        }
        guard !shutDown.isEmpty else { return }
        Task {
            for hold in shutDown {
                // Only if nobody took it in the meantime.
                guard simHolds.holder(of: hold.udid) == nil else { continue }
                _ = await Task.detached { SimulatorsController.xcrun(["simctl", "shutdown", hold.udid], timeout: 60) }.value
            }
            await SimulatorsController.shared.reloadList()
        }
    }

    // MARK: Routes

    func cliSimulators(_ caller: UUID, route: SessionCLI.Route, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        switch route {
        case .simList:
            return await cliSimList(caller, json: json)
        case .simRelease:
            return cliSimRelease(caller, form: form, json: json)
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
        SessionCLISimulator(udid: hold.udid, name: hold.name, runtime: device?.runtime.displayName, state: device?.state ?? "unknown",
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
        return SessionCLI.answer(200, items, text: SimulatorAllocation.listText(items), exit: .ok, json: json)
    }

    private func cliSimRelease(_ caller: UUID, form: [String: String], json: Bool) -> AgentHTTPResponse {
        let udid = (form["udid"] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if !udid.isEmpty {
            guard let holder = simHolds.holder(of: udid) else { return SessionCLI.failure(404, "not_held", exit: .unknown) }
            guard holder == caller else { return SessionCLI.failure(403, "not_yours", exit: .refused) }
        }
        let names = simHolds.held(by: caller).filter { udid.isEmpty || $0.udid == udid }.map(\.udid)
        releaseSimulators(of: caller, udid: udid.isEmpty ? nil : udid, reason: "claudedeck sim release")
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

        var names = catalog.devices.map(\.name)
        var acquired: [SessionCLISimulator] = []
        var failure: String?
        for step in plan {
            var udid: String
            var name: String
            let isNew = step.reuse == nil
            if let device = step.reuse {
                udid = device.udid
                name = device.name
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
            let booted = await Task.detached { () -> SimulatorsController.CommandResult in
                let boot = SimulatorsController.xcrun(["simctl", "boot", device], timeout: 120)
                // "Unable to boot device in current state: Booted" is fine.
                if boot.status != 0, !boot.message.contains("current state: Booted") { return boot }
                return SimulatorsController.xcrun(["simctl", "bootstatus", device, "-b"], timeout: 240)
            }.value
            guard booted.status == 0 else {
                failure = booted.message
                simHolds.release(session: caller, udid: udid)
                saveSimulatorHolds()
                break
            }
            logAgent(callerName, inbound: true, "claudedeck sim acquire · \(name) (\(udid))" + (isNew ? ", created" : ", reused"))
            let runtime = step.reuse?.runtime.displayName ?? step.runtime?.runtime.displayName
            acquired.append(SessionCLISimulator(udid: udid, name: name, runtime: runtime, state: "Booted", holder: caller,
                                                holderName: callerName, mine: true, created: true, new: isNew))
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
        let text = acquired.map { "\($0.udid)  \($0.name)" }.joined(separator: "\n")
        return SessionCLI.answer(200, acquired, text: text, exit: .ok, json: json)
    }
}
