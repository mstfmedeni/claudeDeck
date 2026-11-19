import Foundation
import Testing
@testable import ClaudeDeckCore

/// ServerPlan 1.4: `claudedeck server balance`, the balance in `domain check`, the registrar
/// events and the Mac's edge-triggered low-balance watch. Never a real panel.
@Suite struct ServerPlanBalanceTests {
    /// Answers by "METHOD /path" and records every request.
    private final class Transport: ServerPlanTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private let replies: [String: (Int, Data)]

        init(_ replies: [String: (Int, String)]) {
            self.replies = replies.mapValues { ($0.0, Data($0.1.utf8)) }
        }

        var requests: [URLRequest] { lock.withLock { _requests } }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path.replacingOccurrences(of: ServerPlanContract.basePath, with: "")
            let reply = lock.withLock {
                _requests.append(request)
                return replies["\(request.httpMethod ?? "GET") \(path)"] ?? (404, Data(#"{"error":"not_found"}"#.utf8))
            }
            return (reply.1, HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }

        func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            let (data, response) = try await data(for: request)
            return (response, AsyncThrowingStream { $0.yield(data); $0.finish() })
        }
    }

    static let me14 = #"{"user":{"id":1,"username":"medeni"},"role":"admin","scopes":["read","domains"],"server_version":"1.4","features":["registrar_balance"]}"#
    static let balance = #"{"available_balance":15,"account_balance":20.5,"currency":"USD","low_threshold":20,"low":true,"checked_at":"2026-11-19T21:04:05.123456789+03:00"}"#

    private static func me(_ json: String) throws -> ServerPlanMe { try JSONDecoder().decode(ServerPlanMe.self, from: Data(json.utf8)) }

    private func runner(_ transport: Transport, me: String? = Self.me14) throws -> ServerPlanCLI.Runner {
        let client = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "http://127.0.0.1:5099")!, token: "spk_test"), transport: transport)
        return ServerPlanCLI.Runner(client: client, me: try me.map(Self.me), approve: { _, _, _ in false })
    }

    // MARK: Offered only by a 1.4 panel (or one naming the feature)

    @Test func offeredFromVersionOrFeature() throws {
        let command = try #require(ServerPlanCLI.commands["balance"])
        #expect(command.gate == .none && command.method == "GET" && command.scope == "read" && command.minMinor == 4)
        func me(_ version: String?, _ features: [String] = [], scopes: [String] = ["read"]) -> ServerPlanMe {
            ServerPlanMe(user: "u", scopes: scopes, serverVersion: version, features: features)
        }
        #expect(!ServerPlanCLI.offers(command, me: nil))
        #expect(!ServerPlanCLI.offers(command, me: me(nil)))
        #expect(!ServerPlanCLI.offers(command, me: me("1.3.0")))
        #expect(!ServerPlanCLI.offers(command, me: me("1.3.9", ["domain_check"])))
        #expect(ServerPlanCLI.offers(command, me: me("1.3.0", ["registrar_balance"])))
        #expect(ServerPlanCLI.offers(command, me: me("1.4")))
        #expect(ServerPlanCLI.offers(command, me: me("1.10.2")))
        #expect(ServerPlanCLI.offers(command, me: me("2.0")))
        // The scope still counts.
        #expect(!ServerPlanCLI.offers(command, me: me("1.4", ["registrar_balance"], scopes: ["deploy"])))
        #expect(me("1.4").offersRegistrarBalance && !me("1.3").offersRegistrarBalance)
    }

    @Test func olderPanelIsNotAvailable() async throws {
        let transport = Transport([:])
        let outcome = try await runner(transport, me: #"{"user":"u","scopes":["read"],"server_version":"1.3.0","features":[]}"#)
            .run("balance", method: "GET", form: [:])
        #expect(outcome.status == 501 && outcome.exit == .refused && transport.requests.isEmpty)
    }

    // MARK: The command

    @Test func balanceText() async throws {
        let transport = Transport(["GET /registrar/balance": (200, Self.balance)])
        let outcome = try await runner(transport).run("balance", method: "GET", form: ["refresh": "0"])
        #expect(outcome.status == 200 && outcome.exit == .ok)
        #expect(outcome.text.contains("available: 15.00 USD") && outcome.text.contains("account: 20.50 USD"))
        #expect(outcome.text.contains("low threshold: 20.00 USD") && outcome.text.contains("LOW:") && outcome.text.contains("Add Funds"))
        #expect(outcome.text.contains("checked: 2026-11-19T21:04:05"))
        #expect(transport.requests.first?.url?.query == nil)

        // --refresh asks Namecheap again; no threshold on the panel.
        let fresh = Transport(["GET /registrar/balance": (200, #"{"available_balance":80,"account_balance":80,"currency":"USD","low_threshold":null,"low":false,"checked_at":"2026-11-19T18:00:00Z"}"#)])
        let ok = try await runner(fresh).run("balance", method: "GET", form: ["refresh": "1"])
        #expect(ok.text.contains("low threshold: none") && ok.text.contains("low: no") && !ok.text.contains("LOW"))
        #expect(fresh.requests.first?.url?.query == "refresh=1")
    }

    @Test func balanceRefusals() async throws {
        let unconfigured = try await runner(Transport(["GET /registrar/balance": (412, #"{"error":"not_configured","message":"Namecheap ayarlari yapilmamis"}"#)]))
            .run("balance", method: "GET", form: [:])
        #expect(unconfigured.status == 412 && unconfigured.exit == .refused && unconfigured.text.contains("Entegrasyonlar"))
        let registrar = try await runner(Transport(["GET /registrar/balance": (502, #"{"error":"registrar_error","message":"timeout"}"#)]))
            .run("balance", method: "GET", form: [:])
        #expect(registrar.status == 502 && registrar.exit == .failed && registrar.text.contains("registrar_error"))
    }

    @Test func domainCheckShowsTheBalance() {
        let short = Data(#"{"domain":"shop.dev","available":true,"premium":false,"price":12.98,"renewal_price":14.98,"currency":"USD","price_cap":25,"purchase_allowed":false,"reason":"bakiye yetersiz: 3.00","balance":3,"balance_currency":"USD"}"#.utf8)
        let text = ServerPlanCLI.domainCheckText(short)
        #expect(text.contains("balance: 3.00 USD"))
        #expect(text.contains("purchase: not allowed: bakiye yetersiz: 3.00") && text.contains("Add Funds"))
        // Without the balance (the panel couldn't read it): no line.
        let plain = ServerPlanCLI.domainCheckText(Data(#"{"domain":"shop.dev","available":true,"price":9.98,"currency":"USD","purchase_allowed":true,"reason":""}"#.utf8))
        #expect(!plain.contains("balance") && plain.contains("purchase: allowed"))
    }

    // MARK: Wire

    @Test func decodesTheBalance() throws {
        let value = try ServerPlanClient.decode(ServerPlanRegistrarBalance.self, from: Data(Self.balance.utf8))
        #expect(value.available == 15 && value.account == 20.5 && value.currency == "USD" && value.lowThreshold == 20 && value.low)
        #expect(value.checkedAt != nil)
        let none = try ServerPlanClient.decode(ServerPlanRegistrarBalance.self,
                                               from: Data(#"{"available_balance":7.5,"currency":"USD","low_threshold":null,"low":false,"checked_at":"nonsense"}"#.utf8))
        #expect(none.lowThreshold == nil && none.checkedAt == nil && none.available == 7.5)
        #expect(ServerPlanRegistrarBalance.format(15) == "15" && ServerPlanRegistrarBalance.format(15.5) == "15.50" && ServerPlanRegistrarBalance.format(0.004) == "0")
    }

    @Test func clientAsksWithRefresh() async throws {
        let transport = Transport(["GET /registrar/balance": (200, Self.balance)])
        let client = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "http://127.0.0.1:5099")!, token: "spk_test"), transport: transport)
        _ = try await client.registrarBalance(refresh: true)
        #expect(transport.requests.first?.url?.query == "refresh=1")
        let failing = ServerPlanClient(config: client.config, transport: Transport(["GET /registrar/balance": (412, #"{"error":"not_configured","message":"x"}"#)]))
        await #expect(throws: ServerPlanError.self) { try await failing.registrarBalance() }
        do {
            _ = try await failing.registrarBalance()
        } catch ServerPlanError.http(let status, let code, _) {
            #expect(status == 412 && code == "not_configured")
        }
    }

    @Test func decodesRegistrarEvents() throws {
        let low = try #require(ServerPlanEvent(ServerSentEvent(event: "registrar.low_balance",
                                                               data: #"{"type":"registrar.low_balance","data":{"available_balance":12.5,"currency":"USD","low_threshold":20}}"#, id: "9")))
        #expect(low.kind == .registrarLowBalance && low.data.availableBalance == 12.5 && low.data.currency == "USD" && low.data.lowThreshold == 20)
        let ok = try #require(ServerPlanEvent(ServerSentEvent(event: "registrar.balance_ok", data: #"{"data":{"available_balance":50,"currency":"USD","low_threshold":20}}"#)))
        #expect(ok.kind == .registrarBalanceOK && ok.data.availableBalance == 50)
    }

    // MARK: The low-balance watch

    @Test func thresholdPanelThenLocal() {
        #expect(RegistrarBalanceWatch.threshold(panel: 30, local: 20) == 30)
        #expect(RegistrarBalanceWatch.threshold(panel: nil, local: 20) == 20)
        #expect(RegistrarBalanceWatch.threshold(panel: 0, local: 20) == 20)
        #expect(RegistrarBalanceWatch.threshold(panel: nil, local: 0) == nil)
        #expect(RegistrarBalanceWatch.threshold(panel: 10, local: 0) == 10)
    }

    @Test func edgeTriggered() {
        var watch = RegistrarBalanceWatch()
        #expect(watch.observe(available: 25, currency: "USD", panelThreshold: nil, localThreshold: 20) == nil)
        let first = watch.observe(available: 15, currency: "USD", panelThreshold: nil, localThreshold: 20)
        #expect(first == RegistrarBalanceWatch.Notice(available: 15, currency: "USD", threshold: 20) && watch.notifiedLow)
        // Still low: once per crossing.
        #expect(watch.observe(available: 14, currency: "USD", panelThreshold: nil, localThreshold: 20) == nil)
        #expect(watch.lowEvent(available: 14, currency: "USD", threshold: 20, localThreshold: 20) == nil)
        // Back up, then down again: a new crossing.
        #expect(watch.observe(available: 20, currency: "USD", panelThreshold: nil, localThreshold: 20) == nil && !watch.notifiedLow)
        #expect(watch.observe(available: 5, currency: "USD", panelThreshold: nil, localThreshold: 20) != nil)
    }

    @Test func panelThresholdWins() {
        var watch = RegistrarBalanceWatch()
        // 25 is under the panel's 30 though over the local 20.
        #expect(watch.observe(available: 25, currency: "USD", panelThreshold: 30, localThreshold: 20)?.threshold == 30)
        var other = RegistrarBalanceWatch()
        // 15 is under the local 20 but the panel's 10 is the one in force.
        #expect(other.observe(available: 15, currency: "USD", panelThreshold: 10, localThreshold: 20) == nil && !other.notifiedLow)
    }

    @Test func zeroIsOff() {
        var watch = RegistrarBalanceWatch(notifiedLow: true)
        #expect(watch.observe(available: 1, currency: "USD", panelThreshold: nil, localThreshold: 0) == nil)
        #expect(!watch.notifiedLow)  // re-armed for when it's turned on
        // A panel event carries the panel's own threshold: it still warns.
        #expect(watch.lowEvent(available: 1, currency: "USD", threshold: 20, localThreshold: 0)?.threshold == 20)
        var silent = RegistrarBalanceWatch()
        #expect(silent.lowEvent(available: 1, currency: "USD", threshold: 0, localThreshold: 0) == nil)
    }

    @Test func eventsAndFetchesShareTheState() {
        var watch = RegistrarBalanceWatch()
        #expect(watch.lowEvent(available: 12, currency: "USD", threshold: 20, localThreshold: 20) != nil)
        #expect(watch.observe(available: 12, currency: "USD", panelThreshold: 20, localThreshold: 20) == nil)
        let withdrawn = watch.okEvent()
        #expect(withdrawn && !watch.notifiedLow)
        let again = watch.okEvent()
        #expect(!again)
        #expect(watch.lowEvent(available: 11, currency: "USD", threshold: 20, localThreshold: 20) != nil)
    }

    @Test func persistsAcrossLaunches() throws {
        var watch = RegistrarBalanceWatch()
        _ = watch.observe(available: 3, currency: "USD", panelThreshold: nil, localThreshold: 20)
        let saved = try JSONEncoder().encode(watch)
        var relaunched = try JSONDecoder().decode(RegistrarBalanceWatch.self, from: saved)
        #expect(relaunched.notifiedLow)
        #expect(relaunched.observe(available: 3, currency: "USD", panelThreshold: nil, localThreshold: 20) == nil)
        #expect(relaunched.lowEvent(available: 3, currency: "USD", threshold: 20, localThreshold: 20) == nil)
    }

    // MARK: Phone and settings

    @Test func phoneSnapshotFieldIsOptional() throws {
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.registrarBalance))
        var plan = RemoteServerPlan(servers: [], deploys: [])
        plan.registrarBalance = RemoteServerPlan.Balance(available: 15, currency: "USD", threshold: 20, low: true)
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(RemoteServerPlan.self, from: data) == plan)
        // An older Mac's snapshot (no field) still decodes.
        let old = try JSONDecoder().decode(RemoteServerPlan.self, from: Data(#"{"servers":[],"deploys":[]}"#.utf8))
        #expect(old.registrarBalance == nil)
    }

    @Test func settingDefaultsTo20() throws {
        #expect(DeckSettings().serverPlanBalanceAlert == 20)
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data("{}".utf8))
        #expect(old.serverPlanBalanceAlert == 20)
        let off = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"serverPlanBalanceAlert":0}"#.utf8))
        #expect(off.serverPlanBalanceAlert == 0)
        let negative = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"serverPlanBalanceAlert":-5}"#.utf8))
        #expect(negative.serverPlanBalanceAlert == 0)
    }
}
