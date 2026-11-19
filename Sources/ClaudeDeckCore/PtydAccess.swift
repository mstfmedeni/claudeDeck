import Darwin
import Foundation

/// Whether a process may open what macOS privacy (TCC) protects. The session helper
/// (`claudedeck-ptyd`) under launchd is its own responsible process: ClaudeDeck.app's Full Disk
/// Access or Desktop grant doesn't cover the sessions in it, and a new grant only applies once the
/// helper process restarts. The app runs this probe in-process and asks the helper to run it too
/// (`PtydOp.probeAccess`, protocol 2), then compares (Settings › Sessions, PtydBanner).
public enum PtydAccessState: String, Codable, Sendable, Equatable {
    case granted, denied, unknown
}

public struct PtydAccessReport: Codable, Sendable, Equatable {
    /// A file only Full Disk Access opens (TCC.db, else Safari's bookmarks).
    public var fullDiskAccess: PtydAccessState
    /// Listing ~/Desktop (Full Disk Access or the Desktop folder grant).
    public var desktop: PtydAccessState

    public init(fullDiskAccess: PtydAccessState, desktop: PtydAccessState) {
        self.fullDiskAccess = fullDiskAccess
        self.desktop = desktop
    }

    /// An old helper that doesn't know the request, a timeout, or no helper.
    public static let unknown = PtydAccessReport(fullDiskAccess: .unknown, desktop: .unknown)

    /// Tolerant decoding: a state a later build adds reads as unknown.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullDiskAccess = (try? c.decodeIfPresent(PtydAccessState.self, forKey: .fullDiskAccess)) ?? .unknown
        desktop = (try? c.decodeIfPresent(PtydAccessState.self, forKey: .desktop)) ?? .unknown
    }

    public enum Level: Sendable, Equatable {
        /// Full Disk Access.
        case full
        /// No Full Disk Access, but the Desktop folder.
        case desktopOnly
        /// Neither.
        case none
        case unknown
    }

    public var level: Level {
        switch fullDiskAccess {
        case .granted: .full
        case .denied: desktop == .granted ? .desktopOnly : .none
        case .unknown: .unknown
        }
    }

    /// The app can open something this report (the helper's) definitely can't. Unknown answers
    /// never count: an old helper or a failed probe shows no warning.
    public func lacks(comparedTo app: PtydAccessReport) -> Bool {
        (app.fullDiskAccess == .granted && fullDiskAccess == .denied)
            || (app.desktop == .granted && desktop == .denied)
    }
}

public enum PtydAccessProbe {
    /// The result of one open/list attempt from its errno (0: it worked). EPERM is how TCC
    /// refuses; a missing file (ENOENT) or anything else tells nothing.
    public static func classify(errno code: Int32) -> PtydAccessState {
        switch code {
        case 0: .granted
        case EPERM: .denied
        default: .unknown
        }
    }

    /// Files only Full Disk Access opens, in the order they are tried.
    public static func fullDiskAccessFiles(home: String) -> [String] {
        [home + "/Library/Application Support/com.apple.TCC/TCC.db", home + "/Library/Safari/Bookmarks.plist"]
    }

    /// The first file that gives an answer decides; one that is missing (or fails otherwise)
    /// passes to the next. `open` returns the errno of opening a path (0: opened).
    public static func fullDiskAccess(home: String, open: (String) -> Int32) -> PtydAccessState {
        for path in fullDiskAccessFiles(home: home) {
            let state = classify(errno: open(path))
            if state != .unknown { return state }
        }
        return .unknown
    }

    public static func desktop(home: String, list: (String) -> Int32) -> PtydAccessState {
        classify(errno: list(home + "/Desktop"))
    }

    /// Both probes for this process. Nothing is read or logged: a file is opened and closed, a
    /// folder opened and its first entry fetched (TCC refuses the listing, not always the open).
    public static func run(home: String = NSHomeDirectory()) -> PtydAccessReport {
        PtydAccessReport(fullDiskAccess: fullDiskAccess(home: home, open: openErrno),
                         desktop: desktop(home: home, list: listErrno))
    }

    /// Only the Full Disk Access probe (never touches ~/Desktop, so it can't raise a prompt).
    public static func runFullDiskAccess(home: String = NSHomeDirectory()) -> PtydAccessState {
        fullDiskAccess(home: home, open: openErrno)
    }

    static func openErrno(_ path: String) -> Int32 {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        Darwin.close(fd)
        return 0
    }

    static func listErrno(_ path: String) -> Int32 {
        guard let dir = opendir(path) else { return errno }
        defer { closedir(dir) }
        errno = 0
        if readdir(dir) == nil, errno != 0 { return errno }
        return 0
    }
}
