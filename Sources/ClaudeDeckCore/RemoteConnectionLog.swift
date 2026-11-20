import Foundation

/// The phone's last connection attempts, for "can't connect" reports (Settings › Connection Log).
/// In memory only; each attempt is one address tried one way (or skipped), plus the waits between rounds.
public struct RemoteConnectionLog: Sendable, Equatable {
    /// How an address was reached.
    public enum Route: String, Sendable, Equatable, CaseIterable {
        /// This network: a Bonjour name, a private IP or a `.local` name.
        case lan
        /// A tailnet address through the system (the Tailscale app's VPN).
        case tailscale
        /// A tailnet address through the app's own Tailscale node.
        case inAppTailscale
        /// Anything else (a public name or address typed in Settings).
        case other

        public static func of(address: String, via route: RemoteRoute) -> Route {
            if route == .inApp { return .inAppTailscale }
            if InAppTailscale.isTailnetAddress(address) { return .tailscale }
            if isLocal(address) { return .lan }
            return .other
        }

        static func isLocal(_ address: String) -> Bool {
            if RemoteBonjour.serviceName(of: address) != nil { return true }
            let lower = address.lowercased()
            if lower.hasSuffix(".local") || lower.hasSuffix(".local.") || lower == "localhost" { return true }
            let octets = address.split(separator: ".").compactMap { Int($0) }
            if octets.count == 4 {
                return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168)
                    || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 169 && octets[1] == 254)
            }
            guard lower.contains(":") else { return false }
            return lower.hasPrefix("fe80:") || (lower.hasPrefix("fd") && !lower.hasPrefix("fd7a:115c:a1e0"))
        }
    }

    /// How one attempt ended.
    public enum Outcome: Sendable, Equatable {
        case connected
        /// Unreachable, timed out, or closed before the pairing was proved.
        case failed(String?)
        /// A ClaudeDeck answered and said no (wrong key, old version).
        case refused(String)
        /// Another way got in first, or the attempt was called off.
        case cancelled
        /// Not tried: it can't work from here (another subnet, the Tailscale VPN off).
        case skipped(String)
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case attempt(address: String, route: Route, outcome: Outcome, duration: TimeInterval)
            /// Waiting this long before the next round (after `reason`).
            case backoff(wait: TimeInterval, reason: String)
        }

        public var id: Int
        /// When the attempt started / the wait began.
        public var at: Date
        public var kind: Kind
    }

    public static let capacity = 50

    /// Oldest first.
    public private(set) var entries: [Entry] = []
    private var nextID = 0

    public init() {}

    public mutating func attempt(address: String, route: RemoteRoute, startedAt: Date, outcome: Outcome, now: Date = Date()) {
        append(Entry(id: 0, at: startedAt, kind: .attempt(address: address, route: Route.of(address: address, via: route),
                                                          outcome: outcome, duration: max(0, now.timeIntervalSince(startedAt)))))
    }

    public mutating func backoff(wait: TimeInterval, reason: String, at: Date = Date()) {
        append(Entry(id: 0, at: at, kind: .backoff(wait: wait, reason: reason)))
    }

    public mutating func removeAll() { entries = [] }

    private mutating func append(_ entry: Entry) {
        var entry = entry
        entry.id = nextID
        nextID += 1
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// Plain text for support, newest first: one line per entry.
    public func text(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return entries.reversed().map { entry in
            let time = formatter.string(from: entry.at)
            switch entry.kind {
            case .attempt(let address, let route, let outcome, let duration):
                let result: String
                switch outcome {
                case .connected: result = "connected"
                case .failed(let reason): result = "failed" + (reason.map { ": \($0)" } ?? "")
                case .refused(let reason): result = "refused: \(reason)"
                case .cancelled: result = "cancelled"
                case .skipped(let reason): result = "skipped: \(reason)"
                }
                return "\(time) \(address) [\(route.rawValue)] \(result) (\(String(format: "%.2f", duration)) s)"
            case .backoff(let wait, let reason):
                return "\(time) retry in \(String(format: "%.0f", wait)) s after: \(reason)"
            }
        }.joined(separator: "\n")
    }
}
