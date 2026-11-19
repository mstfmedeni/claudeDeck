import Foundation

// ServerPlan 1.4: the Namecheap (registrar) balance. `GET /registrar/balance` (cached 5 min on the
// panel; `?refresh=1` asks Namecheap again), and the low-balance watch the Mac runs on it: the
// panel's own `registrar.low_balance` / `registrar.balance_ok` events and the balances it fetches
// feed one edge-triggered state, so the owner hears about a low balance once per crossing.

/// `GET /registrar/balance`.
public struct ServerPlanRegistrarBalance: Decodable, Sendable, Equatable {
    public var available: Double
    public var account: Double?
    public var currency: String
    /// The panel's threshold; nil when the owner set none there.
    public var lowThreshold: Double?
    /// The panel's verdict (available < its threshold).
    public var low: Bool
    public var checkedAt: Date?

    public init(available: Double, account: Double? = nil, currency: String = "USD", lowThreshold: Double? = nil, low: Bool = false,
                checkedAt: Date? = nil) {
        self.available = available
        self.account = account
        self.currency = currency
        self.lowThreshold = lowThreshold
        self.low = low
        self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case available = "available_balance", account = "account_balance", currency, lowThreshold = "low_threshold", low, checkedAt = "checked_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decode(Double.self, forKey: .available)
        account = try? c.decodeIfPresent(Double.self, forKey: .account)
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? "USD"
        lowThreshold = (try? c.decodeIfPresent(Double.self, forKey: .lowThreshold)).flatMap { $0 > 0 ? $0 : nil }
        low = (try? c.decodeIfPresent(Bool.self, forKey: .low)) ?? false
        // Go's RFC 3339 with nanoseconds and an offset; a date it can't read doesn't lose the balance.
        checkedAt = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .checkedAt))?.value
    }

    /// "15", "15.50": whole amounts without decimals.
    public static func format(_ amount: Double) -> String {
        let cents = (amount * 100).rounded()
        return cents.truncatingRemainder(dividingBy: 100) == 0 ? String(format: "%.0f", cents / 100) : String(format: "%.2f", cents / 100)
    }
}

extension ServerPlanClient {
    /// `GET /registrar/balance` (scope read). A 412 `not_configured` (no Namecheap in the panel)
    /// is `ServerPlanError.http(412, "not_configured", …)`.
    public func registrarBalance(refresh: Bool = false) async throws -> ServerPlanRegistrarBalance {
        try await get(ServerPlanRegistrarBalance.self, "/registrar/balance", query: refresh ? [URLQueryItem(name: "refresh", value: "1")] : [])
    }
}

extension ServerPlanMe {
    /// The panel serves the registrar balance (1.4 or later, or the feature named) to this token.
    public var offersRegistrarBalance: Bool {
        guard let command = ServerPlanCLI.commands["balance"] else { return false }
        return ServerPlanCLI.offers(command, me: self)
    }
}

/// The low-balance alert, edge-triggered and kept across launches: the owner is told once when
/// the balance goes under the threshold, and again only after it was back at or above it.
///
/// The threshold is the panel's (`low_threshold`) when it has one, else ClaudeDeck's own setting;
/// 0 there means off. The panel's events and the balances fetched here go through the same state,
/// so a fetch and an event about the same drop notify once, and a panel restart (its own edge
/// state is in memory and fires again) doesn't repeat it.
public struct RegistrarBalanceWatch: Codable, Sendable, Equatable {
    /// The owner was told the balance is low, and it hasn't been seen recovered since.
    public var notifiedLow = false

    public init(notifiedLow: Bool = false) {
        self.notifiedLow = notifiedLow
    }

    /// What to tell the owner.
    public struct Notice: Sendable, Equatable {
        public var available: Double
        public var currency: String
        public var threshold: Double
    }

    /// The threshold in force: the panel's (> 0), else the local one (> 0), else none (off).
    public static func threshold(panel: Double?, local: Double) -> Double? {
        if let panel, panel > 0 { return panel }
        return local > 0 ? local : nil
    }

    /// A balance seen (fetched, or carried by an event). Returns the notice to send, if this is a
    /// crossing below the threshold.
    public mutating func observe(available: Double, currency: String, panelThreshold: Double?, localThreshold: Double) -> Notice? {
        guard let threshold = Self.threshold(panel: panelThreshold, local: localThreshold) else {
            notifiedLow = false  // off: re-armed for when it's turned on again
            return nil
        }
        guard available < threshold else {
            notifiedLow = false
            return nil
        }
        guard !notifiedLow else { return nil }
        notifiedLow = true
        return Notice(available: available, currency: currency, threshold: threshold)
    }

    /// `registrar.low_balance`: the panel says it's under its own threshold.
    public mutating func lowEvent(available: Double?, currency: String?, threshold: Double?, localThreshold: Double) -> Notice? {
        let limit = Self.threshold(panel: threshold, local: localThreshold)
        guard let limit else { return nil }
        guard !notifiedLow else { return nil }
        notifiedLow = true
        // An event without the amount (it always has one) still warns, with the threshold.
        return Notice(available: available ?? limit, currency: currency ?? "USD", threshold: limit)
    }

    /// `registrar.balance_ok`: re-armed. Returns whether a low notice was out (to withdraw it).
    @discardableResult
    public mutating func okEvent() -> Bool {
        defer { notifiedLow = false }
        return notifiedLow
    }
}
