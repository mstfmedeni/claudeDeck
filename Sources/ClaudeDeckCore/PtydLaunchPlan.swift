import Darwin
import Foundation

/// Where a session's process lives when it runs in `claudedeck-ptyd`. Saved with the session
/// (DeckSession.helperHost), so a launch after a quit, a crash or an update knows whether the
/// process may still be alive and must be reattached instead of resumed.
public struct PtydHost: Codable, Sendable, Equatable {
    /// The helper process's instance id (a new one every time a helper starts).
    public var instance: String
    /// The child's pid (claude itself: the launch script execs it) and when it started.
    public var pid: Int32
    public var startedAt: Double

    public init(instance: String, pid: Int32, startedAt: Double) {
        self.instance = instance
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// What the app knows about the helper right now.
public enum PtydHelperState: Sendable, Equatable {
    /// Not asked yet (or the answer is on its way): nothing that might be in the helper may start.
    case unknown
    /// No helper runs: nothing listens on the socket and nobody holds its lock.
    case gone
    /// A helper holds the lock but doesn't answer (hung, or busy starting).
    case unresponsive
    /// A helper answered.
    case live(instance: String, compatibility: PtydCompatibility, sessions: [String: PtydSessionInfo])
}

/// The decision for one deck session at launch, on selection, or after the helper went away.
public enum PtydGate: Sendable, Equatable {
    /// Alive in the helper: attach to it (scrollback, then live). Never start it again.
    case attach(PtydSessionInfo)
    /// Alive in a helper this app can't drive: show it, read-only. Never start it again.
    case attachReadOnly(PtydSessionInfo)
    /// Its process ended in the helper while the app was away: it's over, like `/exit`.
    case ended(PtydSessionInfo?)
    /// Can't tell whether the process is alive: leave it alone (no resume).
    case hold(HoldReason)
    /// Not in a helper (or the helper that had it is gone and so is the process): today's path
    /// (resume if it was open, etc.).
    case proceed

    public enum HoldReason: Sendable, Equatable {
        case helperUnknown
        case helperUnresponsive
        /// The helper that ran it is gone, but the process still runs (it ignored SIGHUP).
        case processStillRunning
    }
}

public enum PtydLaunchPlan {
    /// The attach-or-resume decision table. The one rule above all: a session the helper
    /// reports alive is attached, never resumed — whatever else the deck says.
    ///
    /// | helper                     | in helper's list | host saved      | → gate          |
    /// |----------------------------|------------------|-----------------|-----------------|
    /// | live (full)                | alive            | any             | attach          |
    /// | live (read-only)           | alive            | any             | attachReadOnly  |
    /// | any                        | –                | none            | proceed         |
    /// | unknown                    | –                | yes             | hold            |
    /// | unresponsive               | –                | yes             | hold            |
    /// | live, same instance        | exited / missing | yes             | ended           |
    /// | live, other instance, gone | –                | yes, pid alive  | hold            |
    /// | live, other instance, gone | –                | yes, pid gone   | proceed         |
    ///
    /// - Parameter processAlive: whether `host`'s child still runs (pid and start time match).
    public static func gate(sessionID: UUID, host: PtydHost?, helper: PtydHelperState,
                            processAlive: (PtydHost) -> Bool) -> PtydGate {
        if case .live(_, let compatibility, let sessions) = helper, let info = sessions[sessionID.uuidString], info.alive {
            return compatibility == .readOnly ? .attachReadOnly(info) : .attach(info)
        }
        guard let host else { return .proceed }
        switch helper {
        case .unknown:
            return .hold(.helperUnknown)
        case .unresponsive:
            return .hold(.helperUnresponsive)
        case .live(let instance, _, let sessions) where instance == host.instance:
            // The same helper that started it doesn't have it alive: it exited while we were away.
            return .ended(sessions[sessionID.uuidString])
        case .live, .gone:
            // The helper that had it is gone; its children got SIGHUP. One that didn't exit
            // must not get a twin.
            return processAlive(host) ? .hold(.processStillRunning) : .proceed
        }
    }

    /// Restart: whether the old process is gone everywhere `launch` looks, so the new one may
    /// start. The terminal must no longer count it as running, and the helper (when it ran there)
    /// must have reported its exit: until that notice arrives the helper's list still says
    /// alive, and `launch` would attach to the dying process instead of starting a new one (the
    /// attach then fails and the terminal is left ended). The notice can come after the pid is
    /// gone (`kill -0` fails once the helper has reaped it, the notice is sent after that).
    public static func restartMayLaunch(sessionID: UUID, terminalRunning: Bool, helper: PtydHelperState) -> Bool {
        guard !terminalRunning else { return false }
        if case .live(_, _, let sessions) = helper, sessions[sessionID.uuidString]?.alive == true { return false }
        return true
    }

    /// Whether the helper's exit notice for a terminal is about the process it shows now. A
    /// restart stops the old process and starts a new one under the same session id; the old
    /// one's notice can arrive after that, and must not end (or fail) the new run.
    /// - Parameters:
    ///   - currentPID: the pid the terminal runs in the helper (nil while the spawn's answer is
    ///     on its way).
    ///   - retiredPIDs: processes this terminal stopped itself (a restart, End Session).
    public static func exitNoticeApplies(noticePID: Int32, currentPID: Int32?, retiredPIDs: Set<Int32>) -> Bool {
        if retiredPIDs.contains(noticePID) { return false }
        if let currentPID, currentPID > 0, noticePID > 0, currentPID != noticePID { return false }
        return true
    }

    /// Whether `pid` still runs the process that started at `startedAt` (a reused pid doesn't count).
    public static func processAlive(_ host: PtydHost) -> Bool {
        guard host.pid > 0 else { return false }
        guard let started = processStartTime(host.pid) else { return false }
        // Same process if it started within a couple of seconds of what the helper recorded.
        return abs(started - host.startedAt) < 3
    }

    /// Start time of a running process (seconds since 1970), nil if there's no such process.
    public static func processStartTime(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return nil }
        // A zombie still has an entry; it's gone for our purposes.
        if info.pbi_status == UInt32(SZOMB) { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }
}
