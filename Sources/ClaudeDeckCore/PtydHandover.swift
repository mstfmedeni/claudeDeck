import Darwin
import Foundation
import Security

/// Hot self-update of the session helper: what one image of `claudedeck-ptyd` hands to the next
/// when it re-execs itself into the updated binary (same pid, so the sessions' processes stay
/// its children and their ptys stay open).
///
/// Why: privacy (TCC) judges the helper by the code at its path on disk. After an update replaced
/// that file, the old image no longer matches it and every session in it loses Full Disk Access.
/// Exec'ing the new file makes the running code match the disk again without ending anything.
///
/// The state travels in an unlinked temporary file (mode 0600, in the helper's private folder)
/// whose descriptor survives the exec (`--resume-fd`): nothing is left on disk whatever happens.
/// Layout: "CDPH" magic, u32 header length (big endian), the JSON header, then each session's
/// scrollback bytes in session order (`scrollbackLength` each).
public struct PtydHandover: Codable, Sendable, Equatable {
    /// Bump when the layout changes; a new image must keep reading every older format (it only
    /// ever receives state from an older or equal build).
    public static let currentFormat = 1
    static let magic: [UInt8] = Array("CDPH".utf8)
    /// Never more than this much scrollback in total (the newest bytes of each session are kept).
    public static let maxScrollbackTotal = 256 << 20

    public var format: Int
    /// The helper's instance id: the same process keeps it, so the app's saved hosts stay valid.
    public var instance: String
    /// The build of the image that wrote this (logged by the next one).
    public var fromBuild: String
    public var listenFD: Int32
    public var lockFD: Int32
    public var draining: Bool
    public var sessions: [Session]

    public struct Session: Codable, Sendable, Equatable {
        public var spawn: PtydSpawn
        public var pid: Int32
        /// The pty master; -1 once the session ended.
        public var master: Int32
        public var startedAt: Double
        public var cols: Int
        public var rows: Int
        public var alive: Bool
        public var exitCode: Int32?
        public var exitSignal: Int32?
        /// Input not yet written to the pty.
        public var pendingInput: [UInt8]
        /// A SIGKILL scheduled this many seconds from the handover (`signal` with `killAfter`).
        public var killIn: Double?
        /// The master hit EOF (the child is exiting) before the handover.
        public var readStopped: Bool
        /// Not in the JSON header: the bytes follow it.
        public var scrollback: [UInt8]

        enum CodingKeys: String, CodingKey {
            case spawn, pid, master, startedAt, cols, rows, alive, exitCode, exitSignal, pendingInput, killIn,
                 readStopped, scrollbackLength
        }

        public init(spawn: PtydSpawn, pid: Int32, master: Int32, startedAt: Double, cols: Int, rows: Int, alive: Bool,
                    exitCode: Int32? = nil, exitSignal: Int32? = nil, pendingInput: [UInt8] = [], killIn: Double? = nil,
                    readStopped: Bool = false, scrollback: [UInt8] = []) {
            self.spawn = spawn
            self.pid = pid
            self.master = master
            self.startedAt = startedAt
            self.cols = cols
            self.rows = rows
            self.alive = alive
            self.exitCode = exitCode
            self.exitSignal = exitSignal
            self.pendingInput = pendingInput
            self.killIn = killIn
            self.readStopped = readStopped
            self.scrollback = scrollback
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spawn = try c.decode(PtydSpawn.self, forKey: .spawn)
            pid = try c.decode(Int32.self, forKey: .pid)
            master = try c.decode(Int32.self, forKey: .master)
            startedAt = try c.decode(Double.self, forKey: .startedAt)
            cols = try c.decode(Int.self, forKey: .cols)
            rows = try c.decode(Int.self, forKey: .rows)
            alive = try c.decode(Bool.self, forKey: .alive)
            exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
            exitSignal = try c.decodeIfPresent(Int32.self, forKey: .exitSignal)
            pendingInput = try c.decodeIfPresent([UInt8].self, forKey: .pendingInput) ?? []
            killIn = try c.decodeIfPresent(Double.self, forKey: .killIn)
            readStopped = try c.decodeIfPresent(Bool.self, forKey: .readStopped) ?? false
            // Filled in from the bytes after the header (PtydHandover.decode).
            scrollback = [UInt8](repeating: 0, count: try c.decode(Int.self, forKey: .scrollbackLength))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(spawn, forKey: .spawn)
            try c.encode(pid, forKey: .pid)
            try c.encode(master, forKey: .master)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encode(alive, forKey: .alive)
            try c.encodeIfPresent(exitCode, forKey: .exitCode)
            try c.encodeIfPresent(exitSignal, forKey: .exitSignal)
            try c.encode(pendingInput, forKey: .pendingInput)
            try c.encodeIfPresent(killIn, forKey: .killIn)
            try c.encode(readStopped, forKey: .readStopped)
            try c.encode(scrollback.count, forKey: .scrollbackLength)
        }
    }

    public init(instance: String, fromBuild: String, listenFD: Int32, lockFD: Int32, draining: Bool, sessions: [Session]) {
        self.format = Self.currentFormat
        self.instance = instance
        self.fromBuild = fromBuild
        self.listenFD = listenFD
        self.lockFD = lockFD
        self.draining = draining
        self.sessions = sessions
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case unsupportedFormat(Int)
        case io(String)

        public var description: String {
            switch self {
            case .malformed(let why): "malformed handover: \(why)"
            case .unsupportedFormat(let format): "unsupported handover format \(format)"
            case .io(let why): "handover i/o: \(why)"
            }
        }
    }

    /// Every descriptor the next image must inherit (ended sessions have none).
    public var descriptors: [Int32] {
        [listenFD, lockFD] + sessions.filter { $0.alive && $0.master >= 0 }.map(\.master)
    }

    // MARK: Bytes

    public func encoded() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(self)
        var out: [UInt8] = Self.magic
        out.reserveCapacity(8 + header.count + sessions.reduce(0) { $0 + $1.scrollback.count })
        PtydFrame.appendU32(UInt32(header.count), to: &out)
        out.append(contentsOf: header)
        for session in sessions { out.append(contentsOf: session.scrollback) }
        return out
    }

    public static func decode(_ bytes: [UInt8]) throws -> PtydHandover {
        guard bytes.count >= 8, Array(bytes[0..<4]) == magic else { throw Failure.malformed("no magic") }
        let headerLength = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        guard headerLength <= bytes.count - 8 else { throw Failure.malformed("header length") }
        let header = Data(bytes[8..<(8 + headerLength)])
        // The format first: a future layout must be refused, not misread.
        struct Probe: Decodable { var format: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: header) else { throw Failure.malformed("header") }
        guard probe.format >= 1, probe.format <= currentFormat else { throw Failure.unsupportedFormat(probe.format) }
        var handover: PtydHandover
        do {
            handover = try JSONDecoder().decode(PtydHandover.self, from: header)
        } catch {
            throw Failure.malformed("header: \(error)")
        }
        var offset = 8 + headerLength
        for index in handover.sessions.indices {
            let length = handover.sessions[index].scrollback.count
            guard length <= bytes.count - offset else { throw Failure.malformed("scrollback of \(handover.sessions[index].spawn.id)") }
            handover.sessions[index].scrollback = Array(bytes[offset..<(offset + length)])
            offset += length
        }
        guard offset == bytes.count else { throw Failure.malformed("trailing bytes") }
        return handover
    }

    // MARK: The file

    /// Writes the state to a new file in `directory` (0600), unlinks it at once and returns the
    /// open descriptor (close-on-exec; the caller clears that for the exec), positioned at 0.
    public func writeUnlinked(in directory: URL) throws -> Int32 {
        let bytes = try encoded()
        let path = directory.appending(path: "ptyd-handover-\(getpid())-\(UUID().uuidString.prefix(8))").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("open: \(String(cString: strerror(errno)))") }
        unlink(path)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress! + offset, bytes.count - offset, off_t(offset)) }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            let why = String(cString: strerror(errno))
            close(fd)
            throw Failure.io("write: \(why)")
        }
        lseek(fd, 0, SEEK_SET)
        return fd
    }

    /// Reads the whole state from `fd` (from offset 0; the descriptor stays open).
    public static func read(fd: Int32) throws -> PtydHandover {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.io("fstat: \(String(cString: strerror(errno)))") }
        let size = Int(info.st_size)
        guard size >= 8, size <= 64 + maxScrollbackTotal + (64 << 20) else { throw Failure.malformed("size \(size)") }
        var bytes = [UInt8](repeating: 0, count: size)
        var offset = 0
        while offset < size {
            let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + offset, size - offset, off_t(offset)) }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            throw Failure.io("read: \(n == 0 ? "short file" : String(cString: strerror(errno)))")
        }
        return try decode(bytes)
    }

    /// Keeps the newest bytes of each session's scrollback so the total fits `limit`: every
    /// session gets an equal share, and what a short one doesn't use goes to the others.
    public static func bounded(_ scrollbacks: [[UInt8]], limit: Int = maxScrollbackTotal) -> [[UInt8]] {
        var budget = limit
        var result = scrollbacks
        // Smallest first, so leftover shares go to the larger ones.
        let order = scrollbacks.indices.sorted { scrollbacks[$0].count < scrollbacks[$1].count }
        for (position, index) in order.enumerated() {
            let share = budget / max(1, order.count - position)
            if result[index].count > share { result[index] = Array(result[index].suffix(share)) }
            budget -= result[index].count
        }
        return result
    }
}

// MARK: - Deciding whether to exec

/// Whether the binary now at the helper's path may replace the running image. Never exec into
/// a binary that isn't validly signed by the same developer, or isn't a newer build.
public enum PtydUpgradeCheck {
    public enum Verdict: Sendable, Equatable {
        /// Exec into it (its build, if known).
        case go(build: String?)
        case notNewer(candidate: String?, current: String)
        case invalid(String)
    }

    /// The candidate's build: CFBundleVersion of the app bundle it sits in
    /// (`X.app/Contents/MacOS/claudedeck-ptyd` → `X.app/Contents/Info.plist`), read fresh from disk.
    public static func bundleBuild(ofExecutable path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let macOS = url.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS" else { return nil }
        let plist = macOS.deletingLastPathComponent().appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["CFBundleVersion"] as? String
    }

    /// Builds are numbers (CURRENT_PROJECT_VERSION); anything else is never "newer".
    public static func isNewer(_ candidate: String?, than current: String) -> Bool {
        guard let candidate,
              let new = Int(candidate.trimmingCharacters(in: .whitespaces)),
              let old = Int(current.trimmingCharacters(in: .whitespaces)) else { return false }
        return new > old
    }

    /// The decision from the builds and the signature check's outcome (nil = valid).
    public static func verdict(candidateBuild: String?, currentBuild: String, signatureProblem: String?,
                               allowSameBuild: Bool) -> Verdict {
        if let signatureProblem { return .invalid(signatureProblem) }
        guard allowSameBuild || isNewer(candidateBuild, than: currentBuild) else {
            return .notNewer(candidate: candidateBuild, current: currentBuild)
        }
        return .go(build: candidateBuild)
    }

    /// Checks the binary at `path`. Reads the file (call it off the helper's queue).
    /// - Parameters:
    ///   - requirement: the running image's designated requirement, captured at its launch
    ///     (`ownDesignatedRequirement`); nil refuses every candidate.
    ///   - allowSameBuild: tests only (`--upgrade-allow-same-build`): the signature is still
    ///     checked, but the build may be the same.
    public static func check(path: String, requirement: String?, currentBuild: String, allowSameBuild: Bool = false) -> Verdict {
        verdict(candidateBuild: bundleBuild(ofExecutable: path), currentBuild: currentBuild,
                signatureProblem: signatureProblem(path: path, requirement: requirement), allowSameBuild: allowSameBuild)
    }

    /// The running code's designated requirement (same identifier and developer; for an ad-hoc
    /// signature, the same code), as text. Call it at launch, before an update can replace the
    /// file: the static code is read from the path on disk, so asked later it would describe
    /// the replacement, and any replacement would satisfy "itself". Nil (and why) when the
    /// running code doesn't match its file or has no usable signature.
    public static func ownDesignatedRequirement() -> (requirement: String?, problem: String?) {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return (nil, "can't read this helper's own signature") }
        // The file must still be the code that runs (not already replaced under it).
        let valid = SecCodeCheckValidity(me, [], nil)
        guard valid == errSecSuccess else { return (nil, "this helper doesn't match its file on disk (\(valid))") }
        var staticSelf: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticSelf) == errSecSuccess, let staticSelf else {
            return (nil, "can't read this helper's own static code")
        }
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(staticSelf, [], &requirement)
        guard status == errSecSuccess, let requirement else { return (nil, "no designated requirement (\(status))") }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            return (nil, "unprintable designated requirement")
        }
        return (text as String, nil)
    }

    /// Nil when the file at `path` is validly signed and satisfies `requirement`; else why not.
    public static func signatureProblem(path: String, requirement: String?) -> String? {
        guard let text = requirement else { return "no designated requirement captured at launch" }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &parsed) == errSecSuccess, let parsed else {
            return "unparsable designated requirement"
        }
        return signatureProblem(path: path, requirement: parsed)
    }

    static func signatureProblem(path: String, requirement: SecRequirement) -> String? {
        var candidate: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &candidate)
        guard created == errSecSuccess, let candidate else { return "unreadable (\(created))" }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        var error: Unmanaged<CFError>?
        let valid = SecStaticCodeCheckValidityWithErrors(candidate, flags, requirement, &error)
        guard valid == errSecSuccess else {
            let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "\(valid)"
            return "signature check failed (\(valid)): \(detail)"
        }
        return nil
    }
}

// MARK: - Watching the binary

/// Identity of a file on disk: a replaced binary has another inode (or size, or mtime).
public struct PtydFileIdentity: Sendable, Equatable {
    public var device: Int32
    public var inode: UInt64
    public var size: Int64
    public var modified: Double

    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    }

    public init(device: Int32, inode: UInt64, size: Int64, modified: Double) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
    }
}

/// When the helper's binary changed on disk, and whether it has settled long enough to look at.
/// Pure state (the helper feeds it a stat every few seconds), so it's testable.
public struct PtydBinaryWatch: Sendable, Equatable {
    /// The file the running image was loaded from.
    public let baseline: PtydFileIdentity?
    /// How long a new file must stay the same before it is checked (an update still copying).
    public var settle: Double
    private var seen: PtydFileIdentity?
    private var seenAt: Double = 0
    /// Checked and refused (or the exec failed): not tried again until the file changes again.
    private(set) var rejected: PtydFileIdentity?

    public init(baseline: PtydFileIdentity?, settle: Double = 3) {
        self.baseline = baseline
        self.settle = settle
    }

    /// Feed the current identity (nil: no file right now); true when it's time to check it.
    public mutating func observe(_ current: PtydFileIdentity?, now: Double) -> Bool {
        guard let current, current != baseline, current != rejected else {
            seen = nil
            return false
        }
        if current != seen {
            seen = current
            seenAt = now
            return false
        }
        return now - seenAt >= settle
    }

    /// The file `identity` was refused; ignore it until it changes.
    public mutating func reject(_ identity: PtydFileIdentity?) {
        rejected = identity
        seen = nil
    }
}
