import Foundation
import Testing
@testable import ClaudeDeckCore

/// The owner approval queue (Approvals.swift) and its remote encoding (RemoteProtocol.swift).
@Suite struct ApprovalsTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func approval(_ id: String, kind: OwnerApproval.Kind = .serverPlan, created: TimeInterval = 0,
                  expires: TimeInterval = 24 * 3600) -> OwnerApproval {
        OwnerApproval(id: id, kind: kind, title: "s wants \(id)", summary: "summary", command: "container stop", target: "web",
                      sessionID: UUID(), session: "s", project: "p",
                      createdAt: Self.t0.addingTimeInterval(created), expiresAt: Self.t0.addingTimeInterval(expires))
    }

    // MARK: Book

    @Test func orderingSoonestExpiryFirst() {
        var book = ApprovalBook()
        do { let added = book.add(approval("a_2", created: 10, expires: 130)); #expect(added) }
        do { let added = book.add(approval("a_1", created: 0, expires: 120)); #expect(added) }
        do { let added = book.add(approval("a_3", created: 5, expires: 300)); #expect(added) }
        // Same expiry: the older first.
        do { let added = book.add(approval("a_0", created: -5, expires: 130)); #expect(added) }
        #expect(book.pending.map(\.id) == ["a_1", "a_0", "a_2", "a_3"])
        do { let added = book.add(approval("a_1")); #expect(!added) }   // taken id
    }

    @Test func fullBookRefusesMore() {
        var book = ApprovalBook()
        for i in 0..<Approvals.maxPending { let added = book.add(approval("a_\(i)")); #expect(added) }
        do { let added = book.add(approval("a_x")); #expect(!added) }
        #expect(book.pending.count == Approvals.maxPending)
    }

    @Test func resolveOnceAndRecent() {
        var book = ApprovalBook()
        book.add(approval("a_1"))
        book.add(approval("a_2"))
        let first = book.resolve("a_1", .approved, from: "mac", at: Self.t0)
        #expect(first?.outcome == .approved)
        do { let again = book.resolve("a_1", .refused, from: "mac", at: Self.t0); #expect(again == nil) }
        _ = book.resolve("a_2", .expired, from: "timeout", at: Self.t0)
        #expect(book.pending.isEmpty)
        #expect(book.recent.map(\.id) == ["a_2", "a_1"])
        #expect(book.recent[1].outcome == .approved)
    }

    @Test func dueAtTime() {
        var book = ApprovalBook()
        book.add(approval("a_1", expires: 120))
        book.add(approval("a_2", expires: 200))
        #expect(book.due(at: Self.t0.addingTimeInterval(119)).isEmpty)
        #expect(book.due(at: Self.t0.addingTimeInterval(120)) == ["a_1"])
        #expect(Set(book.due(at: Self.t0.addingTimeInterval(500))) == ["a_1", "a_2"])
    }

    @Test func ids() {
        let id = Approvals.newID()
        #expect(Approvals.isValidID(id))
        #expect(!Approvals.isValidID("d_123"))
        #expect(!Approvals.isValidID("a_"))
        #expect(!Approvals.isValidID("a_../x"))
    }

    @Test func phoneMayAnswerWhatTheMacAllows() {
        let buy = OwnerApproval(id: "a_1", kind: .domainPurchase, title: "", summary: "", command: "domain-buy", target: "x.com",
                                sessionID: nil, session: "", project: "", createdAt: Self.t0, expiresAt: Self.t0,
                                phoneMayApprove: true, phoneMayRefuse: true)
        #expect(buy.phoneMayApprove && buy.phoneMayRefuse)
        let gate = approval("a_2")
        #expect(!gate.phoneMayApprove && gate.phoneMayRefuse)
    }

    // MARK: Queue (continuations)

    @MainActor @Test func approveResumesTheWaiterOnce() async {
        let queue = ApprovalQueue(now: { Self.t0 })
        var changes: [String] = []
        queue.observe { change in
            switch change {
            case .added(let a): changes.append("+\(a.id)")
            case .resolved(let r): changes.append("\(r.outcome.rawValue):\(r.id)")
            case .updated: break
            }
        }
        let waiter = Task { await queue.request(approval("a_1")) }
        while queue.pendingCount == 0 { await Task.yield() }
        #expect(queue.resolve("a_1", .approved, from: "mac") != nil)
        // Later answers find nothing: a second resume would trap.
        #expect(queue.resolve("a_1", .refused, from: "mac") == nil)
        queue.expireDue()
        #expect(await waiter.value == .approved)
        #expect(changes == ["+a_1", "approved:a_1"])
        #expect(queue.pending.isEmpty)
    }

    @MainActor @Test func refuseResolvesFalse() async {
        let queue = ApprovalQueue(now: { Self.t0 })
        let waiter = Task { await queue.request(approval("a_1")) }
        while queue.pendingCount == 0 { await Task.yield() }
        queue.resolve("a_1", .refused, from: "phone")
        let outcome = await waiter.value
        #expect(outcome == .refused && !outcome.isApproved)
        #expect(queue.book.recent.first?.from == "phone")
    }

    @MainActor @Test func expiresAsRefusedOnTheClock() async {
        var now = Self.t0
        let queue = ApprovalQueue(now: { now })
        let waiter = Task { await queue.request(approval("a_1", expires: 120)) }
        while queue.pendingCount == 0 { await Task.yield() }
        now = Self.t0.addingTimeInterval(60)
        queue.expireDue()
        #expect(queue.pendingCount == 1)
        now = Self.t0.addingTimeInterval(121)
        queue.expireDue()
        #expect(await waiter.value == .expired)
        #expect(queue.resolve("a_1", .approved, from: "mac") == nil)   // too late
    }

    @MainActor @Test func expiryTimerFires() async {
        let queue = ApprovalQueue()
        let soon = OwnerApproval(id: "a_t", kind: .serverPlan, title: "", summary: "", command: "c", target: "t", sessionID: nil,
                                 session: "", project: "", createdAt: Date(), expiresAt: Date().addingTimeInterval(0.2))
        let outcome = await queue.request(soon)
        #expect(outcome == .expired)
        #expect(queue.book.recent.first?.from == "timeout")
    }

    /// The asking request going away doesn't end an approval (the call behind it goes on in the
    /// app); only the asking session's `approval cancel` does.
    @MainActor @Test func cancelledCallerKeepsWaitingUntilWithdrawn() async {
        let queue = ApprovalQueue(now: { Self.t0 })
        let waiter = Task { await queue.request(approval("a_1")) }
        while queue.pendingCount == 0 { await Task.yield() }
        waiter.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(queue.pendingCount == 1 && queue.hasWaiter("a_1"))
        #expect(queue.cancel("a_1")?.from == "agent")
        #expect(await waiter.value == .cancelled)
        #expect(queue.pending.isEmpty)
    }

    /// Deferred: the call waits apart from the request that started it, so an answer hours later
    /// still reaches it.
    @MainActor @Test func lateAnswerReachesTheCall() async {
        var now = Self.t0
        let queue = ApprovalQueue(now: { now })
        let job = Task { @MainActor in await queue.request(approval("a_1", expires: 4 * 3600)) }
        while queue.pendingCount == 0 { await Task.yield() }
        now = Self.t0.addingTimeInterval(3 * 3600)
        queue.expireDue()
        #expect(queue.pendingCount == 1)
        queue.resolve("a_1", .approved, from: "phone")
        #expect(await job.value == .approved)
    }

    @MainActor @Test func immediateRefusals() async {
        let queue = ApprovalQueue(now: { Self.t0 })
        // Already expired.
        #expect(await queue.request(approval("a_old", expires: -1)) == .refused)
        #expect(queue.pending.isEmpty)
    }

    // MARK: Remote

    @Test func snapshotCarriesApprovals() throws {
        var snapshot = RemoteSnapshot(hostName: "Mac", sessions: [])
        snapshot.features = RemoteSnapshot.Feature.all
        snapshot.approvals = [approval("a_1"), approval("a_2", kind: .domainPurchase)]
        let data = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(RemoteSnapshot.self, from: data)
        #expect(back.approvals == snapshot.approvals)
        #expect(back.supports(RemoteSnapshot.Feature.approvals))
        // An older phone (no `approvals` key in its model) still decodes the snapshot.
        struct OldSnapshot: Decodable { var hostName: String; var sessions: [RemoteSession] }
        #expect(try JSONDecoder().decode(OldSnapshot.self, from: data).hostName == "Mac")
        // A snapshot from an older Mac has none.
        var plain = RemoteSnapshot(hostName: "Mac", sessions: [])
        plain.features = ["decisions"]
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: try JSONEncoder().encode(plain))
        #expect(old.approvals == nil && !old.supports(RemoteSnapshot.Feature.approvals))
    }

    @Test func unknownKindReadsAsOther() throws {
        var json = String(data: try JSONEncoder().encode(approval("a_1")), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"serverPlan\"", with: "\"somethingNew\"")
        let decoded = try JSONDecoder().decode(OwnerApproval.self, from: Data(json.utf8))
        #expect(decoded.kind == .other)
    }

    @Test func answerOnTheWire() throws {
        let frame = try RemoteMessage.answerApproval(id: "a_00ff", approve: false).frame()
        #expect(try RemoteMessage.decode(frame) == .answerApproval(id: "a_00ff", approve: false))
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.approvals))
    }

    // MARK: Wait setting, persistence, wire

    @Test func waitSetting() throws {
        #expect(ApprovalWait.quarterHour.expiry(from: Self.t0) == Self.t0.addingTimeInterval(900))
        #expect(ApprovalWait.day.interval == TimeInterval(86_400))
        #expect(ApprovalWait.allCases.map(\.rawValue) == ["15m", "1h", "4h", "24h", "never"])
        var never = approval("a_1")
        never.expiresAt = ApprovalWait.never.expiry(from: never.createdAt)
        #expect(never.neverExpires && !approval("a_2").neverExpires)
        #expect(DeckSettings().approvalWait == .day)
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data("{}".utf8))
        #expect(old.approvalWait == .day)
        let odd = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"approvalWait":"3d"}"#.utf8))
        #expect(odd.approvalWait == .day)
        var settings = DeckSettings()
        settings.approvalWait = .never
        let back = try JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.approvalWait == .never)
    }

    @Test func statusAndMessage() {
        var book = ApprovalBook()
        book.add(approval("a_1"))
        #expect(book.status("a_1")?.text(now: Self.t0) == "pending approval a_1 (expires in 24 h 0 min): s wants a_1")
        _ = book.resolve("a_1", .approved, from: "mac", at: Self.t0)
        book.setResult("a_1", ApprovalCallResult(AgentHTTPResponse(status: 200, body: Data("stopped web".utf8))), line: "stopped web")
        let resolved = book.resolved("a_1")!
        #expect(Approvals.message(for: resolved) == "[ClaudeDeck approval a_1] Owner approved: s wants a_1 → stopped web")
        #expect(book.status("a_1")?.status == "approved")
        #expect(book.status("a_9") == nil)
        let refused = ResolvedApproval(approval: approval("a_2"), outcome: .refused, from: "mac", resolvedAt: Self.t0)
        #expect(Approvals.message(for: refused) == "[ClaudeDeck approval a_2] Owner refused: s wants a_2")
        let expired = ResolvedApproval(approval: approval("a_3"), outcome: .expired, from: "timeout", resolvedAt: Self.t0)
        #expect(Approvals.message(for: expired).hasPrefix("[ClaudeDeck approval a_3] Expired"))
    }

    /// approvals.json: pending ones with the call behind them come back pending (nothing waits on
    /// them in this launch), the ones whose time ran out expire on restore, results and replays
    /// are dropped with their approval.
    @MainActor @Test func persistenceRoundTrip() async throws {
        var book = ApprovalBook()
        book.add(approval("a_1"))
        book.add(approval("a_2", expires: 60))
        let replay = ApprovalReplay(caller: UUID(), command: "container", method: "POST", form: ["server": "s1"], json: false)
        book.attach(replay, to: "a_1")
        book.attach(replay, to: "a_9") // not pending: ignored
        let data = try JSONEncoder().encode(book)
        let saved = try JSONDecoder().decode(ApprovalBook.self, from: data)
        #expect(saved == book && saved.replays.keys.sorted() == ["a_1"])

        let queue = ApprovalQueue(now: { Self.t0.addingTimeInterval(120) })
        var resolved: [String] = []
        queue.observe { if case .resolved(let r) = $0 { resolved.append("\(r.outcome.rawValue):\(r.id)") } }
        queue.restore(saved)
        #expect(resolved == ["expired:a_2"])
        #expect(queue.pending.map(\.id) == ["a_1"] && !queue.hasWaiter("a_1"))
        #expect(queue.book.replays["a_1"] == replay)
        queue.resolve("a_1", .approved, from: "mac")
        #expect(queue.book.replays["a_1"] == replay) // kept until the replayed call answers
        queue.setResult("a_1", ApprovalCallResult(AgentHTTPResponse(status: 200, body: Data("ok".utf8))), line: "ok")
        #expect(queue.book.replays["a_1"] == nil && queue.book.results["a_1"]?.body == Data("ok".utf8))
        #expect(queue.book.resolved("a_1")?.result == "ok")
    }

    @Test func remoteCompatibility() throws {
        // An older Mac: no history fields.
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(RemoteSnapshot(hostName: "m", sessions: [])))
        #expect(old.approvalHistory == nil && old.decisionHistory == nil)
        var snapshot = RemoteSnapshot(hostName: "m", sessions: [])
        snapshot.approvalHistory = [ResolvedApproval(approval: approval("a_1"), outcome: .approved, from: "mac", resolvedAt: Self.t0, result: "done")]
        let back = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(back.approvalHistory?.first?.result == "done")
        #expect(RemoteSnapshot.Feature.all.isSuperset(of: [RemoteSnapshot.Feature.approvalHistory, RemoteSnapshot.Feature.decisionHistory]))
        // A newer Mac's outcome this side doesn't know.
        let encoded = String(decoding: try JSONEncoder().encode(snapshot.approvalHistory![0]), as: UTF8.self)
            .replacingOccurrences(of: "\"approved\"", with: "\"superseded\"")
        #expect(try JSONDecoder().decode(ResolvedApproval.self, from: Data(encoded.utf8)).outcome == .cancelled)
        // History: a week.
        let week = Approvals.history([ResolvedApproval(approval: approval("a_1"), outcome: .refused, from: "mac", resolvedAt: Self.t0),
                                      ResolvedApproval(approval: approval("a_2"), outcome: .refused, from: "mac",
                                                       resolvedAt: Self.t0.addingTimeInterval(-8 * 24 * 3600))], now: Self.t0)
        #expect(week.map(\.id) == ["a_1"])
    }

    @Test func routes() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/approvals/a_1") == .route(.approval("a_1")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/approvals/a_1/wait") == .route(.waitApproval("a_1")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/approvals/a_1/cancel") == .route(.cancelApproval("a_1")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/approvals/a_1/cancel") == .methodNotAllowed)
        #expect(SessionCLI.Route.waitApproval("a_1").scope == .server)
        #expect(SessionCLI.Exit.pendingApproval.rawValue == 75)
    }
}
