import Darwin
import Foundation

/// Where the helper's socket and lock live: next to deck.json (Application Support/ClaudeDeck,
/// or `CLAUDEDECK_DATA_DIR` in demo mode), so a demo never meets the real app's helper.
public struct PtydPaths: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The app's data folder (same rule as `DeckDataStore.default()`).
    public static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> PtydPaths {
        if let dir = environment["CLAUDEDECK_DATA_DIR"], !dir.isEmpty {
            return PtydPaths(directory: URL(fileURLWithPath: dir))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PtydPaths(directory: base.appending(path: "ClaudeDeck"))
    }

    public var socket: URL { directory.appending(path: "ptyd.sock") }
    /// Held (flock) by the running helper for its whole life; it also holds the helper's pid.
    public var lock: URL { directory.appending(path: "ptyd.lock") }
    public var log: URL { directory.appending(path: "ptyd.log") }

    /// The helper's launchd label: the app's bundle id + ".ptyd"; demo mode gets ".ptyd.demo".
    public static func label(bundleID: String, demo: Bool) -> String {
        bundleID + (demo ? ".ptyd.demo" : ".ptyd")
    }

    /// Whether a helper holds the lock right now (it's alive, maybe not answering).
    public func helperHoldsLock() -> Bool {
        let fd = open(lock.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// The pid the helper wrote into its lock file (meaningful only while it holds the lock).
    public func lockHolderPID() -> pid_t? {
        guard let text = try? String(contentsOf: lock, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }
}
