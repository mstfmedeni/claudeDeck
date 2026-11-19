import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck decide` (Decisions.swift) and the agenda board's parser (AgendaBoard.swift), and
/// both on the remote wire.
@Suite struct DecisionsTests {
    @Test func validation() throws {
        let ok = try Decisions.validate(question: "  Which DB? ", options: "Redis, SQLite ,,redis, None", recommend: "sqlite", context: " why ").get()
        #expect(ok.question == "Which DB?")
        #expect(ok.options == ["Redis", "SQLite", "None"])
        #expect(ok.recommended == "SQLite")
        #expect(ok.context == "why")
        // By number, one per line, free text only.
        #expect(try Decisions.validate(question: "q", options: "A, with comma\nB", recommend: "2", context: "").get().recommended == "B")
        #expect(try Decisions.validate(question: "q", options: "A, with comma\nB", recommend: "", context: "").get().options == ["A, with comma", "B"])
        let free = try Decisions.validate(question: "q", options: "", recommend: "", context: "").get()
        #expect(free.options.isEmpty && free.recommended == nil && free.context == nil)
        func refused(_ question: String, _ options: String = "", _ recommend: String = "", _ context: String = "") -> String? {
            if case .failure(let refusal) = Decisions.validate(question: question, options: options, recommend: recommend, context: context) { return refusal.code }
            return nil
        }
        #expect(refused("  ") == "bad_request")
        #expect(refused("q", "A,B", "C") == "bad_recommend")
        #expect(refused("q", "", "A") == "bad_recommend")
        #expect(refused("q", "A,B", "3") == "bad_recommend")
        #expect(refused("q", (1...11).map(String.init).joined(separator: ",")) == "too_many_options")
        #expect(refused(String(repeating: "x", count: Decisions.maxQuestion + 1)) == "too_long")
        #expect(refused("q", String(repeating: "o", count: Decisions.maxOption + 1)) == "too_long")
        #expect(refused("q", "", "", String(repeating: "c", count: Decisions.maxContext + 1)) == "too_long")
    }

    @Test func ids() {
        let id = Decisions.newID()
        #expect(id.hasPrefix("d_") && id.count == 12 && Decisions.isValidID(id))
        #expect(Decisions.newID() != id)
        #expect(!Decisions.isValidID("d_") && !Decisions.isValidID("x_abc") && !Decisions.isValidID("d_ab/c") && !Decisions.isValidID("d_ab c"))
    }

    private func decision(_ id: String = Decisions.newID(), at: Date = Date()) -> OwnerDecision {
        OwnerDecision(id: id, question: "Which DB?", options: ["Redis", "SQLite"], recommended: "Redis", context: "ctx",
                      projectID: UUID(), project: "shop", sessionID: UUID(), session: "api", createdAt: at)
    }

    @Test func answeringFirstWins() {
        var book = DecisionBook()
        let asked = decision("d_0000000001")
        book.add(asked)
        #expect(book.pendingCount == 1 && book.decision("D_0000000001") != nil)
        guard case .answered(let answered) = book.answer("d_0000000001", with: "SQLite", from: "phone") else {
            Issue.record("not answered"); return
        }
        #expect(answered.status == .answered && answered.answer == "SQLite" && answered.answeredFrom == "phone" && answered.answeredAt != nil)
        // The Mac answering the same one a moment later: the phone's answer stays.
        guard case .alreadyAnswered(let kept) = book.answer("d_0000000001", with: "Redis", from: "mac") else {
            Issue.record("answered twice"); return
        }
        #expect(kept.answer == "SQLite")
        #expect(book.answer("d_nope", with: "x", from: "mac") == .unknown)
        book.setDelivery("d_0000000001", "queued")
        #expect(book.decision("d_0000000001")?.delivery == "queued" && book.pendingCount == 0)
    }

    @Test func answeredOnesArePrunedPendingStay() {
        var book = DecisionBook()
        let old = Date(timeIntervalSince1970: 1_000)
        book.add(decision("d_keep", at: old))
        for index in 0..<(Decisions.maxAnswered + 5) {
            let id = "d_a\(index)"
            book.add(decision(id, at: old.addingTimeInterval(Double(index))))
            _ = book.answer(id, with: "x", from: "mac", at: old.addingTimeInterval(Double(index)))
        }
        #expect(book.decisions.count == Decisions.maxAnswered + 1)
        #expect(book.decision("d_keep")?.isPending == true)
        #expect(book.decision("d_a0") == nil && book.decision("d_a\(Decisions.maxAnswered + 4)") != nil)
    }

    @Test func messageIsOneLine() {
        var asked = decision("d_00000000ab")
        asked.question = "Which DB\nfor the cache?"
        asked.answer = "SQLite —\nkeep it simple"
        let message = Decisions.message(for: asked)
        #expect(!message.contains("\n") && !message.contains("\r"))
        #expect(message.hasPrefix("[ClaudeDeck decision d_00000000ab]"))
        #expect(message.contains("Which DB for the cache?") && message.hasSuffix("SQLite — keep it simple"))
        #expect(Decisions.cleanAnswer("   ") == nil && Decisions.cleanAnswer(" ok ") == "ok")
        #expect(Decisions.cleanAnswer(String(repeating: "a", count: Decisions.maxAnswer + 1)) == nil)
    }

    @Test func textAndJSON() throws {
        var asked = decision("d_00000000cd")
        #expect(Decisions.text(asked).hasPrefix("pending\nid: d_00000000cd\nquestion: Which DB?\noptions: Redis (recommended), SQLite"))
        asked.status = .answered
        asked.answer = "SQLite"
        #expect(Decisions.text(asked).hasPrefix("answered: SQLite\n"))
        let list = Decisions.listText([asked])
        #expect(list.hasPrefix("ID") && list.contains("d_00000000cd") && list.contains("answered"))
        // The command's JSON: snake_case, every key present.
        let object = try #require(try JSONSerialization.jsonObject(with: AgentJSON.encode(decision("d_00000000ef"))) as? [String: Any])
        for key in ["id", "question", "options", "recommended", "context", "project_id", "project", "session_id", "session",
                    "created_at", "status", "answer", "answered_at", "answered_from", "delivery"] {
            #expect(object.keys.contains(key), "missing \(key)")
        }
        #expect(object["status"] as? String == "pending")
        #expect(object["answer"] is NSNull)
    }

    @Test func storedFileRoundTripsAndToleratesNewerFields() throws {
        var book = DecisionBook()
        book.add(decision("d_0000000011"))
        let data = try JSONEncoder().encode(book)
        #expect(try JSONDecoder().decode(DecisionBook.self, from: data) == book)
        let newer = #"{"decisions":[{"id":"d_x1","question":"q","status":"snoozed","future":1}]}"#
        let read = try JSONDecoder().decode(DecisionBook.self, from: Data(newer.utf8))
        #expect(read.decisions.first?.isPending == true && read.decisions.first?.options == [])
    }

    @Test func forRemote() {
        var book = DecisionBook()
        let now = Date()
        var long = decision("d_long", at: now.addingTimeInterval(-10))
        long.context = String(repeating: "c", count: 5_000)
        book.add(long)
        book.add(decision("d_old", at: now.addingTimeInterval(-90_000)))
        _ = book.answer("d_old", with: "x", from: "mac", at: now.addingTimeInterval(-90_000))
        book.add(decision("d_new", at: now.addingTimeInterval(-5)))
        _ = book.answer("d_new", with: "y", from: "mac", at: now.addingTimeInterval(-1))
        let remote = book.forRemote(now: now)
        #expect(remote.map(\.id) == ["d_new", "d_long"])
        #expect((remote.last?.context?.count ?? 0) <= 2_001)
    }

    // MARK: Cancelling

    @Test func cancelPendingOnly() {
        var book = DecisionBook()
        book.add(decision("d_00000000a1"))
        book.add(decision("d_00000000a2"))
        #expect(book.cancellable("d_00000000a1") == .cancelled(book.decision("d_00000000a1")!))
        guard case .cancelled(let cancelled) = book.cancel("D_00000000A1", reason: "obsolete") else { Issue.record("not cancelled"); return }
        #expect(cancelled.status == .cancelled && cancelled.cancelReason == "obsolete" && cancelled.cancelledAt != nil)
        #expect(book.pendingCount == 1 && book.pending.map(\.id) == ["d_00000000a2"])
        // Again: already cancelled; an answered one: already answered; unknown.
        guard case .alreadyCancelled = book.cancel("d_00000000a1", reason: "x") else { Issue.record("cancelled twice"); return }
        _ = book.answer("d_00000000a2", with: "Redis", from: "mac")
        guard case .alreadyAnswered(let kept) = book.cancel("d_00000000a2", reason: "x") else { Issue.record("answered one cancelled"); return }
        #expect(kept.answer == "Redis" && kept.cancelReason == nil)
        #expect(book.cancel("d_nope", reason: "x") == .unknown && book.cancellable("d_nope") == .unknown)
        // A cancelled one can't be answered afterwards.
        guard case .alreadyAnswered(let still) = book.answer("d_00000000a1", with: "SQLite", from: "phone") else { Issue.record("answered"); return }
        #expect(still.isCancelled && still.answer == nil)
        // Text, list and JSON.
        #expect(Decisions.text(book.decision("d_00000000a1")!).hasPrefix("cancelled: obsolete\nid: d_00000000a1"))
        #expect(Decisions.listText(book.newestFirst).contains("cancelled") && Decisions.listText(book.newestFirst).contains("(obsolete)"))
    }

    @Test func cancelledNeverGoToRemotes() throws {
        var book = DecisionBook()
        let now = Date()
        book.add(decision("d_00000000b1", at: now.addingTimeInterval(-30)))
        book.add(decision("d_00000000b2", at: now.addingTimeInterval(-20)))
        book.add(decision("d_00000000b3", at: now.addingTimeInterval(-10)))
        _ = book.cancel("d_00000000b1", reason: "superseded by d_00000000b3", at: now.addingTimeInterval(-5))
        _ = book.answer("d_00000000b2", with: "x", from: "mac", at: now.addingTimeInterval(-2))
        #expect(book.forRemote(now: now).map(\.id) == ["d_00000000b3", "d_00000000b2"])
        // Why: an older phone reads the new status as pending.
        let old = #"{"id":"d_00000000b1","question":"q","status":"cancelled"}"#
        struct OldDecision: Decodable {
            enum Status: String, Decodable { case pending, answered }
            var status: Status
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .pending
            }
            enum CodingKeys: String, CodingKey { case status }
        }
        #expect(try JSONDecoder().decode(OldDecision.self, from: Data(old.utf8)).status == .pending)
    }

    @Test func cancelledFieldsRoundTrip() throws {
        var book = DecisionBook()
        let parent = UUID()
        book.add(OwnerDecision(id: "d_00000000c1", question: "q", options: [], recommended: nil, context: nil, projectID: nil,
                               project: "p", sessionID: UUID(), session: "s", ancestors: [parent]))
        _ = book.cancel("d_00000000c1", reason: "owner dismissed")
        let back = try JSONDecoder().decode(DecisionBook.self, from: JSONEncoder().encode(book))
        #expect(back == book && back.decisions.first?.ancestors == [parent] && back.decisions.first?.cancelReason == "owner dismissed")
        // An older decisions.json (no new keys) still reads.
        let older = try JSONDecoder().decode(DecisionBook.self, from: Data(#"{"decisions":[{"id":"d_x2","question":"q","status":"answered"}]}"#.utf8))
        #expect(older.decisions.first?.ancestors == [] && older.decisions.first?.cancelReason == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: AgentJSON.encode(book.decisions[0])) as? [String: Any])
        #expect(object["status"] as? String == "cancelled" && object["cancel_reason"] as? String == "owner dismissed")
        #expect(object.keys.contains("cancelled_at") && object.keys.contains("ancestors"))
    }

    @Test func cancelledOnesArePrunedLikeAnswered() {
        var book = DecisionBook()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(Decisions.maxAnswered + 3) {
            book.add(decision(String(format: "d_%010x", index), at: base.addingTimeInterval(Double(index))))
            _ = book.cancel(String(format: "d_%010x", index), reason: "r", at: base.addingTimeInterval(Double(index)))
        }
        book.add(decision("d_pending01"))
        #expect(book.decisions.count == Decisions.maxAnswered + 1 && book.pendingCount == 1)
        #expect(book.decision("d_0000000000") == nil && book.decision(String(format: "d_%010x", Decisions.maxAnswered + 2)) != nil)
    }

    @Test func whoMayCancel() {
        let grand = UUID(), parent = UUID(), asker = UUID(), child = UUID(), stranger = UUID(), sibling = UUID()
        let starters = [parent: grand, asker: parent, child: asker, sibling: parent]
        let asked = OwnerDecision(id: "d_00000000d1", question: "q", options: [], recommended: nil, context: nil, projectID: nil,
                                  project: "p", sessionID: asker, session: "s")
        #expect(Decisions.mayCancel(caller: asker, decision: asked, startedBy: starters))
        #expect(Decisions.mayCancel(caller: parent, decision: asked, startedBy: starters))
        #expect(Decisions.mayCancel(caller: grand, decision: asked, startedBy: starters))
        #expect(!Decisions.mayCancel(caller: child, decision: asked, startedBy: starters))
        #expect(!Decisions.mayCancel(caller: sibling, decision: asked, startedBy: starters))
        #expect(!Decisions.mayCancel(caller: stranger, decision: asked, startedBy: starters))
        // The asking session is gone from the deck: the ancestry recorded when it asked still counts.
        #expect(Decisions.ancestors(of: asker, startedBy: starters) == [parent, grand])
        var gone = asked
        gone.ancestors = Decisions.ancestors(of: asker, startedBy: starters)
        #expect(Decisions.mayCancel(caller: grand, decision: gone, startedBy: [:]))
        #expect(!Decisions.mayCancel(caller: parent, decision: asked, startedBy: [:]))
        // No asking session recorded: nobody.
        var orphan = asked
        orphan.sessionID = nil
        #expect(!Decisions.mayCancel(caller: asker, decision: orphan, startedBy: starters))
        // A loop in a broken deck ends.
        #expect(Decisions.ancestors(of: asker, startedBy: [asker: parent, parent: asker]) == [parent])
    }

    @Test func duplicateGuard() {
        let session = UUID()
        var book = DecisionBook()
        var first = decision("d_00000000e1")
        first.sessionID = session
        first.question = "Hangi veritabanı?\n"
        book.add(first)
        #expect(Decisions.normalizedQuestion("  HANGİ   veritabanı ?? ") == Decisions.normalizedQuestion("hangi veritabanı"))
        #expect(Decisions.normalizedQuestion("Which DB?") == "which db")
        #expect(book.pendingDuplicate(session: session, question: "hangi  VERİTABANI")?.id == "d_00000000e1")
        // Another session, another question, the one being superseded, or not pending: no duplicate.
        #expect(book.pendingDuplicate(session: UUID(), question: "Hangi veritabanı?") == nil)
        #expect(book.pendingDuplicate(session: session, question: "Hangi önbellek?") == nil)
        #expect(book.pendingDuplicate(session: session, question: "Hangi veritabanı?", except: "d_00000000e1") == nil)
        _ = book.cancel("d_00000000e1", reason: "x")
        #expect(book.pendingDuplicate(session: session, question: "Hangi veritabanı?") == nil)
    }

    @Test func turkishGuard() {
        #expect(Decisions.looksTurkish(question: "Hangi veritabanı?", options: []))
        #expect(Decisions.looksTurkish(question: "Redis or SQLite", options: ["Ölçekle", "Bekle"]))
        #expect(Decisions.looksTurkish(question: "İLK", options: []))
        #expect(Decisions.looksTurkish(question: "Deploy now, ok mi?", options: []))
        #expect(Decisions.looksTurkish(question: "Cache: Redis ve SQLite", options: []))
        #expect(Decisions.looksTurkish(question: "s\u{0327}u an", options: []))  // ş decomposed
        #expect(!Decisions.looksTurkish(question: "Which database for the cache?", options: ["Redis", "SQLite"]))
        // Words, not pieces of words: "never", "milk", "bumper" aren't Turkish.
        #expect(!Decisions.looksTurkish(question: "Never use milk or bumper?", options: []))
        #expect(!Decisions.looksTurkish(question: "Café résumé naïve", options: []))
    }

    @Test func dismissedMessageIsOneLine() {
        var asked = decision("d_00000000f1")
        asked.question = "Line one\n  line two"
        let message = Decisions.dismissedMessage(for: asked)
        #expect(!message.contains("\n") && message.hasPrefix("[ClaudeDeck decision d_00000000f1] The owner dismissed your question “Line one line two”"))
        #expect(Decisions.cleanReason("  a\nb ") == "a b" && Decisions.cleanReason("  ") == nil)
        #expect((Decisions.cleanReason(String(repeating: "x", count: 900))?.count ?? 0) <= Decisions.maxReason + 1)
    }

    // MARK: Changing an answer

    @Test func changeAnswerKeepsHistory() throws {
        var book = DecisionBook()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        book.add(decision("d_00000000a9", at: t0))
        // Pending: answer it first.
        guard case .notAnswered = book.changeAnswer("d_00000000a9", to: "Redis", from: "mac") else { Issue.record("changed pending"); return }
        _ = book.answer("d_00000000a9", with: "Redis", from: "phone", at: t0.addingTimeInterval(10))
        book.setDelivery("d_00000000a9", "queued")
        guard case .same = book.changeAnswer("d_00000000a9", to: "Redis", from: "mac") else { Issue.record("same answer changed"); return }
        guard case .changed(let changed, let was) = book.changeAnswer("D_00000000A9", to: "SQLite", from: "mac", at: t0.addingTimeInterval(60)) else {
            Issue.record("not changed"); return
        }
        #expect(was == "Redis" && changed.answer == "SQLite" && changed.answeredFrom == "mac" && changed.isChanged)
        #expect(changed.changedAt == t0.addingTimeInterval(60) && changed.answeredAt == t0.addingTimeInterval(60) && changed.delivery == nil)
        #expect(changed.answerHistory == [.init(answer: "Redis", answeredAt: t0.addingTimeInterval(10), answeredFrom: "phone")])
        _ = book.changeAnswer("d_00000000a9", to: "None", from: "phone")
        #expect(book.decision("d_00000000a9")?.answerHistory.map(\.answer) == ["Redis", "SQLite"])
        #expect(book.changeAnswer("d_nope", to: "x", from: "mac") == .unknown)
        _ = book.cancel("d_00000000a9", reason: "x")  // answered: stays answered
        #expect(book.decision("d_00000000a9")?.isAnswered == true)
        // Cancelled ones can't be changed.
        book.add(decision("d_00000000aa"))
        _ = book.cancel("d_00000000aa", reason: "x")
        guard case .notAnswered = book.changeAnswer("d_00000000aa", to: "x", from: "mac") else { Issue.record("changed cancelled"); return }

        // decision get, the message, JSON, the stored file.
        let current = try #require(book.decision("d_00000000a9"))
        let text = Decisions.text(current)
        #expect(text.hasPrefix("answered: None (changed)\n") && text.contains("\nwas: Redis\nwas: SQLite"))
        let message = Decisions.changedMessage(for: current, was: "SQLite")
        #expect(message == "[ClaudeDeck decision d_00000000a9] The owner changed the answer to your question “Which DB?”: None (was: SQLite)")
        let object = try #require(try JSONSerialization.jsonObject(with: AgentJSON.encode(current)) as? [String: Any])
        let history = try #require(object["answer_history"] as? [[String: Any]])
        #expect(history.count == 2 && history[0]["answer"] as? String == "Redis" && history[0]["answered_from"] as? String == "phone")
        #expect(object.keys.contains("changed_at"))
        #expect(try JSONDecoder().decode(DecisionBook.self, from: JSONEncoder().encode(book)) == book)
    }

    @Test func sectionsRecentAndToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 18))!
        var all: [OwnerDecision] = []
        // 8 answered today (an hour apart), 2 yesterday, a pending and a cancelled one.
        for index in 0..<10 {
            var asked = decision(String(format: "d_%010d", index), at: now.addingTimeInterval(-Double(index) * 3600 - 60))
            asked.status = .answered
            asked.answer = "x"
            asked.answeredAt = index < 8 ? now.addingTimeInterval(-Double(index) * 3600) : now.addingTimeInterval(-86_400 - Double(index) * 60)
            all.append(asked)
        }
        all.append(decision("d_pending00"))
        var gone = decision("d_cancel000", at: now.addingTimeInterval(-100))
        gone.status = .cancelled
        gone.cancelledAt = now.addingTimeInterval(-50)
        all.append(gone)
        let (recent, otherToday) = DecisionSections.answered(all.shuffled(), now: now, calendar: calendar)
        #expect(recent.map(\.id) == (0..<5).map { String(format: "d_%010d", $0) })
        #expect(otherToday.map(\.id) == (5..<8).map { String(format: "d_%010d", $0) })
        #expect(DecisionSections.cancelledToday(all, now: now, calendar: calendar).map(\.id) == ["d_cancel000"])
        // Answered on another day but among the newest 5: still shown as recent.
        let few = DecisionSections.answered(Array(all[8..<10]), now: now, calendar: calendar)
        #expect(few.recent.count == 2 && few.otherToday.isEmpty)
    }

    @Test func changeOnTheWire() throws {
        let frame = try RemoteMessage.changeDecisionAnswer(id: "d_0000000099", answer: "SQLite").frame()
        #expect(try RemoteMessage.decode(frame) == .changeDecisionAnswer(id: "d_0000000099", answer: "SQLite"))
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.changeDecisionAnswer))
        // An older phone's decoder skips the new keys of a changed answer.
        var book = DecisionBook()
        book.add(decision("d_0000000098"))
        _ = book.answer("d_0000000098", with: "A", from: "mac")
        _ = book.changeAnswer("d_0000000098", to: "B", from: "mac")
        let data = try JSONEncoder().encode(book.decisions[0])
        struct OldDecision: Decodable { var id: String; var status: String; var answer: String? }
        let old = try JSONDecoder().decode(OldDecision.self, from: data)
        #expect(old.status == "answered" && old.answer == "B")
    }

    // MARK: Routes

    @Test func cancelRoute() {
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/decisions/d_1234/cancel") == .route(.cancelDecision("d_1234")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/decisions/d_1234/cancel") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/decisions/d_1234/answer") == .notFound)
        #expect(SessionCLI.Route.cancelDecision("x").scope == .decide)
    }

    @Test func dismissOnTheWire() throws {
        let frame = try RemoteMessage.dismissDecision(id: "d_0000000099").frame()
        #expect(try RemoteMessage.decode(frame) == .dismissDecision(id: "d_0000000099"))
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.dismissDecision))
    }

    @Test func routes() {
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/decisions") == .route(.decide))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/decisions") == .route(.decisions))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/decisions/d_1234") == .route(.decision("d_1234")))
        #expect(SessionCLI.match(method: "DELETE", path: "/v1/cli/decisions") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/decisions/d_1234") == .methodNotAllowed)
        #expect(SessionCLI.Route.decide.scope == .decide && SessionCLI.Route.decision("x").scope == .decide)
        // Claude sessions and the user's terminals; never a terminal a session opened.
        #expect(SessionCLI.fullScopes.contains(.decide))
        #expect(!SessionCLI.openedScopes.contains(.decide))
        var book = SessionCLIBook()
        let opened = book.token(for: UUID(), scopes: SessionCLI.scopes(openedBy: UUID()))
        let request = AgentHTTPRequest(method: "POST", path: "/v1/cli/decisions", query: [:], headers: ["authorization": "Bearer \(opened)"], body: Data())
        guard case .failure(let refusal) = SessionCLI.resolve(request, book: book) else { Issue.record("allowed"); return }
        #expect(refusal.response.status == 403)
    }

    @Test func limiter() {
        var book = SessionCLIBook()
        let caller = UUID()
        var allowed = 0
        for _ in 0..<12 where book.decisions.allow(caller) { allowed += 1 }
        #expect(allowed == 10)
        let other = book.decisions.allow(UUID())
        #expect(other)
    }

    // MARK: Remote

    @Test func remoteFieldsAreOptional() throws {
        // An older host: no decisions, no agendas, no features for them.
        guard case .snapshot(let old)? = try RemoteCompatibilityTests.decode(RemoteCompatibilityTests.snapshotFrom059) else {
            Issue.record("not a snapshot"); return
        }
        #expect(old.decisions == nil && old.agendas == nil)
        #expect(!old.supports(RemoteSnapshot.Feature.decisions) && !old.supports(RemoteSnapshot.Feature.agenda))
        #expect(RemoteSnapshot.Feature.all.isSuperset(of: [RemoteSnapshot.Feature.decisions, RemoteSnapshot.Feature.agenda]))

        // This host to a remote: the fields go and come back; an older remote ignores them.
        var snapshot = RemoteSnapshot(hostName: "h", sessions: [])
        snapshot.features = RemoteSnapshot.Feature.all
        snapshot.decisions = [decision("d_0000000099")]
        snapshot.agendas = [RemoteAgenda(projectID: UUID(), project: "shop",
                                         items: [AgendaItem(id: "A1", statusText: "doing", status: .doing, dependsOn: ["A0"])],
                                         updatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        let frame = try RemoteMessage.snapshot(snapshot).frame()
        guard case .snapshot(let back)? = try RemoteMessage.decode(frame) else { Issue.record("not a snapshot"); return }
        #expect(back.decisions?.first?.id == "d_0000000099" && back.decisions?.first?.recommended == "Redis")
        #expect(back.agendas?.first?.items.first?.status == .doing)

        let answer = try RemoteMessage.answerDecision(id: "d_0000000099", answer: "SQLite").frame()
        #expect(try RemoteMessage.decode(answer) == .answerDecision(id: "d_0000000099", answer: "SQLite"))
        // A newer agenda status this build doesn't know reads as "Other", not a failed snapshot.
        let json = #"""
        {"snapshot":{"_0":{"hostName":"n","sessions":[],"agendas":[{"projectID":"A0000000-0000-0000-0000-000000000001","project":"p",
          "items":[{"id":"A1","statusText":"parked","status":"parked","dependsOn":[]}]}]}}}
        """#
        guard case .snapshot(let newer)? = try RemoteCompatibilityTests.decode(json) else { Issue.record("not a snapshot"); return }
        #expect(newer.agendas?.first?.items.first?.status == nil)
    }
}

@Suite struct AgendaBoardTests {
    static let sample = """
    # Agenda

    Some intro text | with a pipe.

    | ID | Track | Owner (agent) | Status | Depends-On | Evidence | Notes |
    |----|-------|---------------|:------:|------------|----------|-------|
    | A1 | api | backend-1 | done | — | [PR #12](https://example.com/12) | ok |
    | A2 | api | backend-1 | **Doing** | A1 | | |
    | B1 | ios | ios-agent | In Review | A1, A2 | screenshots/b1.png | |
    | B2 | ios | | blocked | B1; A2 | waiting on `pay\\|ment` | |
    | C1 | web | web | todo | | | |
    | C2 | web | web | parked | | | |
    |    | web | web | todo | | | (no id: skipped) |
    """

    @Test func parsesTheTable() throws {
        let board = try #require(AgendaBoard.parse(Self.sample))
        #expect(board.items.map(\.id) == ["A1", "A2", "B1", "B2", "C1", "C2"])
        let a1 = board.items[0]
        #expect(a1.status == .done && a1.track == "api" && a1.owner == "backend-1" && a1.dependsOn.isEmpty)
        #expect(a1.evidence == "[PR #12](https://example.com/12)")
        #expect(board.items[1].status == .doing && board.items[1].statusText == "Doing" && board.items[1].dependsOn == ["A1"])
        #expect(board.items[2].status == .review && board.items[2].dependsOn == ["A1", "A2"])
        let b2 = board.items[3]
        #expect(b2.status == .blocked && b2.owner == nil && b2.dependsOn == ["B1", "A2"] && b2.evidence == "waiting on `pay|ment`")
        #expect(board.items[4].status == .todo && board.items[4].evidence == nil)
        #expect(board.items[5].status == nil && board.items[5].statusText == "parked")
        let columns = board.columns
        #expect(columns.map(\.status) == [.todo, .doing, .review, .blocked, .done, nil])
        #expect(columns.map(\.items.count) == [1, 1, 1, 1, 1, 1])
        #expect(board.count(.done) == 1)
    }

    @Test func columnOrderCaseAndExtrasDontMatter() throws {
        let markdown = """
        status|EVIDENCE|id|extra|depends_on|AGENT
        ---|---|---|---|---|---
        WIP|log.txt|X-1|ignored|X-0|bot
        Completed ✅||X-0|||
        """
        let board = try #require(AgendaBoard.parse(markdown))
        #expect(board.items.count == 2)
        #expect(board.items[0].id == "X-1" && board.items[0].status == .doing && board.items[0].evidence == "log.txt")
        #expect(board.items[0].owner == "bot" && board.items[0].dependsOn == ["X-0"] && board.items[0].track == nil)
        #expect(board.items[1].status == .done)
        // A short row leaves the rest empty.
        let short = try #require(AgendaBoard.parse("| id | status | owner |\n|--|--|--|\n| Z | todo |\n"))
        #expect(short.items.first?.owner == nil && short.items.first?.status == .todo)
    }

    @Test func titleColumnAndSeveralTables() throws {
        let markdown = """
        ## Track A
        | id | task | status |
        |---|---|---|
        | A1 | Build the API | doing |

        | Name | Value |
        |---|---|
        | not | agenda |

        ## Track B
        | # | Status | Title |
        | --- | --- | --- |
        | B1 | to-do | Ship the app |
        """
        let board = try #require(AgendaBoard.parse(markdown))
        #expect(board.items.map(\.id) == ["A1", "B1"])
        #expect(board.items[0].title == "Build the API" && board.items[1].title == "Ship the app" && board.items[1].status == .todo)
    }

    @Test func noBoard() {
        #expect(AgendaBoard.parse("") == nil)
        #expect(AgendaBoard.parse("# Agenda\n\nNothing yet.\n") == nil)
        // A table without an id or a status column isn't the agenda.
        #expect(AgendaBoard.parse("| task | owner |\n|---|---|\n| a | b |\n") == nil)
        // Tables in a code block are examples.
        #expect(AgendaBoard.parse("```\n| id | status |\n|---|---|\n| A | todo |\n```\n") == nil)
        // The header and separator alone: a board with no items yet.
        #expect(AgendaBoard.parse("| id | status |\n|---|---|\n")?.items.isEmpty == true)
        // Windows line endings.
        #expect(AgendaBoard.parse("| id | status |\r\n|---|---|\r\n| A | doing |\r\n")?.items.first?.status == .doing)
    }

    @Test func statusWords() {
        #expect(AgendaStatus(cell: "In progress") == .doing)
        #expect(AgendaStatus(cell: "in-progress") == .doing)
        #expect(AgendaStatus(cell: "TODO") == .todo)
        #expect(AgendaStatus(cell: "To Do") == .todo)
        #expect(AgendaStatus(cell: "`review`") == .review)
        #expect(AgendaStatus(cell: "On hold") == .blocked)
        #expect(AgendaStatus(cell: "✅") == .done)
        #expect(AgendaStatus(cell: "done ✅") == .done)
        #expect(AgendaStatus(cell: "someday") == nil)
    }

    @Test func cellsAndLimits() {
        #expect(AgendaBoard.cells("| a | b\\|c | d |") == ["a", "b|c", "d"])
        #expect(AgendaBoard.cells("a|b") == ["a", "b"])
        #expect(AgendaBoard.isSeparator("|:--|--:|:-:|") && AgendaBoard.isSeparator("--- | ---"))
        #expect(!AgendaBoard.isSeparator("| a | b |"))
        let rows = (0..<(AgendaBoard.maxItems + 20)).map { "| I\($0) | todo |" }.joined(separator: "\n")
        #expect(AgendaBoard.parse("| id | status |\n|---|---|\n" + rows)?.items.count == AgendaBoard.maxItems)
        let long = AgendaBoard.parse("| id | status | evidence |\n|---|---|---|\n| A | done | \(String(repeating: "e", count: 2_000)) |\n")
        #expect((long?.items.first?.evidence?.count ?? 0) == AgendaBoard.maxCell + 1)
        #expect(AgendaBoard.dependencies("[A1](#a1), `B2` and C3") == ["A1", "B2", "C3"])
        #expect(AgendaBoard.dependencies("none").isEmpty && AgendaBoard.dependencies("n/a").isEmpty)
    }
}
