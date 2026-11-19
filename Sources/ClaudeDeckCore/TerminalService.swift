import Foundation

// Service terminals: a plain terminal (Program Status on) whose command serves rather than works —
// a dev server, `npm run dev`, a watcher. Without this it would show "Running" forever and fill
// the Working filter and counts.
//
// A command becomes a service when it has run for `minimumRunTime` and it or one of its
// descendant processes listens on a TCP port (`ListeningPorts`, probed at most every
// `pollInterval`, only for terminals whose command is running). The user can mark a terminal
// either way by hand (`DeckSession.serviceOverride`), which covers watchers without a port and
// the opposite case. What a program reports itself (OSC 7501) is never turned into a service by
// the probe. A service still ends like any command: finished or failed, with its notification.

public enum TerminalService {
    /// A command must have run this long before it is probed.
    public static let minimumRunTime: TimeInterval = 20
    /// How often running commands are probed.
    public static let pollInterval: TimeInterval = 10

    /// Whether the terminal's command should be probed for listening ports now. `commandSince`
    /// is `ProgramStatusMonitor.commandSince` (nil: nothing a shell runs). `override` is the
    /// user's mark: false never probes; true probes at once (for the ports it shows).
    public static func shouldProbe(commandSince: Date?, override: Bool?, now: Date) -> Bool {
        guard override != false, let commandSince else { return false }
        if override == true { return true }
        return now.timeIntervalSince(commandSince) >= minimumRunTime
    }

    /// The user's mark on top of what the terminal reports: "service" turns a running command
    /// (or program) into a service, "not a service" turns one back; blocked, finished and failed
    /// are left alone, so a crashed server is still noticed.
    public static func applying(override: Bool?, to status: ProgramStatus) -> ProgramStatus {
        var status = status
        switch (override, status.state) {
        case (true?, .working):
            status.state = .service
        case (false?, .service):
            status.state = .working
            status.ports = nil
        default:
            break
        }
        return status
    }

    /// ":5050", ":3000, :5173", ":3000, :5173 +2".
    public static func portsLabel(_ ports: [Int]?, limit: Int = 2) -> String? {
        guard let ports, !ports.isEmpty else { return nil }
        let shown = ports.prefix(limit).map { ":\($0)" }.joined(separator: ", ")
        return ports.count > limit ? "\(shown) +\(ports.count - limit)" : shown
    }
}

#if os(macOS)
import Darwin

/// TCP ports that processes listen on, read with libproc (no `lsof` child process): a process
/// tree walk from the given roots (`proc_listchildpids`), then each process's socket descriptors.
/// Only processes of the same user can be read, which is all a terminal starts.
public enum ListeningPorts {
    /// Deep enough for shell → npm → sh → node → worker.
    public static let maxDepth = 6
    /// A runaway tree (a fork bomb, a build farm) isn't walked whole.
    public static let maxProcesses = 256

    /// For each root, the sorted TCP ports it or its descendants listen on (roots with none are
    /// absent). `includeRoot`: the root's own sockets count too.
    public static func scan(roots: [pid_t], includeRoot: Bool = false) -> [pid_t: [Int]] {
        var result: [pid_t: [Int]] = [:]
        for root in roots where root > 0 {
            var pids = descendants(of: root)
            if includeRoot { pids.insert(root, at: 0) }
            var ports = Set<Int>()
            for pid in pids { ports.formUnion(listening(pid)) }
            if !ports.isEmpty { result[root] = ports.sorted() }
        }
        return result
    }

    /// `root`'s descendants, breadth first, without `root`.
    public static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var level: [pid_t] = [root]
        var depth = 0
        while !level.isEmpty, depth < maxDepth, found.count < maxProcesses {
            var next: [pid_t] = []
            for pid in level { next += children(of: pid) }
            next = next.filter { $0 > 0 && $0 != root && !found.contains($0) }
            found += next
            level = next
            depth += 1
        }
        return Array(found.prefix(maxProcesses))
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 32
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let bytes = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<pid_t>.stride
            // A full buffer may have been cut short: ask again with more room.
            if count >= capacity, capacity < 4096 { capacity *= 4; continue }
            return Array(buffer.prefix(count))
        }
    }

    /// TCP ports `pid` listens on.
    public static func listening(_ pid: pid_t) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // A little headroom for descriptors opened in between.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard got == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.append(port) }
        }
        return ports
    }
}
#endif
