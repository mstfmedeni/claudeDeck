import CryptoKit
import Foundation
import Testing
@testable import ClaudeDeckCore

/// Moving remote.json's keys into the Keychain: never losing the host key (a paired phone would
/// have to pair again), never deleting what can't be read, and loading again being harmless.
/// A stub stands in for the Keychain; files go to a temporary folder.
@Suite struct RemoteSecretsMigrationTests {
    final class StubStore: RemoteSecretStore {
        var items: [RemoteSecret: Data] = [:]
        var failWrites = false
        var failDeletes = false
        /// Writes "succeed" but nothing reads back.
        var forgetful = false
        /// Reads fail as a locked Keychain's would.
        var locked = false
        var writes = 0
        var deletes = 0

        func read(_ secret: RemoteSecret) -> RemoteSecretRead {
            if locked { return .unavailable(-25308) }
            if forgetful { return .missing }
            return items[secret].map { .found($0) } ?? .missing
        }

        func write(_ secret: RemoteSecret, _ data: Data) -> Bool {
            writes += 1
            guard !failWrites, !locked else { return false }
            items[secret] = data
            return true
        }

        func delete(_ secret: RemoteSecret) -> Bool {
            deletes += 1
            guard !failDeletes, !locked else { return false }
            items[secret] = nil
            return true
        }
    }

    private let folder = FileManager.default.temporaryDirectory.appending(path: "remote-secrets-\(UUID().uuidString)")
    private var url: URL { folder.appending(path: "remote.json") }
    private let pem = P256.Signing.PrivateKey().pemRepresentation

    /// remote.json as versions before the Keychain wrote it: every key in the file.
    private func writeLegacyFile(hostKey: Data, passwordKey: Data? = Data(repeating: 9, count: 32), apns: Bool = true) throws -> RemoteLocalState {
        var state = RemoteLocalState()
        state.hostKey = hostKey
        state.hostUsesPassword = true
        state.passwordKey = passwordKey
        state.lastHostAddress = "mac.tail.ts.net"
        if apns { state.apns = APNsCredentials(keyID: "KEY123", teamID: "TEAM45", keyPEM: pem) }
        state.pushDevices = [PushDevice(token: Data(repeating: 1, count: 32), topic: "co.example.app", environment: "production", name: "iPhone", addedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        try state.save(to: url)
        return state
    }

    private func fileJSON() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test func legacyFileFieldsAreMovedAndTheKeysStayTheSame() throws {
        defer { cleanUp() }
        let hostKey = RemotePairing.makeKey()
        let legacy = try writeLegacyFile(hostKey: hostKey)
        // The legacy file really has them (the fixture is what older versions wrote).
        #expect(try fileJSON()["hostKey"] != nil && fileJSON()["passwordKey"] != nil)
        let store = StubStore()

        let state = RemoteLocalStore.load(from: url, secrets: store)
        #expect(state.hostID == legacy.hostID)
        #expect(state.hostKey == hostKey && state.hasHostKey)
        #expect(state.passwordKey == legacy.passwordKey)
        #expect(state.apns == legacy.apns)
        #expect(state.pushDevices == legacy.pushDevices && state.lastHostAddress == legacy.lastHostAddress && state.hostUsesPassword)
        #expect(store.items == [.hostKey: hostKey, .passwordKey: legacy.passwordKey!, .apnsKey: Data(pem.utf8)])
        // Out of the file, which says where they went; the APNs ids stay.
        let json = try fileJSON()
        #expect(json["hostKey"] == nil && json["passwordKey"] == nil)
        #expect((json["apns"] as? [String: Any])?["keyPEM"] as? String == "")
        #expect((json["apns"] as? [String: Any])?["keyID"] as? String == "KEY123")
        #expect(json["keychain"] as? [String] == ["apnsKey", "hostKey", "passwordKey"])
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // Again (every launch): the same state, nothing written anywhere.
        let bytes = try Data(contentsOf: url)
        let writes = store.writes
        let again = RemoteLocalStore.load(from: url, secrets: store)
        #expect(again.hostKey == hostKey && again.passwordKey == legacy.passwordKey && again.apns == legacy.apns && again.hostID == legacy.hostID)
        #expect(store.writes == writes)
        #expect(try Data(contentsOf: url) == bytes)

        // A save of something else doesn't write the Keychain again.
        var changed = again
        changed.lastHostAddress = "100.81.1.1"
        try RemoteLocalStore.save(&changed, to: url, secrets: store)
        #expect(store.writes == writes)
        #expect(RemoteLocalStore.load(from: url, secrets: store).hostKey == hostKey)
    }

    @Test func aKeychainThatFailsLeavesTheFileAsItWas() throws {
        defer { cleanUp() }
        let hostKey = RemotePairing.makeKey()
        _ = try writeLegacyFile(hostKey: hostKey)
        let store = StubStore()
        store.failWrites = true
        let state = RemoteLocalStore.load(from: url, secrets: store)
        #expect(state.hostKey == hostKey && state.hasHostKey)
        #expect(try fileJSON()["hostKey"] != nil && fileJSON()["keychain"] == nil)

        // Written but not readable back: not trusted either.
        store.failWrites = false
        store.forgetful = true
        _ = RemoteLocalStore.load(from: url, secrets: store)
        #expect(try fileJSON()["hostKey"] != nil && fileJSON()["passwordKey"] != nil)

        // Working again: moved on the next launch.
        store.forgetful = false
        let moved = RemoteLocalStore.load(from: url, secrets: store)
        #expect(moved.hostKey == hostKey)
        #expect(try fileJSON()["hostKey"] == nil)
        #expect(store.items[.hostKey] == hostKey)
    }

    @Test func aLockedKeychainNeverCostsTheKey() throws {
        defer { cleanUp() }
        let hostKey = RemotePairing.makeKey()
        _ = try writeLegacyFile(hostKey: hostKey)
        let store = StubStore()
        _ = RemoteLocalStore.load(from: url, secrets: store)
        #expect(try fileJSON()["hostKey"] == nil)

        // Next launch, the Keychain doesn't answer: no key, no new key either.
        store.locked = true
        var state = RemoteLocalStore.load(from: url, secrets: store)
        #expect(!state.hasHostKey && state.unreadSecrets == [.hostKey, .passwordKey, .apnsKey])
        #expect(state.apns?.keyID == "KEY123")
        // Saving meanwhile keeps them listed and touches nothing in the Keychain.
        state.lastHostAddress = "elsewhere"
        let deletes = store.deletes
        try RemoteLocalStore.save(&state, to: url, secrets: store)
        #expect(store.deletes == deletes)
        #expect(try fileJSON()["keychain"] as? [String] == ["apnsKey", "hostKey", "passwordKey"])
        #expect(try fileJSON()["hostKey"] == nil)
        #expect(store.items[.hostKey] == hostKey)

        // Unlocked: read again, the same key.
        #expect(!RemoteLocalStore.readSecrets(&state, secrets: store))
        store.locked = false
        #expect(RemoteLocalStore.readSecrets(&state, secrets: store))
        #expect(state.hostKey == hostKey && state.hasHostKey && state.unreadSecrets.isEmpty)
        #expect(state.apns?.keyPEM == pem)
        #expect(RemoteLocalStore.load(from: url, secrets: store).hostKey == hostKey)
    }

    @Test func aMissingHostKeyIsNotSilentlyReplaced() throws {
        defer { cleanUp() }
        _ = try writeLegacyFile(hostKey: RemotePairing.makeKey())
        let store = StubStore()
        _ = RemoteLocalStore.load(from: url, secrets: store)
        // The item went (deleted by hand, another Keychain).
        store.items = [:]
        var state = RemoteLocalStore.load(from: url, secrets: store)
        #expect(!state.hasHostKey)
        // The password and APNs keys just count as removed.
        #expect(state.passwordKey == nil && state.apns == nil)
        // New Key (or a password) sets one, which is saved as usual.
        let fresh = RemotePairing.makeKey()
        state.hostKey = fresh
        #expect(state.hasHostKey)
        try RemoteLocalStore.save(&state, to: url, secrets: store)
        #expect(store.items[.hostKey] == fresh)
        #expect(RemoteLocalStore.load(from: url, secrets: store).hostKey == fresh)
    }

    @Test func aKeyInTheFileWinsOverTheKeychain() throws {
        defer { cleanUp() }
        // Moved, then an older ClaudeDeck ran and wrote a key into the file again.
        let store = StubStore()
        store.items[.hostKey] = RemotePairing.makeKey()
        let current = RemotePairing.makeKey()
        _ = try writeLegacyFile(hostKey: current)
        let state = RemoteLocalStore.load(from: url, secrets: store)
        #expect(state.hostKey == current)
        #expect(store.items[.hostKey] == current)
        #expect(try fileJSON()["hostKey"] == nil)
    }

    @Test func aRemovedSecretDoesNotComeBack() throws {
        defer { cleanUp() }
        _ = try writeLegacyFile(hostKey: RemotePairing.makeKey())
        let store = StubStore()
        var state = RemoteLocalStore.load(from: url, secrets: store)
        // Remove Password with a Keychain that won't delete: the file stops pointing at it.
        store.failDeletes = true
        state.passwordKey = nil
        try RemoteLocalStore.save(&state, to: url, secrets: store)
        #expect(store.items[.passwordKey] != nil)
        #expect(RemoteLocalStore.load(from: url, secrets: store).passwordKey == nil)
        // APNs key removed: gone from both.
        store.failDeletes = false
        state.apns = nil
        try RemoteLocalStore.save(&state, to: url, secrets: store)
        #expect(store.items[.apnsKey] == nil)
        #expect(RemoteLocalStore.load(from: url, secrets: store).apns == nil)
    }

    @Test func aNewInstallGetsItsKeyInTheKeychain() throws {
        defer { cleanUp() }
        let store = StubStore()
        let state = RemoteLocalStore.load(from: url, secrets: store)
        #expect(state.hasHostKey)
        #expect(store.items[.hostKey] == state.hostKey)
        #expect(try fileJSON()["hostKey"] == nil)
        #expect(RemoteLocalStore.load(from: url, secrets: store).hostKey == state.hostKey)
    }

    @Test func privateFilesAre0600FromTheStart() throws {
        defer { cleanUp() }
        let file = folder.appending(path: "secret.json")
        try PrivateFile.write(Data("one".utf8), to: file)
        try PrivateFile.write(Data("two".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // No temporary files left next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["secret.json"])
    }

    @Test func demoCopiesKeepSecretsInAFile() throws {
        defer { cleanUp() }
        let store = FileSecretStore(url: folder.appending(path: "remote-secrets.json"))
        #expect(store.read(.hostKey) == .missing)
        let key = RemotePairing.makeKey()
        #expect(store.write(.hostKey, key))
        #expect(store.read(.hostKey) == .found(key))
        #expect(store.delete(.hostKey) && store.read(.hostKey) == .missing)
        let state = RemoteLocalStore.load(from: url, secrets: store)
        #expect(store.read(.hostKey) == .found(state.hostKey))
    }
}
