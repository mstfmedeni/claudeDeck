import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck server domain check|buy` (agent API v1.3) through `ServerPlanCLI.Runner`: the
/// approval rule, the owner's purchase dialog and the panel's refusals. Never a real panel.
@Suite struct ServerPlanDomainBuyTests {
    /// Answers by "METHOD /path" in order (the last answer repeats) and records every request.
    private final class Transport: ServerPlanTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var replies: [String: [(Int, Data)]]

        init(_ replies: [String: [(Int, String)]]) {
            self.replies = replies.mapValues { $0.map { ($0.0, Data($0.1.utf8)) } }
        }

        var requests: [URLRequest] { lock.withLock { _requests } }
        var bodies: [[String: Any]] {
            requests.filter { $0.httpMethod != "GET" }.map { ($0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path.replacingOccurrences(of: ServerPlanContract.basePath, with: "")
            let key = "\(request.httpMethod ?? "GET") \(path)"
            let reply: (Int, Data) = lock.withLock {
                _requests.append(request)
                guard var list = replies[key], !list.isEmpty else { return (404, Data(#"{"error":"not_found"}"#.utf8)) }
                let first = list.removeFirst()
                replies[key] = list.isEmpty ? [first] : list
                return first
            }
            return (reply.1, HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }

        func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            let (data, response) = try await data(for: request)
            return (response, AsyncThrowingStream { $0.yield(data); $0.finish() })
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static let me13 = #"{"user":{"id":1,"username":"medeni"},"role":"admin","scopes":["read","domains","domains_buy"],"server_version":"1.3.0","features":[]}"#
    static let gate = (428, #"{"error":"confirm_required","message":"Onay gerekli","summary":"shop-example.com 1 yil icin satin alinacak: ~9.98 USD (yenileme 13.98/yil), onay d_00000000aa","confirm":"shop-example.com"}"#)
    static let bought = (201, #"{"domain":"shop-example.com","years":1,"charged_amount":9.98,"currency":"USD","order_id":"7001","purchase_id":3,"nameservers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"],"cloudflare_zone":{"name":"shop-example.com","status":"pending","nameservers":["ada.ns.cloudflare.com","bob.ns.cloudflare.com"]},"whois_privacy":true}"#)

    static func decision(_ id: String = "d_00000000aa", question: String = "Buy shop-example.com for the new store?", answer: String? = "yes",
                         status: OwnerDecision.Status = .answered) -> OwnerDecision {
        var decision = OwnerDecision(id: id, question: question, options: ["yes", "no"], recommended: "yes", context: nil,
                                     projectID: nil, project: "store", sessionID: nil, session: "store")
        decision.status = status
        if status == .answered { decision.answer = answer; decision.answeredAt = Date(); decision.answeredFrom = "mac" }
        return decision
    }

    private func runner(_ transport: Transport, me: String? = Self.me13, approve: Bool = false, decisions: [OwnerDecision] = [Self.decision()],
                        asked: Box<[String]> = Box([]), log: Box<[String]> = Box([])) throws -> ServerPlanCLI.Runner {
        let client = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "http://127.0.0.1:5099")!, token: "spk_test"), transport: transport)
        let me = try me.map { try JSONDecoder().decode(ServerPlanMe.self, from: Data($0.utf8)) }
        return ServerPlanCLI.Runner(client: client, me: me, approve: { command, target, summary in
            asked.value.append("\(command) \(target) | \(summary ?? "")")
            return approve
        }, log: { log.value.append($0) }, decision: { id in decisions.first { $0.id == id } })
    }

    private func buy(_ r: ServerPlanCLI.Runner, _ domain: String = "shop-example.com", approval: String = "d_00000000aa",
                     years: String = "1", noDNS: Bool = false) async -> ServerPlanCLI.Outcome {
        await r.run("domain-buy", method: "POST", form: ["domain": domain, "approval": approval, "years": years, "no_dns": noDNS ? "1" : "0"])
    }

    // MARK: Offered only by a 1.3 panel

    @Test func offeredFromVersionOrFeature() throws {
        let check = try #require(ServerPlanCLI.commands["domain-check"]), purchase = try #require(ServerPlanCLI.commands["domain-buy"])
        #expect(check.gate == .none && check.method == "GET" && check.scope == "read")
        #expect(purchase.gate == .owner && purchase.method == "POST" && purchase.scope == "domains_buy")
        func me(_ version: String?, scopes: [String] = ["read", "domains_buy"], features: [String] = []) -> ServerPlanMe {
            ServerPlanMe(user: "medeni", scopes: scopes, serverVersion: version, features: features)
        }
        #expect(ServerPlanCLI.offers(check, me: me("1.3.0")) && ServerPlanCLI.offers(purchase, me: me("1.3")))
        #expect(ServerPlanCLI.offers(purchase, me: me("2.0")))
        #expect(!ServerPlanCLI.offers(check, me: me("1.2.0")) && !ServerPlanCLI.offers(purchase, me: me("1.2.0")))
        // A panel that names the feature, whatever its version.
        #expect(ServerPlanCLI.offers(check, me: me("1.2.0", features: ["domain_check"])))
        #expect(ServerPlanCLI.offers(purchase, me: me(nil, features: ["domain_purchase"])))
        #expect(!ServerPlanCLI.offers(purchase, me: me("1.2.0", features: ["domain_check"])))
        // Unknown version, or no /me: not offered (other v1.1 commands are still tried).
        #expect(!ServerPlanCLI.offers(purchase, me: me(nil)) && !ServerPlanCLI.offers(purchase, me: nil))
        #expect(ServerPlanCLI.offers(ServerPlanCLI.commands["ports"]!, me: nil) && ServerPlanCLI.offers(ServerPlanCLI.commands["ports"]!, me: me(nil)))
        // The token's scope.
        #expect(!ServerPlanCLI.offers(purchase, me: me("1.3.0", scopes: ["read", "domains"])))
    }

    @Test func olderPanelDoesntOfferIt() async throws {
        let transport = Transport([:])
        let old = #"{"user":{"id":1,"username":"medeni"},"role":"admin","scopes":["read","domains","domains_buy"],"server_version":"1.2.0","features":[]}"#
        let r = try runner(transport, me: old, approve: true)
        let outcome = await buy(r)
        #expect(outcome.status == 501 && outcome.exit == .refused && transport.requests.isEmpty)
        #expect(await r.run("domain-check", method: "GET", form: ["domain": "a.com"]).exit == .refused)
        // A 1.3 panel without the route (404) is "not available" too.
        let missing = await (try runner(Transport([:]))).run("domain-check", method: "GET", form: ["domain": "a.com"])
        #expect(missing.status == 501 && missing.exit == .refused)
    }

    // MARK: Check

    @Test func checkText() async throws {
        let transport = Transport(["GET /domains/check": [(200, #"{"domain":"shop-example.com","available":true,"premium":false,"price":9.98,"renewal_price":13.98,"currency":"USD","price_cap":25,"purchase_allowed":true,"reason":""}"#)]])
        let outcome = await (try runner(transport)).run("domain-check", method: "GET", form: ["domain": " Shop-Example.com "])
        #expect(outcome.exit == .ok && outcome.status == 200)
        #expect(outcome.text.contains("shop-example.com: available") && outcome.text.contains("price: 9.98 USD the first year, renewal 13.98 USD/year"))
        #expect(outcome.text.contains("premium: no") && outcome.text.contains("purchase: allowed"))
        #expect(transport.requests.first?.url?.query == "name=shop-example.com")
        #expect(transport.requests.first?.timeoutInterval == 60)

        let taken = ServerPlanCLI.domainCheckText(Data(#"{"domain":"premium.io","available":true,"premium":true,"price":1450,"renewal_price":1450,"currency":"USD","price_cap":25,"purchase_allowed":false,"reason":"premium domain: agent satin alamaz"}"#.utf8))
        #expect(taken.contains("premium: yes") && taken.contains("purchase: not allowed: premium domain: agent satin alamaz"))
        #expect(ServerPlanCLI.domainCheckText(Data(#"{"domain":"taken.com","available":false,"purchase_allowed":false,"reason":"domain musait degil"}"#.utf8))
            .hasPrefix("taken.com: not available"))

        // A bad name never goes out; Namecheap not set up is the owner's to fix.
        let none = Transport([:])
        #expect(await (try runner(none)).run("domain-check", method: "GET", form: ["domain": "not a domain"]).exit == .usage && none.requests.isEmpty)
        let off = await (try runner(Transport(["GET /domains/check": [(412, #"{"error":"not_configured","message":"namecheap ayarlari eksik"}"#)]])))
            .run("domain-check", method: "GET", form: ["domain": "a.com"])
        #expect(off.status == 412 && off.exit == .refused && off.text.contains("Entegrasyonlar › Namecheap"))
    }

    // MARK: Approval (checked before anything is sent)

    @Test func approvalRule() {
        let domain = "shop-example.com"
        #expect(ServerPlanCLI.approvalProblem(id: "d_00000000aa", decision: Self.decision(), domain: domain) == nil)
        // The answer may name it instead of the question; any case.
        #expect(ServerPlanCLI.approvalProblem(id: "d_00000000aa", decision: Self.decision(question: "Which domain?", answer: "SHOP-EXAMPLE.COM"), domain: domain) == nil)
        #expect(ServerPlanCLI.approvalProblem(id: "", decision: nil, domain: domain) == "no --approval")
        #expect(ServerPlanCLI.approvalProblem(id: "d_00000000ff", decision: nil, domain: domain)?.contains("no decision") == true)
        #expect(ServerPlanCLI.approvalProblem(id: "x", decision: nil, domain: domain)?.contains("no decision") == true)
        #expect(ServerPlanCLI.approvalProblem(id: "d_00000000aa", decision: Self.decision(status: .pending), domain: domain)?.contains("hasn't answered") == true)
        #expect(ServerPlanCLI.approvalProblem(id: "d_00000000aa", decision: Self.decision(status: .cancelled), domain: domain)?.contains("cancelled") == true)
        #expect(ServerPlanCLI.approvalProblem(id: "d_00000000aa", decision: Self.decision(question: "Buy other.com?"), domain: domain)?.contains("doesn't mention") == true)
    }

    @Test func badApprovalIsRefusedLocally() async throws {
        let cases: [(approval: String, decisions: [OwnerDecision])] = [
            ("d_00000000ff", [Self.decision()]),                               // unknown id
            ("d_00000000aa", [Self.decision(status: .pending)]),               // not answered
            ("d_00000000aa", [Self.decision(status: .cancelled)]),             // cancelled
            ("d_00000000aa", [Self.decision(question: "Buy other.com?")]),     // another domain
            ("", [Self.decision()]),                                           // none
            ("not-an-id", [Self.decision()]),
        ]
        for (approval, decisions) in cases {
            let transport = Transport(["POST /domains/purchase": [Self.gate, Self.bought]])
            let asked = Box<[String]>([]), log = Box<[String]>([])
            let outcome = await buy(try runner(transport, approve: true, decisions: decisions, asked: asked, log: log), approval: approval)
            #expect(outcome.status == 400 && outcome.exit == .usage, "\(approval)")
            #expect(String(decoding: outcome.json, as: UTF8.self).contains("\"error\":\"bad_approval\""))
            #expect(outcome.text.contains("ask the owner first with claudedeck decide, then pass its id"))
            #expect(transport.requests.isEmpty && asked.value.isEmpty)
            #expect(log.value.contains { $0.hasPrefix("domain buy shop-example.com: refused") })
        }
        // Years and the name are checked here too.
        let transport = Transport([:])
        let r = try runner(transport, approve: true)
        #expect(await buy(r, years: "3").exit == .usage)
        #expect(await buy(r, years: "x").exit == .usage)
        #expect(await buy(r, "shop example").exit == .usage)
        #expect(transport.requests.isEmpty)
    }

    // MARK: The owner's dialog

    @Test func ownerRefusesNothingIsBought() async throws {
        let transport = Transport(["POST /domains/purchase": [Self.gate, Self.bought]])
        let asked = Box<[String]>([]), log = Box<[String]>([])
        let outcome = await buy(try runner(transport, approve: false, asked: asked, log: log))
        #expect(outcome.status == 403 && outcome.exit == .refused && outcome.text.contains("nothing was bought"))
        // Asked once, with the panel's price summary; one request, never confirmed.
        #expect(asked.value == ["domain-buy shop-example.com | shop-example.com 1 yil icin satin alinacak: ~9.98 USD (yenileme 13.98/yil), onay d_00000000aa"])
        #expect(transport.requests.count == 1 && transport.bodies.allSatisfy { $0["confirm"] == nil })
        #expect(transport.bodies.first?["approval_ref"] as? String == "d_00000000aa")
        #expect(log.value.contains { $0.contains("the owner refused") })
    }

    @Test func ownerApprovesItsBought() async throws {
        let transport = Transport(["POST /domains/purchase": [Self.gate, Self.bought]])
        let log = Box<[String]>([])
        let outcome = await buy(try runner(transport, approve: true, log: log), "Shop-Example.com", years: "1")
        #expect(outcome.status == 201 && outcome.exit == .ok)
        let first = transport.bodies[0], second = transport.bodies[1]
        #expect(first["domain"] as? String == "shop-example.com" && first["years"] as? Int == 1 && first["setup_dns"] as? Bool == true)
        #expect(first["approval_ref"] as? String == "d_00000000aa" && first["confirm"] == nil)
        #expect(second["confirm"] as? String == "shop-example.com" && second["approval_ref"] as? String == "d_00000000aa")
        #expect(transport.requests.allSatisfy { $0.timeoutInterval == 180 })
        for line in ["bought: shop-example.com for 1 year", "charged: 9.98 USD", "order: 7001", "nameservers: ada.ns.cloudflare.com, bob.ns.cloudflare.com",
                     "cloudflare zone: shop-example.com (pending)", "whois privacy: on"] {
            #expect(outcome.text.contains(line), "\(line)")
        }
        #expect(String(decoding: outcome.json, as: UTF8.self).contains("\"order_id\":\"7001\""))
        #expect(log.value.contains { $0.contains("approved by the owner") } && log.value.contains { $0.contains("bought for 1 year(s), charged 9.98 USD, order 7001") })

        // --no-dns, 2 years.
        let plain = Transport(["POST /domains/purchase": [Self.gate, (201, #"{"domain":"shop-example.com","years":2,"charged_amount":23.96,"currency":"USD","order_id":"7002","nameservers":null,"cloudflare_zone":null,"whois_privacy":true}"#)]])
        let two = await buy(try runner(plain, approve: true), years: "2", noDNS: true)
        #expect(two.exit == .ok && plain.bodies[0]["setup_dns"] as? Bool == false && plain.bodies[0]["years"] as? Int == 2)
        #expect(two.text.contains("for 2 years") && two.text.contains("charged: 23.96 USD") && two.text.contains("cloudflare zone: none"))
    }

    @Test func panelAskingAnotherNameIsNotConfirmed() async throws {
        let transport = Transport(["POST /domains/purchase": [(428, #"{"error":"confirm_required","summary":"x","confirm":"other.com"}"#)]])
        let asked = Box<[String]>([])
        let outcome = await buy(try runner(transport, approve: true, asked: asked))
        #expect(outcome.exit == .failed && asked.value.isEmpty && transport.requests.count == 1)
    }

    // MARK: The panel's refusals

    @Test func panelRefusalsMapToExitCodesAndHints() async throws {
        let cases: [(reply: (Int, String), status: Int, code: String, exit: SessionCLI.Exit, hint: String)] = [
            ((400, #"{"error":"bad_request","message":"approval_ref gerekli (sahibinin onay karari)"}"#), 400, "no_approval_ref", .usage, "claudedeck decide"),
            ((412, #"{"error":"purchase_disabled","message":"Agent domain satin alma panelde kapali (Entegrasyonlar > Namecheap)"}"#), 412, "purchase_disabled", .refused,
             "turned off in ServerPlan › Entegrasyonlar › Namecheap"),
            ((412, #"{"error":"not_configured","message":"Kayit iletisim bilgisi eksik: Phone"}"#), 412, "not_configured", .refused, "isn't set up in ServerPlan › Entegrasyonlar › Namecheap"),
            ((409, #"{"error":"conflict","message":"Bu domain daha once satin alindi"}"#), 409, "conflict", .failed, "already bought, or not available"),
            ((409, #"{"error":"conflict","message":"Domain musait degil"}"#), 409, "conflict", .failed, "domain check"),
            ((403, #"{"error":"premium_domain","message":"Premium domain (1450.00 USD): agent satin alamaz"}"#), 403, "premium_domain", .refused, "never buy premium"),
            ((403, #"{"error":"price_cap","message":"Fiyat 40.00 USD/yil, sinir 25.00"}"#), 403, "price_cap", .refused, "price cap"),
            ((403, #"{"error":"forbidden","message":"Bu islem sadece admin kullanicinin tokeni ile yapilabilir"}"#), 403, "serverplan_forbidden", .refused, "domains_buy scope"),
            ((402, #"{"error":"insufficient_balance","message":"Namecheap bakiyesi yetersiz: 3.00, gereken 9.98 USD"}"#), 402, "insufficient_balance", .refused, "balance is too low"),
            ((502, #"{"error":"registrar_error","message":"namecheap: timeout"}"#), 502, "registrar_error", .failed, "namecheap: timeout"),
        ]
        for c in cases {
            // Before the 428 (the panel checks first), and after the owner said yes.
            for replies in [[c.reply], [Self.gate, c.reply]] {
                let transport = Transport(["POST /domains/purchase": replies])
                let log = Box<[String]>([])
                let outcome = await buy(try runner(transport, approve: true, log: log))
                #expect(outcome.status == c.status && outcome.exit == c.exit, "\(c.code)")
                #expect(String(decoding: outcome.json, as: UTF8.self).contains("\"error\":\"\(c.code)\""), "\(c.code)")
                #expect(outcome.text.contains(c.hint), "\(c.code): \(outcome.text)")
                #expect(log.value.contains { $0.hasPrefix("domain buy shop-example.com: refused") }, "\(c.code)")
            }
        }
    }
}
