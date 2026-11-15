import Darwin
import Foundation

/// Whether anyone can see the app's UI, from what macOS reports. Work that only feeds the screen
/// (animations, relative-time ticks, polling for a page) pauses when nobody can.
///
/// The screen counts as seen when a display is awake and this login session is the active,
/// unlocked console — or when a Screen Sharing session is connected: with the monitor powered
/// off, a remote viewer still sees everything (often on a virtual display).
public struct UIVisibility: Equatable, Sendable {
    /// Some window (main, editor, the menu bar panel) is ordered in and not fully covered.
    public var windowOnScreen = true
    /// The app is hidden (⌘H).
    public var appHidden = false
    /// The displays went to sleep (`screensDidSleepNotification`).
    public var displaysAsleep = false
    /// At least one screen is attached (a monitor on a cut-off smart plug leaves none).
    public var hasScreens = true
    /// This login session owns the console (not switched away with fast user switching).
    public var sessionActive = true
    public var screenLocked = false
    /// A Screen Sharing session to this Mac is connected.
    public var screenSharing = false

    public init() {}

    /// The screen itself can be seen: the menu bar label is worth updating.
    public var screenVisible: Bool {
        screenSharing || (!displaysAsleep && hasScreens && sessionActive && !screenLocked)
    }

    /// A window can be seen: its animations, ticks and page polling are worth running.
    public var windowsVisible: Bool {
        screenSharing || (screenVisible && windowOnScreen && !appHidden)
    }

    /// Whether to look for a Screen Sharing session every so often: only while the local signals
    /// say nobody can see a window, since then a connected viewer is the only way anyone could.
    public var needsSharingCheck: Bool {
        var local = self
        local.screenSharing = false
        return !local.windowsVisible
    }
}

/// Spots a connected macOS Screen Sharing session without shelling out.
///
/// launchd owns the listening socket (port 5900) and starts `screensharingd` for a connection;
/// the daemon exits when the viewer disconnects. So a process with that name exists exactly while
/// someone is connected — in every mode, High Performance (UDP, other ports) included — and the
/// process list (one sysctl) is cheaper and needs fewer rights than reading socket tables.
public enum ScreenSharingDetector {
    public static let daemonName = "screensharingd"

    /// Whether `name` (a process's short name, at most 16 characters) is the sharing daemon.
    public static func isSharingProcess(_ name: String) -> Bool { name == daemonName }

    public static func isSessionActive() -> Bool {
        processNames().contains(where: isSharingProcess)
    }

    /// Short names of all processes (`kinfo_proc.kp_proc.p_comm`).
    public static func processNames() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for processes started between the two calls.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { proc in
            withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }
}
