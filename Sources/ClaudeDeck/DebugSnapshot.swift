import AppKit
import ClaudeDeckCore

/// Development aid: when `CLAUDEDECK_SNAPSHOT_DIR` is set, periodically renders the app's own
/// windows to PNG files there (no screen-recording permission needed).
@MainActor
enum DebugSnapshot {
    static func startIfRequested(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["CLAUDEDECK_SNAPSHOT_DIR"] else { return }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                write(to: dir)
                typePendingInput(from: dir, model: model)
            }
        }
    }

    /// `<dir>/<session-uuid>.in` files are typed into that session's terminal, then deleted;
    /// an empty `<dir>/<session-uuid>.select` selects that session, `.beside` opens it in a new pane,
    /// `<project-uuid>.shell` opens a plain terminal in that project.
    private static func typePendingInput(from dir: String, model: AppModel) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files where file.hasSuffix(".select") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(7))) { model.selectedSessionID = id }
        }
        for file in files where file.hasSuffix(".beside") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(7))) { model.openBeside(id) }
        }
        for file in files where file.hasSuffix(".shell") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let project = UUID(uuidString: String(file.dropLast(6))) { model.newShell(in: project) }
        }
        // Screenshots of things only a scroll or a right click shows (the app need not be in front):
        // `settings.category`: "agents" (a SettingsCategory raw value) opens Settings on that category;
        // `settings.scroll`: "Y" scrolls the Settings window's form to Y points from its top;
        // `rightclick`: "X Y" right-clicks the main window at X, Y points from its top left.
        for file in files where file == "settings.category" {
            let path = (dir as NSString).appendingPathComponent(file)
            let name = contents(path)
            try? FileManager.default.removeItem(atPath: path)
            if SettingsCategory(rawValue: name) != nil { UserDefaults.windowState.set(name, forKey: SettingsCategory.storageKey) }
            // Opens Settings too (already open: just brought forward).
            model.openSettings?()
        }
        // `load.inject`: "overloaded", "busy", "ok", a JSON LoadSample, or "real" (LoadController.inject).
        for file in files where file == "load.inject" {
            let path = (dir as NSString).appendingPathComponent(file)
            let text = contents(path)
            try? FileManager.default.removeItem(atPath: path)
            LoadController.shared.inject(text)
        }
        // `load.tab`: opens the "Mac Yükü" tab.
        for file in files where file == "load.tab" {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
            model.showMacLoad()
        }
        for file in files where file == "settings.scroll" {
            let path = (dir as NSString).appendingPathComponent(file)
            let y = Double(contents(path).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            try? FileManager.default.removeItem(atPath: path)
            // The form is the widest scroll view of the Settings window (the category list is narrower).
            let settings = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
            if let scroll = settings?.contentView.map({ scrollViews(in: $0) })?.max(by: { $0.frame.width < $1.frame.width }) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        for file in files where file == "rightclick" {
            let path = (dir as NSString).appendingPathComponent(file)
            // "X Y PREFIX": the submenu whose item title starts with PREFIX instead of the whole menu.
            let words = contents(path).split(whereSeparator: \.isWhitespace).map(String.init)
            let parts = words.prefix(2).compactMap { Double($0) }
            let submenuPrefix = words.count > 2 ? words[2...].joined(separator: " ") : nil
            try? FileManager.default.removeItem(atPath: path)
            guard parts.count == 2, let window = NSApp.windows.filter({ $0.isVisible }).max(by: { $0.frame.width < $1.frame.width }),
                  let content = window.contentView else { continue }
            let point = NSPoint(x: parts[0], y: content.bounds.height - parts[1])
            // Only the down: the menu stays open (as after a quick click) until something else is clicked.
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                DispatchQueue.main.async {
                    // The view under the point that has a menu for it (SwiftUI's context menus).
                    var view = content.hitTest(point)
                    while let current = view, current.menu(for: event) == nil { view = current.superview }
                    if let view, let menu = view.menu(for: event) {
                        menu.update()
                        let sub = submenuPrefix.flatMap { prefix in menu.items.first { $0.title.hasPrefix(prefix) }?.submenu }
                        NSMenu.popUpContextMenu(sub ?? menu, with: event, for: view)
                    } else {
                        window.sendEvent(event)
                    }
                }
            }
        }
        // `<decision-id>.decide`: answers that decision with the file's text, as a click in Your
        // Decisions does.
        for file in files where file.hasSuffix(".decide") {
            let path = (dir as NSString).appendingPathComponent(file)
            let answer = contents(path)
            try? FileManager.default.removeItem(atPath: path)
            model.answerDecision(String(file.dropLast(7)), answer: answer, from: "mac")
        }
        // `<approval-id>.approve` / `<approval-id>.refuse`: the Approvals card's buttons;
        // `<approval-id>.phone-approve` / `.phone-refuse`: as a phone's answer would come in.
        // The pending ones are written to `approvals.json` (ids, kinds, titles) every tick.
        for file in files where file.hasPrefix("a_") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            let parts = file.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, Approvals.isValidID(parts[0]) else { continue }
            switch parts[1] {
            case "approve": model.answerApproval(parts[0], approve: true, from: "mac")
            case "refuse": model.answerApproval(parts[0], approve: false, from: "mac")
            case "phone-approve": model.answerApproval(parts[0], approve: true, from: "phone")
            case "phone-refuse": model.answerApproval(parts[0], approve: false, from: "phone")
            case "reapprove": model.reapproveApproval(parts[0], from: "mac")
            case "phone-reapprove": model.reapproveApproval(parts[0], from: "phone")
            default: break
            }
        }
        if files.contains("approvals.show") {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent("approvals.show"))
            model.showApprovals()
        }
        if let data = try? JSONEncoder().encode(model.approvals.pending) {
            try? data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("approvals.json")))
        }
        // `<decision-id>.dismiss`: Remove (no answer); `<decision-id>.change`: changes its answer to
        // the file's text; `decisions.size`: the Decisions tab's text size in points.
        for file in files where file.hasSuffix(".dismiss") || file.hasSuffix(".change") || file == "decisions.size" {
            let path = (dir as NSString).appendingPathComponent(file)
            let text = contents(path)
            try? FileManager.default.removeItem(atPath: path)
            if file == "decisions.size" {
                if let size = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    UserDefaults.windowState.set(size, forKey: DecisionsTextSize.key)
                }
            } else if file.hasSuffix(".dismiss") {
                model.dismissDecision(String(file.dropLast(8)), from: "mac")
            } else {
                model.changeDecisionAnswer(String(file.dropLast(7)), answer: text, from: "mac")
            }
        }
        // `agent.add`: "name|webhook URL" adds an agent; `<session-uuid>.ask`: asks every agent
        // about that session (the file's text is the request).
        for file in files where file == "agent.add" {
            let path = (dir as NSString).appendingPathComponent(file)
            let parts = contents(path).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1).map(String.init)
            try? FileManager.default.removeItem(atPath: path)
            if parts.count == 2 { model.mutate { $0.settings.agents.append(AgentProfile(name: parts[0], webhookURL: parts[1])) } }
        }
        // `agentapi.cmd`: "on <port>" / "off" for the agents' local API; its token goes to
        // `agentapi-token.txt` (demo keychain only).
        for file in files where file == "agentapi.cmd" {
            let path = (dir as NSString).appendingPathComponent(file)
            let parts = contents(path).split(separator: " ").map(String.init)
            try? FileManager.default.removeItem(atPath: path)
            model.mutate {
                $0.settings.agentAPIEnabled = parts.first == "on"
                if parts.count > 1, let port = Int(parts[1]) { $0.settings.agentAPIPort = port }
            }
            model.agentAPI.refresh()
            try? (model.agentAPI.token ?? "").write(toFile: (dir as NSString).appendingPathComponent("agentapi-token.txt"), atomically: true, encoding: .utf8)
        }
        // `agent.edit`: "name|key=value" sets async / autoTrigger / canSendDirectly ("true"/"false")
        // or autoProjects (comma-separated project names) on that agent.
        for file in files where file == "agent.edit" {
            let path = (dir as NSString).appendingPathComponent(file)
            let parts = contents(path).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|").map(String.init)
            try? FileManager.default.removeItem(atPath: path)
            guard parts.count == 2, let target = model.agent(named: parts[0]) else { continue }
            let pair = parts[1].split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            model.mutate { deck in
                guard let index = deck.settings.agents.firstIndex(where: { $0.id == target.id }) else { return }
                switch pair[0] {
                case "async": deck.settings.agents[index].async = pair[1] == "true"
                case "autoTrigger": deck.settings.agents[index].autoTrigger = pair[1] == "true"
                case "canSendDirectly": deck.settings.agents[index].canSendDirectly = pair[1] == "true"
                case "autoProjects":
                    let names = pair[1].split(separator: ",").map(String.init)
                    deck.settings.agents[index].autoProjects = deck.projects.filter { names.contains($0.name) }.map(\.id)
                default: break
                }
            }
        }
        for file in files where file.hasSuffix(".ask") {
            let path = (dir as NSString).appendingPathComponent(file)
            let request = contents(path)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(4))) { model.askAgents(model.agents.map(\.id), about: id, request: request) }
        }
        // `<session-uuid>.queue`: puts the file's text in that session's prompt queue.
        for file in files where file.hasSuffix(".queue") {
            let path = (dir as NSString).appendingPathComponent(file)
            let text = contents(path)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(6))) { model.enqueue(id, text: text) }
        }
        // `<session-uuid>.remove`: deletes that session, as its context menu does.
        for file in files where file.hasSuffix(".remove") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(7))) { model.removeSession(id) }
        }
        for file in files where file.hasSuffix(".paste") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.dropLast(6))) { model.terminals.view(for: id)?.paste(NSApp as Any) }
        }
        for file in files where file.hasSuffix(".approve") || file.hasSuffix(".deny") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            let approve = file.hasSuffix(".approve")
            guard let id = UUID(uuidString: String(file.prefix(36))) else { continue }
            let stamp = model.pendingPermissionStamp(id)
            _ = approve ? model.approvePermission(id, expectedAt: stamp) : model.denyPermission(id, expectedAt: stamp)
        }
        // `remote.cmd`: "host" / "client" / "off" turns remote mode on that side (demo testing);
        // `<session-uuid>.remote-approve` / `.remote-deny` answer a prompt on the paired Mac.
        // `remote.addresses`: the host's address order, one per line (empty: automatic).
        for file in files where file == "remote.addresses" {
            let path = (dir as NSString).appendingPathComponent(file)
            let lines = contents(path).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            try? FileManager.default.removeItem(atPath: path)
            model.mutate { $0.settings.remoteAddresses = lines }
            model.remote.applyAddressOrder()
        }
        for file in files where file == "remote.cmd" {
            let path = (dir as NSString).appendingPathComponent(file)
            let command = contents(path).trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: path)
            model.mutate {
                $0.settings.remoteHost = command.hasPrefix("host")
                $0.settings.remoteLAN = command.hasSuffix("+lan")
                $0.settings.remoteClient = command.hasPrefix("client")
            }
            model.remote.refresh()
        }
        let remote = model.remote
        let remoteLines = ["host: \(remote.hostState) remotes=\(remote.connectedRemotes) last=\(remote.lastRemoteAnswer ?? "-") rejected=\(remote.lastRejectedPeer ?? "-")",
                           "client: \(remote.connection) answering=\(remote.answering.count) error=\(remote.answerError ?? "-") uploads=\(remote.uploads)",
                           "terminals: \(remote.terminalStates) counters: \(remote.counters.sorted { $0.key < $1.key })",
                           "lan: \(remote.lanHosts.map(\.name)) via=\(remote.connectedVia ?? "-") agentapi=\(model.agentAPI.state) enabled=\(model.deck.settings.agentAPIEnabled)",
                           "projects: \(remote.hostProjects.map { $0.pinned ? "📌" + $0.name : $0.name }) past=\(remote.hostPastConversations.mapValues(\.count).values.sorted())"]
            + (remote.snapshot?.sessions ?? []).map { "  \($0.id.uuidString) \($0.name) \($0.state.rawValue) stamp=\($0.permissionStamp.map { String($0) } ?? "-")" }
            + model.agentNotes.flatMap { id, notes in notes.map { "  note \(id.uuidString.prefix(8)) \($0.agentName) pending=\($0.pending) reply=\(($0.reply ?? "-").prefix(60)) error=\($0.error ?? "-")" } }
        try? remoteLines.joined(separator: "\n").write(toFile: (dir as NSString).appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        // `<id>.remote-open` opens the paired Mac's session in a tab; `<id>.remote-type` types its
        // contents there ("\\r" = Enter); `screen-<id>.txt` holds each live terminal's visible text.
        for file in files where file.hasSuffix(".remote-open") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.prefix(36))) { model.openRemoteTerminal(id) }
        }
        for file in files where file.hasSuffix(".remote-type") {
            let path = (dir as NSString).appendingPathComponent(file)
            let text = contents(path).replacingOccurrences(of: "\\r", with: "\r")
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.prefix(36))) { model.remote.sendTerminalInput(id, data: Data(text.utf8)) }
        }
        // `remote.start`: a Claude session with this prompt in the paired Mac's first project
        // ("shell:" first: a terminal); `<id>.remote-resume` / `.remote-stop` act on its sessions.
        for file in files where file == "remote.start" {
            let path = (dir as NSString).appendingPathComponent(file)
            let text = contents(path)
            try? FileManager.default.removeItem(atPath: path)
            guard let project = model.remote.hostProjects.first else { continue }
            if text.hasPrefix("shell:") {
                model.remote.startHostShell(in: project.id, command: String(text.dropFirst(6)))
            } else {
                model.remote.startHostSession(in: project.id, prompt: text)
            }
            model.remote.loadHostPastConversations(project.id)
        }
        for file in files where file.hasSuffix(".remote-resume") || file.hasSuffix(".remote-stop") {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
            guard let id = UUID(uuidString: String(file.prefix(36))) else { continue }
            if file.hasSuffix(".remote-resume") { model.remote.resumeHostSession(id) } else { model.remote.stopHostSession(id) }
        }
        // `<id>.remote-files`: the listed paths (one per line) as if dropped on that remote terminal.
        for file in files where file.hasSuffix(".remote-files") {
            let path = (dir as NSString).appendingPathComponent(file)
            let urls = contents(path).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            try? FileManager.default.removeItem(atPath: path)
            if let id = UUID(uuidString: String(file.prefix(36))) { model.remote.pasteFiles(id, files: RemoteUploadReader.files(urls)) }
        }
        // `<project-uuid>.pin`: toggles the project's pin.
        for file in files where file.hasSuffix(".pin") {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
            if let id = UUID(uuidString: String(file.prefix(36))) { model.mutate { $0.updateProject(id) { $0.pinned.toggle() } } }
        }
        // `zoom.in` / `zoom.out`: ⌘+ / ⌘- for the terminals.
        for file in files where file == "zoom.in" || file == "zoom.out" {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
            model.zoomTerminals(by: file == "zoom.in" ? 1 : -1)
        }
        for (id, text) in model.remote.debugScreens() {
            try? text.write(toFile: (dir as NSString).appendingPathComponent("screen-\(id.uuidString).txt"), atomically: true, encoding: .utf8)
        }
        // `remote.password`: sets the remote-mode password (both roles).
        for file in files where file == "remote.password" {
            let path = (dir as NSString).appendingPathComponent(file)
            let password = contents(path).trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: path)
            if !password.isEmpty { model.remote.setPassword(password) }
        }
        for file in files where file.hasSuffix(".remote-approve") || file.hasSuffix(".remote-deny") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            guard let id = UUID(uuidString: String(file.prefix(36))) else { continue }
            model.remote.answer(id, stamp: model.remote.snapshot?.session(id)?.permissionStamp, approve: file.hasSuffix(".remote-approve"))
        }
        // `<name>.tab`: "diff\t<dir>\t<path>\t<staged 0|1>" opens that diff tab (as a Changes click would),
        // "file\t<path>\t<preview 0|1>" an editor tab, "repo\t<dir>\t<history|worktrees>" a repository page,
        // "automations" / "inbox" / "sessions" / "skills" / "simulators" / "dashboard" / "decisions" / "agents" those tabs, "search\t<query>\t<all 0|1>" the Search
        // tab with that query; "close-all" closes every tab but Sessions.
        for file in files where file.hasSuffix(".tab") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let parts = contents(path).components(separatedBy: "\t")
            if parts.count == 4, parts[0] == "diff" {
                model.tabs.open(.diff(repo: parts[1], path: parts[2], staged: parts[3] == "1"), preview: true)
            } else if parts.count == 3, parts[0] == "file" {
                model.tabs.openFile(URL(fileURLWithPath: parts[1]), preview: parts[2] == "1")
            } else if parts.count == 3, parts[0] == "repo", let page = RepositoryPage(rawValue: parts[2]) {
                model.tabs.open(.repository(repo: parts[1], page: page))
            } else if parts == ["automations"] {
                model.tabs.open(.automations)
            } else if parts == ["inbox"] {
                model.tabs.open(.inbox)
            } else if parts == ["skills"] {
                model.showSkills()
            } else if parts == ["simulators"] {
                model.showSimulators()
            } else if parts == ["dashboard"] {
                model.showDashboard()
            } else if parts == ["decisions"] {
                model.showDecisions()
            } else if parts == ["agents"] {
                model.showAgentsOverview()
            } else if parts.count == 2, parts[0] == "agenda", let project = model.deck.projects.first(where: { $0.name == parts[1] }) {
                model.showAgenda(project.id)
            } else if parts.count == 3, parts[0] == "search" {
                model.showHistorySearch()
                HistorySearchController.shared.scope = parts[2] == "1" ? .all : .project
                HistorySearchController.shared.query = parts[1]
            } else if parts == ["sessions"] {
                model.tabs.selectSessions()
            } else if parts == ["close-all"] {
                model.tabs.close(model.tabs.tabs.filter { $0 != .sessions })
            }
        }
        // `<name>.inspector`: "files" / "changes" shows the right panel on that tab, "hide" closes it.
        for file in files where file.hasSuffix(".inspector") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let tab = contents(path)
            UserDefaults.windowState.set(tab != "hide", forKey: "showFiles")
            if let tab = InspectorTab(rawValue: tab) { UserDefaults.windowState.set(tab.rawValue, forKey: "inspectorTab") }
        }
        // `<name>.quickopen`: shows Quick Open with the file's text as the query.
        for file in files where file.hasSuffix(".quickopen") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            ExplorerSheets.quickOpen(model: model, query: contents(path))
        }
        // `<session-uuid>.github` fetches the session's linked issue/PR; `.popover` opens its pane-header popover.
        for file in files where file.hasSuffix(".github") || file.hasSuffix(".popover") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            guard let id = UUID(uuidString: String(file.prefix(36))) else { continue }
            if file.hasSuffix(".github") { Task { await GitHubMonitor.shared.refresh(id) } }
            else { GitHubMonitor.shared.debugPresentRequest = id }
        }
        // `<name>.frame`: "x y w h" (screen points, bottom-left origin) for the main window.
        for file in files where file.hasSuffix(".frame") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let n = contents(path).split(separator: " ").compactMap { Double($0) }
            if n.count == 4 { model.tabs.mainWindow?.setFrame(NSRect(x: n[0], y: n[1], width: n[2], height: n[3]), display: true) }
        }
        // `<name>.scroll`: "x y" (window points, top-left origin) scrolls the scroll view there to its end.
        for file in files where file.hasSuffix(".scroll") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let n = contents(path).split(separator: " ").compactMap { Double($0) }
            guard n.count == 2, let window = model.tabs.mainWindow, let content = window.contentView else { continue }
            let point = NSPoint(x: n[0], y: content.bounds.height - n[1])
            var view = content.hitTest(point)
            while let v = view, !(v is NSScrollView) { view = v.superview }
            guard let scroll = view as? NSScrollView, let doc = scroll.documentView else { continue }
            let end = doc.isFlipped ? max(0, doc.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: end))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // `ptyd.cmd`: "on" / "off-keep" / "off-end" / "restart" for the session helper (no dialogs);
        // `screens.dump`: every session's visible text and status to `screens.txt`.
        // `serverplan.terminal`: "<server id> <name>" opens that ServerPlan server's terminal.
        for file in files where file == "serverplan.terminal" {
            let path = (dir as NSString).appendingPathComponent(file)
            let parts = contents(path).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
            try? FileManager.default.removeItem(atPath: path)
            if parts.count == 2, let id = Int(parts[0]) { model.openServerPlanTerminal(serverID: id, serverName: parts[1], runClaude: false) }
        }
        // `serverplan.clear`: "all" | "deploy <id>" | "server <id>" | "panel" | "action" clears
        // that ServerPlan error as its x / Clear All does; "phone <id>…" as the phone's swipe.
        // `serverplan.dump`: the shown and cleared failures to `serverplan.txt`.
        for file in files where file == "serverplan.clear" || file == "serverplan.dump" {
            let path = (dir as NSString).appendingPathComponent(file)
            let words = contents(path).split(whereSeparator: \.isWhitespace).map(String.init)
            try? FileManager.default.removeItem(atPath: path)
            let controller = ServerPlanController.shared
            if file == "serverplan.dump" {
                let lines = ["shown: " + controller.visibleIssues.map { "\($0.key)=\($0.signature)" }.joined(separator: ", "),
                             "cleared: " + model.deck.dismissedServerIssues.map { "\($0.key)=\($0.signature)" }.joined(separator: ", "),
                             "actionError: \(controller.actionError ?? "-") lastError: \(controller.lastError ?? "-") shownLastError: \(controller.shownLastError ?? "-")",
                             "phone deploys: " + (controller.remoteStatus?.deploys.map { "\($0.id):\($0.status)" }.joined(separator: ", ") ?? "-")]
                try? lines.joined(separator: "\n").write(toFile: (dir as NSString).appendingPathComponent("serverplan.txt"), atomically: true, encoding: .utf8)
                continue
            }
            let id = words.count > 1 ? Int(words[1]) : nil
            switch words.first {
            case "all": controller.clearAll()
            case "deploy": if let id, let deploy = controller.deployments.first(where: { $0.id == id }) { controller.clearDeploy(deploy) }
            case "server": if let id, let server = controller.server(id) { controller.clearServerIssue(server) }
            case "panel": controller.clearPanelError()
            case "action": controller.actionError = nil
            case "phone": controller.clearFromPhone(deploymentIDs: words.dropFirst().compactMap { Int($0) }, all: false)
            default: break
            }
        }
        for file in files where file == "ptyd.cmd" {
            let path = (dir as NSString).appendingPathComponent(file)
            let command = contents(path)
            try? FileManager.default.removeItem(atPath: path)
            Task { @MainActor in
                switch command {
                case "on": await model.ptyd.enable()
                case "off-keep": await model.ptyd.disable(endSessions: false)
                case "off-end": await model.ptyd.disable(endSessions: true)
                case "restart": await model.ptyd.restartHelper()
                default: break
                }
            }
        }
        for file in files where file == "screens.dump" {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
            var out = "helper: \(model.ptyd.state) held: \(model.ptyd.held) readOnly: \(model.terminals.readOnlySessions)\n"
            for session in model.deck.sessions {
                let status = model.status(of: session.id)
                out += "== \(session.id) \(session.name) running=\(model.terminals.isRunning(session.id)) helper=\(model.terminals.isInHelper(session.id)) pid=\(model.terminals.pid(for: session.id)) status=\(status.display) \(status.detail ?? "")\n"
                if let view = model.terminals.view(for: session.id) {
                    let lines = TerminalCapture.screen(of: view, scrollback: 0).lines.map { $0.map(\.text).joined() }
                    out += lines.map { $0.replacingOccurrences(of: "\u{0}", with: " ") }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n") + "\n"
                }
            }
            try? out.write(toFile: (dir as NSString).appendingPathComponent("screens.txt"), atomically: true, encoding: .utf8)
        }
        // `app.activate` brings the app forward (active window chrome, popovers); `app.quit` quits it.
        for file in files where file == "app.activate" || file == "app.quit" {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
            guard file == "app.quit" else { NSApp.activate(); continue }
            // An open sheet (Quick Open) would hold up termination.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
        }
        for file in files where file.hasSuffix(".in") {
            let path = (dir as NSString).appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let id = UUID(uuidString: String(file.dropLast(3))),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            model.terminals.type(text.replacingOccurrences(of: "<ESC>", with: "\u{1b}").replacingOccurrences(of: "<CR>", with: "\r"), into: id)
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func contents(_ path: String) -> String {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Row counts of every table/outline view (glass sidebars don't render into snapshots).
    private static func writeRowCounts(to dir: String) {
        var lines: [String] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView {
                lines.append("\(type(of: t)) rows=\(t.numberOfRows) frame=\(t.frame.integral)")
                // Every row view the table holds: one not at its row's place is drawn as a stale copy.
                for sub in t.subviews.sorted(by: { $0.frame.minY < $1.frame.minY }) where !sub.isHidden && sub.alphaValue > 0 {
                    let row = (sub as? NSTableRowView).map { t.row(for: $0) } ?? -2
                    let expected = row >= 0 ? t.rect(ofRow: row).integral : .zero
                    lines.append("  \(type(of: sub)) row=\(row) frame=\(sub.frame.integral)\(row >= 0 && expected != sub.frame.integral ? " expected=\(expected)" : "")")
                }
            }
            v.subviews.forEach(walk)
        }
        for w in NSApp.windows where w.isVisible { if let c = w.contentView?.superview ?? w.contentView { walk(c) } }
        try? lines.joined(separator: "\n").write(toFile: (dir as NSString).appendingPathComponent("rows.txt"), atomically: true, encoding: .utf8)
    }

    private static func write(to dir: String) {
        writeRowCounts(to: dir)
        let visibility = AppVisibility.shared
        try? "windowsVisible=\(visibility.windowsVisible) screenVisible=\(visibility.screenVisible) \(visibility.state)"
            .write(toFile: (dir as NSString).appendingPathComponent("visibility.txt"), atomically: true, encoding: .utf8)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            // A title like "api · ./dev.sh" would otherwise point into a folder that doesn't exist.
            let name = window.title.isEmpty ? "window-\(i)" : window.title.replacingOccurrences(of: "/", with: "∕")
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}
