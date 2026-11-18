import Foundation
import Security

// Where remote mode's keys live at rest: the host key, the password key and the APNs .p8 key go
// to the Keychain; remote.json keeps the rest. Moving them is careful by design, since losing the
// host key unpairs every phone:
// - a key is left out of the file only after the Keychain gave the same bytes back;
// - a key the Keychain can't give back (locked, access denied) is never replaced or deleted,
//   only asked for again later;
// - a key still in the file wins over the Keychain (the file is written after the Keychain, so
//   it's the newer one), which makes loading again after any interruption safe.

/// What reading a secret gave.
public enum RemoteSecretRead: Equatable, Sendable {
    case found(Data)
    /// No such item: the Keychain answered and doesn't have it.
    case missing
    /// The Keychain didn't answer (locked, access denied, …): try again later.
    case unavailable(Int32)
}

/// Keeps the secrets (the Keychain; tests and demo copies use their own stores).
public protocol RemoteSecretStore: AnyObject {
    func read(_ secret: RemoteSecret) -> RemoteSecretRead
    /// Adds or replaces; false when it failed.
    func write(_ secret: RemoteSecret, _ data: Data) -> Bool
    /// False when it failed (an item that wasn't there counts as deleted).
    func delete(_ secret: RemoteSecret) -> Bool
}

/// Generic passwords in the login Keychain, one per secret, never synced.
public final class KeychainSecretStore: RemoteSecretStore {
    let service: String

    public init(service: String) { self.service = service }

    private func base(_ secret: RemoteSecret) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: secret.rawValue]
    }

    public func read(_ secret: RemoteSecret) -> RemoteSecretRead {
        var query = base(secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable(status) }
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    public func write(_ secret: RemoteSecret, _ data: Data) -> Bool {
        // Update in place first: deleting and adding again would leave a moment with no item.
        let update = SecItemUpdate(base(secret) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base(secret)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "ClaudeDeck remote \(secret.rawValue)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func delete(_ secret: RemoteSecret) -> Bool {
        let status = SecItemDelete(base(secret) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Secrets in a 0600 file of their own: demo copies, which never touch the real Keychain.
public final class FileSecretStore: RemoteSecretStore {
    let url: URL

    public init(url: URL) { self.url = url }

    private func all() -> [String: Data]? {
        guard let data = try? Data(contentsOf: url) else { return FileManager.default.fileExists(atPath: url.path) ? nil : [:] }
        return try? JSONDecoder().decode([String: Data].self, from: data)
    }

    public func read(_ secret: RemoteSecret) -> RemoteSecretRead {
        guard let all = all() else { return .unavailable(-1) }
        return all[secret.rawValue].map { .found($0) } ?? .missing
    }

    public func write(_ secret: RemoteSecret, _ data: Data) -> Bool {
        guard var all = all() else { return false }
        all[secret.rawValue] = data
        return (try? PrivateFile.write(JSONEncoder().encode(all), to: url)) != nil
    }

    public func delete(_ secret: RemoteSecret) -> Bool {
        guard var all = all() else { return false }
        guard all.removeValue(forKey: secret.rawValue) != nil else { return true }
        return (try? PrivateFile.write(JSONEncoder().encode(all), to: url)) != nil
    }
}

/// remote.json plus the Keychain.
public enum RemoteLocalStore {
    /// Reads the file, fills in the secrets the Keychain holds and moves the ones still in the
    /// file there (`save`). Idempotent: loading again finds them where the last load put them.
    public static func load(from url: URL, secrets: RemoteSecretStore) -> RemoteLocalState {
        var state = RemoteLocalState.read(from: url) ?? RemoteLocalState()
        let existed = FileManager.default.fileExists(atPath: url.path)
        readSecrets(&state, secrets: secrets)
        // Secrets still in the file go to the Keychain now (a new file is written either way).
        let inFile = RemoteSecret.allCases.contains { state.secretData($0) != nil && !state.keychainSecrets.contains($0) && !state.unreadSecrets.contains($0) }
        if inFile || !existed { try? save(&state, to: url, secrets: secrets) }
        return state
    }

    /// Asks the Keychain again for the secrets it didn't give back before. True when any came.
    @discardableResult
    public static func readSecrets(_ state: inout RemoteLocalState, secrets: RemoteSecretStore) -> Bool {
        var got = false
        for secret in RemoteSecret.allCases where state.keychainSecrets.contains(secret) && state.secretData(secret) == nil {
            switch secrets.read(secret) {
            case .found(let data) where !data.isEmpty:
                state.setSecretData(secret, data)
                state.verified[secret] = data
                got = true
            case .unavailable, .found:
                state.unreadSecrets.insert(secret)
            case .missing:
                if secret == .hostKey {
                    // Never a silent new key (every phone would need pairing again): the user
                    // chooses New Key or a password, which sets one.
                    state.unreadSecrets.insert(secret)
                } else {
                    // Gone: as if removed.
                    state.keychainSecrets.remove(secret)
                    if secret == .apnsKey { state.apns = nil }
                }
            }
        }
        return got
    }

    /// Writes each known secret to the Keychain and keeps it out of the file only once it reads
    /// back the same; then writes the file (0600, atomically). Secrets that couldn't be read
    /// stay listed and untouched.
    public static func save(_ state: inout RemoteLocalState, to url: URL, secrets: RemoteSecretStore) throws {
        for secret in RemoteSecret.allCases where !state.unreadSecrets.contains(secret) {
            if let value = state.secretData(secret) {
                // Already there with this value: no Keychain write on every save.
                if state.keychainSecrets.contains(secret), state.verified[secret] == value { continue }
                if secrets.write(secret, value), secrets.read(secret) == .found(value) {
                    state.keychainSecrets.insert(secret)
                    state.verified[secret] = value
                } else {
                    state.keychainSecrets.remove(secret)
                    state.verified[secret] = nil
                }
            } else if state.keychainSecrets.contains(secret) || state.verified[secret] != nil {
                // Removed (password, APNs key): the file no longer points at it, so a delete
                // that fails leaves an orphan item, never a value that comes back.
                _ = secrets.delete(secret)
                state.keychainSecrets.remove(secret)
                state.verified[secret] = nil
            }
        }
        try state.save(to: url)
    }
}
