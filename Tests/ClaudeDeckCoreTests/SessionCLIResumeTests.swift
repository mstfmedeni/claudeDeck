import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck resume` and the automatic resume: ownership, the cap and the start queue, who may
/// be resumed automatically, and the removed sessions' tombstones.
@Suite struct SessionCLIResumeTests {
    // MARK: Ownership

    @Test func resumeFollowsTheCloseChain() {
        let me = UUID(), child = UUID(), grandchild = UUID(), sibling = UUID(), parent = UUID(), owners = UUID()
        let startedBy = [child: me, grandchild: child, sibling: parent, me: parent]
        func check(_ target: UUID, kind: SessionKind = .claude, running: Bool = false, resumable: Bool = true,
                   setting: Bool = true) -> SessionCLI.ResumeCheck {
            SessionCLI.mayResume(caller: me, target: target, targetKind: kind, running: running, resumable: resumable,
                                 startedBy: startedBy, settingOn: setting)
        }
        #expect(check(child) == .allowed)
        #expect(check(grandchild) == .allowed)
        #expect(check(sibling) == .notYours)
        #expect(check(parent) == .notYours)
        #expect(check(owners) == .notYours)
        // Itself: running by definition.
        #expect(check(me) == .running)
        #expect(check(child, running: true) == .running)
        #expect(check(child, resumable: false) == .notResumable)
        #expect(check(child, kind: .shell) == .notClaude)
        // The setting comes first; ownership before state (nothing leaks about others' sessions).
        #expect(check(child, setting: false) == .settingOff)
        #expect(check(owners, running: true) == .notYours)
        // A terminal one of mine opened is mine too (`openedBy`), but not a Claude session.
        let terminal = UUID()
        #expect(SessionCLI.mayResume(caller: me, target: terminal, targetKind: .shell, running: false, resumable: true,
                                     startedBy: startedBy, openedBy: [terminal: child], settingOn: true) == .notClaude)
    }

    @Test func resumeRefusalsAreTheDocumentedOnes() throws {
        func code(_ check: SessionCLI.ResumeCheck) throws -> (Int, String?, String?) {
            let response = try #require(check.response)
            return (response.status, SessionCLI.errorCode(of: response), response.headers[SessionCLI.exitHeader])
        }
        #expect(SessionCLI.ResumeCheck.allowed.response == nil)
        #expect(try code(.settingOff) == (403, "setting_off", "4"))
        #expect(try code(.notYours) == (403, "not_yours", "4"))
        #expect(try code(.notClaude) == (400, "not_claude", "2"))
        #expect(try code(.running) == (409, "running", "1"))
        #expect(try code(.notResumable) == (409, "not_resumable", "1"))
    }

    // MARK: Cap and queue

    @Test func admissionLikeNew() {
        // Load first: overloaded refuses, or queues with --queue (and always for automatic resumes).
        #expect(SessionCLI.admission(load: .refuse, heldBy: "overloaded", startRefusal: nil, queue: false) == .refuse("overloaded"))
        #expect(SessionCLI.admission(load: .queue, heldBy: "busy", startRefusal: "too_many_running", queue: true) == .queue("busy"))
        // Then the cap and the rate limit.
        #expect(SessionCLI.admission(load: .allow, heldBy: "overloaded", startRefusal: nil, queue: false) == .now)
        #expect(SessionCLI.admission(load: .allow, heldBy: "overloaded", startRefusal: "too_many_running", queue: false) == .refuse("too_many_running"))
        #expect(SessionCLI.admission(load: .allow, heldBy: "overloaded", startRefusal: "too_many_running", queue: true) == .queue("too_many_running"))
        #expect(SessionCLI.admission(load: .allow, heldBy: "overloaded", startRefusal: "too_many_starts", queue: true) == .queue("too_many_starts"))
        #expect(SessionCLI.admission(load: .allow, heldBy: "overloaded", startRefusal: nil, queue: true) == .now)
    }

    @Test func capAndRateLimitCountResumesLikeNew() {
        var book = SessionCLIBook()
        let caller = UUID()
        #expect(SessionCLI.admitStart(caller: caller, runningStarted: 8, cap: 8, book: &book).flatMap(SessionCLI.errorCode) == "too_many_running")
        for _ in 0..<5 { #expect(SessionCLI.admitStart(caller: caller, runningStarted: 0, cap: 8, book: &book) == nil) }
        #expect(SessionCLI.admitStart(caller: caller, runningStarted: 0, cap: 8, book: &book).flatMap(SessionCLI.errorCode) == "too_many_starts")
    }

    @Test func resumeEntriesInTheStartQueue() throws {
        let target = UUID()
        var entry = CLIQueuedStart(id: SessionCLI.newQueueID(), caller: UUID(), callerName: "lead", projectID: UUID(), name: "worker",
                                   prompt: "go on", worktree: "", skill: nil, options: ClaudeLaunchOptions())
        entry.resumeSessionID = target
        entry.auto = true
        let decoded = try JSONDecoder().decode(CLIQueuedStart.self, from: JSONEncoder().encode(entry))
        #expect(decoded.resumeSessionID == target && decoded.auto == true)
        // Entries written before resume existed still decode (a `new`).
        var plain = entry
        plain.resumeSessionID = nil
        plain.auto = nil
        let old = try JSONDecoder().decode(CLIQueuedStart.self, from: JSONEncoder().encode(plain))
        #expect(old.resumeSessionID == nil && old.auto == nil)
        // `queue list` tells them apart.
        let info = SessionCLIQueueInfo(entry, project: "web", mine: true, position: 1)
        #expect(info.kind == "resume")
        #expect(SessionCLIQueueInfo(old, project: "web", mine: true, position: 1).kind == "new")
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        #expect(object["kind"] as? String == "resume")
        // They share the queue's limits.
        let queue = Array(repeating: entry, count: SessionCLI.maxQueuedPerCaller)
        #expect(SessionCLI.admitQueued(caller: entry.caller, queue: queue) != nil)
    }

    // MARK: Automatic resume

    @Test func autoResumeOnlyForSessionsASessionClosed() {
        func check(enabled: Bool = true, kind: SessionKind = .claude, running: Bool = false, stoppedBy: SessionStopper? = .agent,
                   resumable: Bool = true) -> SessionCLI.AutoResumeCheck {
            SessionCLI.autoResume(enabled: enabled, kind: kind, running: running, stoppedBy: stoppedBy, resumable: resumable)
        }
        #expect(check() == .resume)
        #expect(check(enabled: false) == .off)
        #expect(check(kind: .shell) == .notClaude)
        #expect(check(running: true) == .running)
        // The owner's stops stay stopped, and so do sessions that ended by themselves.
        #expect(check(stoppedBy: .owner) == .notAgentClosed)
        #expect(check(stoppedBy: nil) == .notAgentClosed)
        #expect(check(resumable: false) == .notResumable)
        #expect(SessionCLI.AutoResumeCheck.notAgentClosed.rawValue == "not_agent_closed")
    }

    @Test func sendResumesOnlyWhatTheCallerMayResume() {
        let me = UUID(), child = UUID(), other = UUID()
        let startedBy = [child: me]
        #expect(SessionCLI.sendMayResume(caller: me, callerOpenedBy: nil, target: child, startedBy: startedBy, startSetting: true))
        #expect(!SessionCLI.sendMayResume(caller: me, callerOpenedBy: nil, target: child, startedBy: startedBy, startSetting: false))
        #expect(!SessionCLI.sendMayResume(caller: me, callerOpenedBy: nil, target: other, startedBy: startedBy, startSetting: true))
        #expect(!SessionCLI.sendMayResume(caller: me, callerOpenedBy: nil, target: me, startedBy: startedBy, startSetting: true))
        // A terminal a session opened has no `start` scope.
        let terminal = UUID()
        #expect(!SessionCLI.sendMayResume(caller: terminal, callerOpenedBy: me, target: child, startedBy: [child: terminal], startSetting: true))
    }

    @Test func autoResumeSettingIsOnByDefaultAndOldFilesDecode() throws {
        #expect(DeckSettings().autoResumeOnDelivery)
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"sessionCLIEnabled":true}"#.utf8))
        #expect(old.autoResumeOnDelivery)
        var off = DeckSettings()
        off.autoResumeOnDelivery = false
        #expect(!(try JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(off))).autoResumeOnDelivery)
    }

    @Test func whoStoppedItIsKept() throws {
        var session = DeckSession(projectID: UUID(), name: "worker")
        #expect(session.stoppedBy == nil)
        session.stoppedBy = .agent
        let decoded = try JSONDecoder().decode(DeckSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.stoppedBy == .agent)
        // Unknown values (a newer version) read as nil, never failing the deck.
        let data = try JSONEncoder().encode(session)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["stoppedBy"] = "martian"
        let odd = try JSONDecoder().decode(DeckSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(odd.stoppedBy == nil)
    }

    // MARK: Tombstones

    private func deck(transcriptExists: Bool = true) -> (DeckData, Project, DeckSession) {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/resume-tests-project")
        var session = deck.addSession(to: project.id, name: "worker")!
        deck.updateSession(session.id) {
            $0.claudeSessionID = "abc-123"
            $0.transcriptPath = "/tmp/transcripts/abc-123.jsonl"
            $0.startedBy = UUID()
            $0.launchOptions = ClaudeLaunchOptions(permissionMode: "acceptEdits")
            $0.account = "work"
            $0.stoppedBy = .agent
            $0.queue = [QueuedPrompt(text: "old")]
        }
        session = deck.session(session.id)!
        return (deck, project, session)
    }

    @Test func tombstoneKeepsWhatResumeNeeds() throws {
        var (deck, _, session) = deck()
        deck.addTombstone(for: session.id)
        deck.removeSession(session.id)
        let tombstone = try #require(deck.tombstone(session.id))
        #expect(tombstone.claudeSessionID == "abc-123" && tombstone.startedBy == session.startedBy
                && tombstone.launchOptions == session.launchOptions && tombstone.account == "work" && tombstone.stoppedBy == .agent)
        #expect(deck.tombstoneResumable(session.id, fileExists: { _ in true }))
        #expect(!deck.tombstoneResumable(session.id, fileExists: { _ in false }))
        // It survives a save.
        let saved = try JSONDecoder().decode(DeckData.self, from: JSONEncoder().encode(deck))
        #expect(saved.removedSessions == deck.removedSessions)
        // Restoring puts the same id back, stopped, and drops the tombstone.
        let back = deck.restoreTombstone(session.id)
        let restored = try #require(back)
        #expect(restored.id == session.id && restored.claudeSessionID == "abc-123" && !restored.isOpen && restored.kind == .claude)
        #expect(restored.startedBy == session.startedBy && restored.launchOptions == session.launchOptions)
        #expect(deck.session(session.id) != nil && deck.tombstone(session.id) == nil)
        let again = deck.restoreTombstone(session.id)
        #expect(again == nil)
    }

    @Test func noTombstoneWithoutAConversation() {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/resume-tests-project")
        let fresh = deck.addSession(to: project.id, name: "never ran")!
        let shell = deck.addSession(to: project.id, kind: .shell)!
        deck.addTombstone(for: fresh.id)
        deck.addTombstone(for: shell.id)
        #expect(deck.removedSessions.isEmpty)
    }

    @Test func tombstoneNeedsItsProject() {
        var (deck, project, session) = deck()
        deck.addTombstone(for: session.id)
        deck.removeSession(session.id)
        deck.removeProject(project.id)
        #expect(!deck.tombstoneResumable(session.id, fileExists: { _ in true }))
        let back = deck.restoreTombstone(session.id)
        #expect(back == nil)
    }

    @Test func tombstonesArePrunedAfterThirtyDays() throws {
        let (deck, _, session) = deck()
        let now = Date()
        var old = try #require(SessionTombstone(session, removedAt: now.addingTimeInterval(-31 * 24 * 3600)))
        old.id = UUID()
        let recent = try #require(SessionTombstone(session, removedAt: now.addingTimeInterval(-29 * 24 * 3600)))
        #expect(SessionCLI.pruneTombstones([old, recent], now: now) == [recent])
        // At most `maxTombstones`, the newest.
        let many = (0..<(SessionCLI.maxTombstones + 5)).map { index -> SessionTombstone in
            var tombstone = recent
            tombstone.id = UUID()
            tombstone.removedAt = now.addingTimeInterval(-Double(index))
            return tombstone
        }
        let pruned = SessionCLI.pruneTombstones(many, now: now)
        #expect(pruned.count == SessionCLI.maxTombstones)
        #expect(pruned.allSatisfy { now.timeIntervalSince($0.removedAt) < Double(SessionCLI.maxTombstones) })
        _ = deck
    }

    @Test func removedStartersHandTheirTombstonesOn() throws {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/resume-tests-project")
        let lead = deck.addSession(to: project.id, name: "lead")!
        let middle = deck.addSession(to: project.id, name: "middle")!
        let worker = deck.addSession(to: project.id, name: "worker")!
        deck.updateSession(middle.id) { $0.startedBy = lead.id }
        deck.updateSession(worker.id) { $0.startedBy = middle.id; $0.claudeSessionID = "w-1" }
        deck.addTombstone(for: worker.id)
        deck.removeSession(worker.id)
        // The middle one goes too: its removed worker now counts as the lead's.
        deck.handOverStartedSessions(of: middle.id)
        deck.removeSession(middle.id)
        #expect(deck.tombstone(worker.id)?.startedBy == lead.id)
    }
}
