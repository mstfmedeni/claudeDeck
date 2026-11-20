import Foundation

/// `claudedeck server ratelimit show|set|clear HOST` (agent API 1.5, `/me` feature `ratelimit`):
/// Cloudflare rate limiting for an app's API (by default `/init`, 20 requests per 10 s per IP).
///
/// Cloudflare's Free plan allows one rate-limit rule per zone, so `set` replaces the zone's rule:
/// when there is one, the panel answers 428 (confirm = the host) with what would change, and that
/// goes to the owner (Onaylar). `clear` always asks first. `show` is read-only.
extension ServerPlanCLI.Runner {
    static let cloudflareSettings = "ServerPlan › Entegrasyonlar › Cloudflare"

    func performRateLimit(_ command: ServerPlanCLI.Command, form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        let host = try ServerPlanCLI.rateLimitHost(form["host"])
        switch command.name {
        case "ratelimit-show":
            let (status, data) = try await exchange("GET", "/ratelimit", query: [URLQueryItem(name: "host", value: host)], timeout: 60)
            guard (200..<300).contains(status) else { throw Refusal(outcome: Self.rateLimitFailure(status, data, host: host)) }
            return ServerPlanCLI.Outcome(json: data, text: ServerPlanCLI.rateLimitText(data, host: host))
        case "ratelimit-set":
            let paths = try ServerPlanCLI.rateLimitPaths(form["paths"])
            let (requests, period) = try ServerPlanCLI.rateLimitRate(form["rate"])
            let body: [String: Any] = ["host": host, "paths": paths, "requests": requests, "period": period]
            let data = try await rateLimitGated(command, "/ratelimit", body: body, host: host)
            log("ratelimit set \(host) \(paths.joined(separator: ",")) \(requests)/\(period)s")
            let rule = ServerPlanCLI.object(data)?["rule"] as? [String: Any]
            return ServerPlanCLI.Outcome(json: data, text: "set: " + (rule.map(ServerPlanCLI.rateLimitRuleText) ?? "\(host) \(paths.joined(separator: ",")) \(requests) per \(period)s"))
        case "ratelimit-clear":
            let data = try await rateLimitGated(command, "/ratelimit/clear", body: ["host": host], host: host)
            log("ratelimit clear \(host)")
            return ServerPlanCLI.Outcome(json: data, text: "cleared: the zone of \(host) has no rate-limit rule now")
        default:
            return .error(404, "unknown_command", exit: .usage)
        }
    }

    /// POST; a 428 (an existing rule would be replaced, or a clear) goes to the owner and is sent
    /// again with `confirm` only after a yes.
    private func rateLimitGated(_ command: ServerPlanCLI.Command, _ path: String, body: [String: Any], host: String) async throws -> Data {
        var (status, data) = try await exchange("POST", path, json: body, timeout: 90)
        if status == ServerPlanContract.confirmRequiredStatus {
            let parsed = ServerPlanError.ErrorBody.parse(data)
            let confirm = parsed.confirm ?? host
            guard await approve(command.name, confirm, parsed.summary ?? parsed.message) else {
                log("\(command.name) \(host): the owner refused or didn't answer")
                throw Refusal(outcome: .error(403, "owner_refused", "the owner didn't approve it in ClaudeDeck", exit: .refused))
            }
            log("\(command.name) \(host): approved by the owner")
            var confirmed = body
            confirmed["confirm"] = confirm
            (status, data) = try await exchange("POST", path, json: confirmed, timeout: 90)
        }
        guard (200..<300).contains(status) else { throw Refusal(outcome: Self.rateLimitFailure(status, data, host: host)) }
        return data
    }

    /// The panel's refusals with what to do about them.
    static func rateLimitFailure(_ status: Int, _ data: Data, host: String) -> ServerPlanCLI.Outcome {
        let parsed = ServerPlanError.ErrorBody.parse(data)
        let message = parsed.message ?? "HTTP \(status)"
        let code = parsed.code ?? ""
        func failure(_ status: Int, _ code: String, _ hint: String?, exit: SessionCLI.Exit) -> ServerPlanCLI.Outcome {
            .error(status, code, hint.map { "\(message); \($0)" } ?? message, exit: exit)
        }
        switch status {
        case 400: return failure(400, code.isEmpty ? "bad_request" : code, "a host like api.example.com, paths like /init or /v1/* (no quotes)", exit: .usage)
        case 404 where code == "not_found" && message.lowercased().contains("zone"):
            let base = host.split(separator: ".").suffix(2).joined(separator: ".")
            return failure(404, "no_zone", "no Cloudflare zone for \(base): add it with claudedeck server zone add \(base)", exit: .unknown)
        case 404: return .error(501, "not_available", ServerPlanCLI.notAvailable, exit: .refused)
        case 412: return failure(412, code.isEmpty ? "not_configured" : code, "the Cloudflare token isn't set in \(cloudflareSettings)", exit: .refused)
        case 428: return failure(403, "confirm_required", nil, exit: .refused)
        case 502:
            return failure(502, code.isEmpty ? "cloudflare_error" : code,
                           "Cloudflare refused; the panel's Cloudflare token needs Zone › Zone WAF › Edit (and the Free plan allows one rule per zone, period 10 s)",
                           exit: .failed)
        default: return ServerPlanCLI.outcome(for: ServerPlanError.from(status: status, body: data))
        }
    }
}

extension ServerPlanCLI {
    static func rateLimitHost(_ value: String?) throws -> String {
        let host = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard host.wholeMatch(of: /[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?/) != nil, host.contains("."), !host.contains("..") else {
            throw Runner.Refusal(outcome: .error(400, "bad_host", "a host like api.example.com", exit: .usage))
        }
        return host
    }

    /// `--paths /init,/v1/*` (default `/init`): absolute, no quotes or spaces, `*` only at the end.
    static func rateLimitPaths(_ value: String?) throws -> [String] {
        let given = (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let paths = given.isEmpty ? ["/init"] : given
        for path in paths where path.wholeMatch(of: /\/[A-Za-z0-9._~\/-]*\*?/) == nil {
            throw Runner.Refusal(outcome: .error(400, "bad_path", "\(path): paths like /init or /v1/* (comma separated)", exit: .usage))
        }
        return paths
    }

    /// `--rate 20/10s` (default; `N/M`, `N/Ms`, `N/Mm`) → (requests, period in seconds).
    static func rateLimitRate(_ value: String?) throws -> (Int, Int) {
        let text = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return (20, 10) }
        guard let match = text.wholeMatch(of: /(\d{1,6})\/(\d{1,5})(s|m)?/), let requests = Int(match.1), let amount = Int(match.2),
              requests > 0, amount > 0 else {
            throw Runner.Refusal(outcome: .error(400, "bad_rate", "--rate REQUESTS/PERIOD, e.g. 20/10s or 100/1m", exit: .usage))
        }
        return (requests, match.3 == "m" ? amount * 60 : amount)
    }

    static func rateLimitRuleText(_ rule: [String: Any]) -> String {
        let limit = rule["ratelimit"] as? [String: Any] ?? [:]
        let requests = value(limit, "requests_per_period") ?? "?", period = value(limit, "period") ?? "?"
        var text = (value(rule, "description") ?? "(no description)") + ": \(value(rule, "action") ?? "block") over \(requests) per \(period)s"
        if let by = value(limit, "characteristics") { text += " per \(by)" }
        if let timeout = value(limit, "mitigation_timeout") { text += ", blocked for \(timeout)s" }
        if (rule["enabled"] as? Bool) == false { text += " (disabled)" }
        if let expression = value(rule, "expression") { text += "\n  \(expression)" }
        return text
    }

    static func rateLimitText(_ data: Data, host: String) -> String {
        guard let object = object(data) else { return String(decoding: data, as: UTF8.self) }
        let rules = object["zone_rules"] as? [[String: Any]] ?? []
        let base = host.split(separator: ".").suffix(2).joined(separator: ".")
        guard !rules.isEmpty else { return "no rate-limit rule in the zone of \(base)" }
        return "rate-limit rules in the zone of \(base) (Cloudflare Free: one per zone):\n" + rules.map { "- " + rateLimitRuleText($0) }.joined(separator: "\n")
    }
}
