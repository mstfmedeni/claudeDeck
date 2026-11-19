import Foundation

/// The v1.3 agent API behind `claudedeck server domain check|buy`: a domain's availability and
/// price, and buying it from the Namecheap balance.
///
/// A purchase spends real money, so it's guarded on both sides. Here: the domain and `--years`
/// are checked, and `--approval` must be a decision in ClaudeDeck's book that the owner answered
/// and that names the domain, before anything is sent; the panel's 428 (with the price) is always
/// the owner's purchase dialog (gate `.owner`, never confirmed automatically); every refusal and
/// the purchase are logged. On the panel: the owner's on/off switch and price cap, the
/// `domains_buy` scope with an admin token, premium domains refused, the balance checked.
extension ServerPlanCLI.Runner {
    /// What a session must do to get an approval.
    static let approvalHint = "ask the owner first with claudedeck decide, then pass its id"
    static let namecheapSettings = "ServerPlan › Entegrasyonlar › Namecheap"

    func performV13(_ command: ServerPlanCLI.Command, form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        switch command.name {
        case "domain-check":
            let domain = try ServerPlanCLI.domainName(form["domain"])
            let (status, data) = try await exchange("GET", "/domains/check", query: [URLQueryItem(name: "name", value: domain)], timeout: 60)
            guard (200..<300).contains(status) else { throw Refusal(outcome: Self.domainFailure(status, data, buying: false)) }
            return ServerPlanCLI.Outcome(json: data, text: ServerPlanCLI.domainCheckText(data))
        case "domain-buy":
            return try await domainBuy(command, form)
        default:
            return .error(404, "unknown_command", exit: .usage)
        }
    }

    private func domainBuy(_ command: ServerPlanCLI.Command, _ form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        let domain = try ServerPlanCLI.domainName(form["domain"])
        let given = (form["years"] ?? "").trimmingCharacters(in: .whitespaces)
        guard let years = given.isEmpty ? 1 : Int(given), years == 1 || years == 2 else {
            throw Refusal(outcome: .error(400, "bad_years", "--years is 1 or 2", exit: .usage))
        }
        // The owner's decision, checked here before the panel hears of it.
        let approval = (form["approval"] ?? "").trimmingCharacters(in: .whitespaces)
        let decision = Decisions.isValidID(approval) ? await self.decision(approval) : nil
        if let problem = ServerPlanCLI.approvalProblem(id: approval, decision: decision, domain: domain) {
            log("domain buy \(domain): refused, \(problem)")
            throw Refusal(outcome: .error(400, "bad_approval", "\(problem); \(Self.approvalHint)", exit: .usage))
        }
        var body: [String: Any] = ["domain": domain, "years": years, "approval_ref": approval, "setup_dns": form["no_dns"] != "1"]
        var (status, data) = try await exchange("POST", "/domains/purchase", json: body, timeout: 180)
        if status == ServerPlanContract.confirmRequiredStatus {
            // The panel's price summary goes to the owner's purchase dialog; only a yes sends
            // the confirmation, and only for the domain asked about.
            let gate = ServerPlanError.ErrorBody.parse(data)
            guard gate.confirm == nil || gate.confirm == domain else {
                log("domain buy \(domain): refused, the panel asked to confirm \(gate.confirm ?? "")")
                throw Refusal(outcome: .error(502, "serverplan_error", "the panel asked to confirm another name: \(gate.confirm ?? "")", exit: .failed))
            }
            let summary = gate.summary ?? gate.message ?? "\(domain), \(years) year(s)"
            guard await approve(command.name, domain, summary) else {
                log("domain buy \(domain): the owner refused or didn't answer")
                throw Refusal(outcome: .error(403, "owner_refused", "the owner didn't approve the purchase in ClaudeDeck; nothing was bought", exit: .refused))
            }
            log("domain buy \(domain): approved by the owner (\(summary))")
            body["confirm"] = domain
            (status, data) = try await exchange("POST", "/domains/purchase", json: body, timeout: 180)
        }
        guard (200..<300).contains(status), status != ServerPlanContract.confirmRequiredStatus else {
            let failure = Self.domainFailure(status, data, buying: true)
            log("domain buy \(domain): refused, \(failure.text)")
            throw Refusal(outcome: failure)
        }
        let object = ServerPlanCLI.object(data) ?? [:]
        let charged = ServerPlanCLI.value(object, "charged_amount").map { "\($0) \(ServerPlanCLI.value(object, "currency") ?? "")" } ?? "?"
        log("domain buy \(domain): bought for \(years) year(s), charged \(charged), order \(ServerPlanCLI.value(object, "order_id") ?? "?"), approval \(approval)")
        return ServerPlanCLI.Outcome(status: status, json: data, text: ServerPlanCLI.domainPurchaseText(data))
    }

    /// A request whose HTTP status is the answer (the purchase's 402, 403, 412 codes matter).
    private func exchange(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil,
                          timeout: TimeInterval) async throws -> (Int, Data) {
        let request = try client.request(path, method: method, query: query, json: json, timeout: timeout)
        do {
            let (data, response) = try await client.transport.data(for: request)
            return (response.statusCode, data)
        } catch let error as ServerPlanError {
            throw error
        } catch {
            throw ServerPlanError.transport(error.localizedDescription)
        }
    }

    /// A panel refusal of `domain check` / `domain buy`, with what to do about it.
    static func domainFailure(_ status: Int, _ data: Data, buying: Bool) -> ServerPlanCLI.Outcome {
        let parsed = ServerPlanError.ErrorBody.parse(data)
        let code = parsed.code ?? ""
        let message = parsed.message ?? "HTTP \(status)"
        func failure(_ status: Int, _ code: String, _ hint: String?, exit: SessionCLI.Exit) -> ServerPlanCLI.Outcome {
            .error(status, code, hint.map { "\(message); \($0)" } ?? message, exit: exit)
        }
        switch status {
        case 400 where message.contains("approval_ref"):
            return failure(400, "no_approval_ref", approvalHint, exit: .usage)
        case 400:
            return failure(400, code.isEmpty ? "bad_request" : code, nil, exit: .usage)
        case 402:
            return failure(402, "insufficient_balance", "the Namecheap balance is too low; the owner tops it up", exit: .refused)
        case 403 where code == "premium_domain":
            return failure(403, code, "agents never buy premium domains; the owner buys it by hand", exit: .refused)
        case 403 where code == "price_cap":
            return failure(403, code, "over the owner's yearly price cap; only the owner raises it in \(namecheapSettings)", exit: .refused)
        case 403:
            return failure(403, "serverplan_forbidden", buying ? "the ServerPlan token needs the domains_buy scope and an admin user" : nil, exit: .refused)
        case 404:
            return .error(501, "not_available", ServerPlanCLI.notAvailable, exit: .refused)
        case 409:
            return failure(409, "conflict", "already bought, or not available: see claudedeck server domain check", exit: .failed)
        case 412 where code == "purchase_disabled":
            return failure(412, code, "agent purchases are turned off in \(namecheapSettings)", exit: .refused)
        case 412:
            return failure(412, code.isEmpty ? "not_configured" : code, "Namecheap (or the registrant contact) isn't set up in \(namecheapSettings)", exit: .refused)
        case 502:
            return failure(502, code.isEmpty ? "registrar_error" : code, nil, exit: .failed)
        default:
            return ServerPlanCLI.outcome(for: ServerPlanError.from(status: status, body: data))
        }
    }
}

extension ServerPlanCLI {
    /// A registrable name as the panel normalizes it (trimmed, lowercased).
    static func domainName(_ value: String?) throws -> String {
        let name = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
        guard name.count <= 253, name.wholeMatch(of: try! Regex("\(label)(\\.\(label))+")) != nil else {
            throw Runner.Refusal(outcome: .error(400, "bad_domain", "a domain like example.com", exit: .usage))
        }
        return name
    }

    /// Why `decision` doesn't approve buying `domain` (nil: it does). The owner answered it (not
    /// pending, not cancelled), and its question or answer names the domain.
    public static func approvalProblem(id: String, decision: OwnerDecision?, domain: String) -> String? {
        guard !id.isEmpty else { return "no --approval" }
        guard Decisions.isValidID(id), let decision, decision.id == id else { return "no decision \(id) in ClaudeDeck" }
        switch decision.status {
        case .pending: return "the owner hasn't answered \(id) yet"
        case .cancelled: return "\(id) was cancelled"
        case .answered: break
        }
        let name = domain.lowercased()
        guard decision.question.lowercased().contains(name) || (decision.answer ?? "").lowercased().contains(name) else {
            return "\(id) doesn't mention \(domain)"
        }
        return nil
    }

    static func amount(_ value: Any?) -> String? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): String(format: "%.2f", number.doubleValue)
        case let text as String: text
        default: nil
        }
    }

    /// `/domains/check`: available or not, the price, premium, and whether an agent may buy it.
    public static func domainCheckText(_ data: Data) -> String {
        guard let object = object(data) else { return String(decoding: data, as: UTF8.self) }
        let domain = value(object, "domain") ?? "?"
        let currency = value(object, "currency").map { " \($0)" } ?? ""
        var lines = ["\(domain): " + ((object["available"] as? Bool) == true ? "available" : "not available")]
        if let price = amount(object["price"]) {
            lines.append("price: \(price)\(currency) the first year" + (amount(object["renewal_price"]).map { ", renewal \($0)\(currency)/year" } ?? ""))
        }
        lines.append("premium: " + ((object["premium"] as? Bool) == true ? "yes" : "no"))
        if let cap = amount(object["price_cap"]) { lines.append("price cap: \(cap)\(currency)/year") }
        if (object["purchase_allowed"] as? Bool) == true {
            lines.append("purchase: allowed (with the owner's approval)")
        } else {
            lines.append("purchase: not allowed" + (value(object, "reason").map { ": \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The 201 of `/domains/purchase`.
    public static func domainPurchaseText(_ data: Data) -> String {
        guard let object = object(data) else { return String(decoding: data, as: UTF8.self) }
        let domain = value(object, "domain") ?? "?"
        let years = value(object, "years") ?? "?"
        let currency = value(object, "currency").map { " \($0)" } ?? ""
        var lines = ["bought: \(domain) for \(years) year\(years == "1" ? "" : "s")",
                     "charged: \(amount(object["charged_amount"]) ?? "?")\(currency)"]
        if let order = value(object, "order_id") { lines.append("order: \(order)") }
        if let nameservers = object["nameservers"] as? [Any], !nameservers.isEmpty {
            lines.append("nameservers: " + nameservers.compactMap(string).joined(separator: ", "))
        }
        switch object["cloudflare_zone"] {
        case let zone as [String: Any] where zone["error"] != nil:
            lines.append("cloudflare zone: failed (\(value(zone, "error") ?? "?")); set the nameservers by hand")
        case let zone as [String: Any]:
            lines.append("cloudflare zone: \(value(zone, "name") ?? domain) (\(value(zone, "status") ?? "?"))")
        default:
            lines.append("cloudflare zone: none (Namecheap's nameservers)")
        }
        lines.append("whois privacy: " + ((object["whois_privacy"] as? Bool) == true ? "on" : "off"))
        return lines.joined(separator: "\n")
    }
}
