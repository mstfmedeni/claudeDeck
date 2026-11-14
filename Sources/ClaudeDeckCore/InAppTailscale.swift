import Foundation

// Pure parts of the iPhone/iPad app's optional in-app Tailscale node (the node itself, with
// TailscaleKit, lives in the iOS target): its name and tag, and which way to reach an address.

/// How one address is reached.
public enum RemoteRoute: String, Sendable, Equatable, Codable {
    /// The system's network (Wi-Fi, cellular, a VPN such as the Tailscale app).
    case system
    /// The app's own Tailscale node (userspace; works whatever VPN is on).
    case inApp
}

public enum InAppTailscale {
    /// The ACL tag every in-app node registers with. Only users listed as its owner in the
    /// tailnet policy (`tagOwners`) can sign the node in; tagged nodes don't expire.
    public static let tag = "tag:claudedeck"
    public static let advertiseTags = [tag]

    /// Prefix of the node's Tailscale name.
    public static let appName = "claudedeck"
    /// How long the system route gets for a tailnet address before the in-app node is tried
    /// (another VPN can claim 100.64.0.0/10 and black-hole it).
    public static let systemTryTimeout: TimeInterval = 2

    /// The node's Tailscale hostname: `claudedeck-<device name>`, DNS-safe (a–z, 0–9, '-';
    /// no repeats or trailing dashes; at most 63 characters). "Mustafa's iPhone" →
    /// `claudedeck-mustafas-iphone`. iOS gives apps only the model ("iPhone") without the
    /// user-assigned-device-name entitlement: then it's `claudedeck-iphone` (Tailscale adds a
    /// number to duplicates).
    public static func hostname(deviceName: String, model: String) -> String {
        let device = sanitize(deviceName)
        let suffix = device.isEmpty ? sanitize(model) : device
        let name = suffix.isEmpty ? appName : appName + "-" + suffix
        return trimmed(String(name.prefix(63)))
    }

    /// Lowercase a–z, 0–9 and single dashes, nothing at either end.
    static func sanitize(_ text: String) -> String {
        // Fold accents first ("İ" would otherwise lowercase to "i" + a combining dot).
        let folded = text
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        for scalar in folded.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9": result.unicodeScalars.append(scalar)
            // "Mustafa's" → "mustafas", not "mustafa-s".
            case "'", "\u{2019}", "\u{2018}", "\u{02BC}", "`": continue
            default: if !result.hasSuffix("-") { result += "-" }
            }
        }
        return trimmed(result)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The login failed because the tailnet doesn't let this user apply the tag (control says
    /// "requested tags [...] are invalid or not permitted").
    public static func isTagRejection(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("requested tags") || lower.contains("tagowner") { return true }
        return lower.contains("tag:") && (lower.contains("not permitted") || lower.contains("invalid"))
    }

    /// A Tailscale address: 100.64.0.0/10, fd7a:115c:a1e0::/48 or a MagicDNS name (*.ts.net).
    public static func isTailnetAddress(_ address: String) -> Bool {
        let host = address.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasSuffix(".ts.net") || host.hasSuffix(".ts.net.") { return true }
        return Tailscale.isTailscaleIP(host)
    }

    /// The ways to try `address`, in order (each next one only when the one before failed).
    /// - Not a tailnet address, or the in-app node is off: the system only (today's behaviour).
    /// - The in-app node is on: the system first (the Tailscale app may be on) with a short
    ///   timeout, then the node. When one of them worked on this network (`remembered`), that
    ///   one first; the node still backs up the system route.
    public static func routes(for address: String, inAppEnabled: Bool, remembered: RemoteRoute?) -> [RemoteRoute] {
        guard inAppEnabled, isTailnetAddress(address) else { return [.system] }
        return remembered == .inApp ? [.inApp, .system] : [.system, .inApp]
    }
}
