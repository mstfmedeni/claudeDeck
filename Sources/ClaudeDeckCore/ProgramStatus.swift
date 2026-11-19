import Foundation

// Program status for plain terminals: what the program in a shell is doing (working, blocked on
// input, finished, failed), from two sources.
//
// 1. OSC 7501, the Program Status Protocol (https://www.superlogical.com/rex/docs/build/program-status):
//    `ESC ] 7501 ; key=value:key=value ST`, where ST is `ESC \` or BEL. `state` is required
//    (idle | working | done | blocked | error | clear); `msg` and `title` are base64 UTF-8;
//    `id` addresses a record (`build/test` is a child of `build`, no id is the root record); each
//    report replaces its record; a new shell prompt (OSC 133 A) or the process exiting drops
//    `working` and `blocked` records, `done` and `error` survive. `ESC ] 7501 ; ? ST` asks whether
//    the terminal supports it.
// 2. Shell integration marks, OSC 133 (FinalTerm): `A` prompt start, `B` command start, `C`
//    command executed (output begins), `D;<exit>` command finished.
//
// Everything here is pure: `OSCScanner` pulls the sequences out of raw pty output,
// `ProgramStatusParser` / `ShellMark` parse them, `ProgramStatusTracker` turns them into the
// one status a terminal shows.

/// Pulls OSC sequences with the given codes out of a byte stream that arrives in arbitrary chunks
/// (a sequence may be split across them). Only looks; the terminal still gets every byte.
public struct OSCScanner: Sendable {
    private enum Phase: Sendable {
        case ground, escape, code, payload, payloadEscape, skip, skipEscape
    }

    public let codes: Set<Int>
    public let maxPayload: Int
    private var phase = Phase.ground
    private var code = 0
    private var digits = 0
    private var payload: [UInt8] = []

    public init(codes: Set<Int>, maxPayload: Int = ProgramStatusParser.maxSequenceLength) {
        self.codes = codes
        self.maxPayload = maxPayload
    }

    private static let esc: UInt8 = 0x1B, bel: UInt8 = 0x07, can: UInt8 = 0x18, sub: UInt8 = 0x1A
    private static let rightBracket: UInt8 = 0x5D, backslash: UInt8 = 0x5C, semicolon: UInt8 = 0x3B

    public mutating func scan(_ bytes: some Collection<UInt8>, _ emit: (Int, [UInt8]) -> Void) {
        for byte in bytes { step(byte, emit) }
    }

    /// Same as `scan`, with a fast path: outside a sequence, chunks without ESC are skipped whole.
    public mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>, _ emit: (Int, [UInt8]) -> Void) {
        guard let base = bytes.baseAddress else { return }
        var index = 0
        while index < bytes.count {
            if phase == .ground {
                guard let hit = memchr(base + index, Int32(Self.esc), bytes.count - index) else { return }
                index = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
            step(bytes[index], emit)
            index += 1
        }
    }

    private mutating func step(_ byte: UInt8, _ emit: (Int, [UInt8]) -> Void) {
        switch phase {
        case .ground:
            if byte == Self.esc { phase = .escape }
        case .escape:
            if byte == Self.rightBracket {
                phase = .code
                code = 0
                digits = 0
            } else {
                phase = byte == Self.esc ? .escape : .ground
            }
        case .code:
            if byte >= 0x30, byte <= 0x39, digits < 6 {
                code = code * 10 + Int(byte - 0x30)
                digits += 1
            } else if byte == Self.semicolon, digits > 0 {
                if codes.contains(code) {
                    payload.removeAll(keepingCapacity: true)
                    phase = .payload
                } else {
                    phase = .skip
                }
            } else if byte == Self.bel {
                if digits > 0, codes.contains(code) { emit(code, []) }
                phase = .ground
            } else if byte == Self.esc {
                phase = digits > 0 && codes.contains(code) ? .payloadEscape : .escape
                payload.removeAll(keepingCapacity: true)
            } else if byte == Self.can || byte == Self.sub {
                phase = .ground
            } else {
                phase = .skip
            }
        case .payload:
            switch byte {
            case Self.bel:
                emit(code, payload)
                phase = .ground
            case Self.esc:
                phase = .payloadEscape
            case Self.can, Self.sub:
                phase = .ground
            default:
                if byte < 0x20 { break } // C0 controls inside an OSC string are ignored
                if payload.count >= maxPayload {
                    phase = .skip // too long: dropped whole
                } else {
                    payload.append(byte)
                }
            }
        case .payloadEscape:
            // ESC \ ends the string; any other escape sequence cancels it (ESC ] starts a new one).
            if byte == Self.backslash {
                emit(code, payload)
                phase = .ground
            } else if byte == Self.rightBracket {
                phase = .code
                code = 0
                digits = 0
            } else {
                phase = byte == Self.esc ? .escape : .ground
            }
        case .skip:
            if byte == Self.bel || byte == Self.can || byte == Self.sub { phase = .ground }
            else if byte == Self.esc { phase = .skipEscape }
        case .skipEscape:
            if byte == Self.rightBracket {
                phase = .code
                code = 0
                digits = 0
            } else {
                phase = byte == Self.esc ? .skipEscape : .ground
            }
        }
    }
}

// MARK: OSC 7501

/// One OSC 7501 report.
public struct ProgramStatusReport: Equatable, Sendable {
    public enum State: String, Sendable, CaseIterable {
        case idle, working, done, blocked, error, clear
    }

    /// What a `blocked` program waits for.
    public enum Kind: String, Sendable, CaseIterable {
        case permission, question, auth
    }

    public var state: State
    /// Record path; "" is the root record.
    public var id: String
    public var kind: Kind?
    /// 0...100, only with `working` / `blocked`.
    public var progress: Int?
    public var app: String?
    public var title: String?
    public var message: String?

    public init(state: State, id: String = "", kind: Kind? = nil, progress: Int? = nil,
                app: String? = nil, title: String? = nil, message: String? = nil) {
        self.state = state
        self.id = id
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
    }
}

public enum ProgramStatusSequence: Equatable, Sendable {
    /// `OSC 7501 ; ?`: answer with `ProgramStatusParser.queryReply`.
    case query
    case report(ProgramStatusReport)
}

public enum ProgramStatusParser {
    public static let code = 7501
    /// The spec's limits.
    public static let maxSequenceLength = 4096
    static let maxKeyLength = 16
    static let maxMessageEncoded = 2732, maxMessageDecoded = 2048
    static let maxTitleEncoded = 256, maxTitleDecoded = 192
    static let maxAppLength = 32
    static let maxIDLength = 128, maxIDSegment = 32, maxIDDepth = 8

    /// The reply to a query: supported, with the states (not counting `clear`) and kinds this
    /// terminal accepts. Sent back on the pty, so it ends with ST.
    public static let queryReply = "\u{1B}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1B}\\"

    /// Parses the payload after `7501;`. nil when the report must be ignored (no or an unknown
    /// `state`, a malformed `id`).
    public static func parse(_ payload: some Collection<UInt8>) -> ProgramStatusSequence? {
        guard payload.count <= maxSequenceLength else { return nil }
        let body = String(decoding: payload, as: UTF8.self)
        let pairs = body.split(separator: ":", omittingEmptySubsequences: false)
        if pairs.first?.trimmingCharacters(in: .whitespaces) == "?" { return .query }

        var fields: [String: String] = [:]
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else { continue } // malformed: skipped
            let key = pair[..<eq].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.utf8.count <= maxKeyLength else { continue }
            fields[key] = value // a repeated key: the last one wins
        }
        guard let rawState = fields["state"], let state = ProgramStatusReport.State(rawValue: rawState) else { return nil }
        var report = ProgramStatusReport(state: state)
        if let id = fields["id"], !id.isEmpty {
            guard let valid = validID(id) else { return nil }
            report.id = valid
        }
        if state == .blocked, let kind = fields["kind"] { report.kind = ProgramStatusReport.Kind(rawValue: kind) }
        if state == .working || state == .blocked, let text = fields["progress"],
           text.allSatisfy(\.isASCII), let value = Int(text), (0...100).contains(value) {
            report.progress = value
        }
        if let app = fields["app"], !app.isEmpty, app.utf8.count <= maxAppLength, !hasControlCharacters(app) {
            report.app = app
        }
        report.title = fields["title"].flatMap { decodeText($0, maxEncoded: maxTitleEncoded, maxDecoded: maxTitleDecoded) }
        report.message = fields["msg"].flatMap { decodeText($0, maxEncoded: maxMessageEncoded, maxDecoded: maxMessageDecoded) }
        return .report(report)
    }

    /// `a/b/c`: up to 8 non-empty segments of up to 32 bytes, 128 in all.
    static func validID(_ id: String) -> String? {
        guard id.utf8.count <= maxIDLength, !hasControlCharacters(id) else { return nil }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count <= maxIDDepth,
              segments.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maxIDSegment }) else { return nil }
        return id
    }

    /// Base64 UTF-8 within the limits and without control characters; nil (treated as absent) otherwise.
    static func decodeText(_ encoded: String, maxEncoded: Int, maxDecoded: Int) -> String? {
        guard !encoded.isEmpty, encoded.utf8.count <= maxEncoded,
              let data = Data(base64Encoded: encoded), data.count <= maxDecoded,
              let text = String(data: data, encoding: .utf8), !hasControlCharacters(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// U+0000–U+001F, U+007F, U+0080–U+009F.
    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }
}

// MARK: OSC 133

/// A shell integration mark (OSC 133, FinalTerm / iTerm2 semantic prompts).
public enum ShellMark: Equatable, Sendable {
    /// `A`: a new prompt begins.
    case promptStart
    /// `B`: the prompt ended, the user types the command.
    case commandStart
    /// `C`: the command runs (its output follows).
    case commandExecuted
    /// `D[;exit]`: the command finished; nil when the shell didn't say how.
    case commandFinished(exitCode: Int32?)

    public static let code = 133

    /// Parses the payload after `133;` (`A`, `A;k=i`, `D;0`, `D;1;aid=…`).
    public static func parse(_ payload: some Collection<UInt8>) -> ShellMark? {
        let text = String(decoding: payload, as: UTF8.self)
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let action = fields.first?.trimmingCharacters(in: .whitespaces), action.count == 1 else { return nil }
        switch action {
        case "A": return .promptStart
        case "B": return .commandStart
        case "C": return .commandExecuted
        case "D":
            let exit = fields.count > 1 ? Int32(fields[1].trimmingCharacters(in: .whitespaces)) : nil
            return .commandFinished(exitCode: exit)
        default: return nil
        }
    }
}

// MARK: State machine

/// What a plain terminal shows.
public struct ProgramStatus: Equatable, Sendable {
    public enum State: String, Sendable, Codable {
        case working, blocked, finished, failed
        /// A long-running command that serves (listens on a TCP port, or the user marked the
        /// terminal as a service): running, but not "working" (TerminalService.swift).
        case service
    }

    public var state: State
    /// The command's exit code (shell integration), when known.
    public var exitCode: Int32?
    /// The program's `msg` (or `title`).
    public var message: String?
    /// What a blocked program waits for.
    public var kind: ProgramStatusReport.Kind?
    /// The program's `app` id.
    public var app: String?
    /// When the terminal entered this state (a new message doesn't move it). A command that turns
    /// into a service keeps the time it started.
    public var since: Date
    /// `service`: the TCP ports its processes listen on (sorted; empty when only marked by hand).
    public var ports: [Int]?

    public init(state: State, exitCode: Int32? = nil, message: String? = nil, kind: ProgramStatusReport.Kind? = nil,
                app: String? = nil, since: Date, ports: [Int]? = nil) {
        self.state = state
        self.exitCode = exitCode
        self.message = message
        self.kind = kind
        self.app = app
        self.since = since
        self.ports = ports
    }

    /// Finished or failed: the result is ready (the "your turn" of a terminal).
    public var isOutcome: Bool { state == .finished || state == .failed }
}

/// Folds OSC 7501 reports, OSC 133 marks and the process exiting into one `ProgramStatus`.
///
/// Which record shows: a blocked one (the most recent), else a working one or a running
/// command, else the newest result — a `done` / `error` record or the last command's exit code.
/// A result the program reported during a command beats that command's exit code (it says
/// more), and takes the exit code along. `idle` records and an interrupted command (exit 130)
/// show nothing: the terminal is at rest.
public struct ProgramStatusTracker: Sendable {
    struct Record: Sendable {
        var report: ProgramStatusReport
        /// Bumped when the record's state changes, not when only its message does.
        var serial: Int
    }

    struct CommandResult: Sendable {
        var exitCode: Int32?
        /// `serial` when the command started; records newer than this belong to it.
        var startSerial: Int
        var serial: Int
    }

    public static let maxRecords = 256

    public private(set) var status: ProgramStatus?
    private var records: [String: Record] = [:]
    private var commandRunning = false
    private var commandStartSerial = 0
    private var lastCommand: CommandResult?
    private var serial = 0
    /// Identity of the event behind `status` (moves `since` when it changes).
    private var statusToken = ""
    /// TCP ports the running command's processes were seen listening on (`noteListening`);
    /// dropped when the command ends. Sticky while it runs: a dev server that restarts (and
    /// briefly listens on nothing) stays a service.
    private var listeningPorts: [Int] = []
    /// `status` comes from a command the shell runs (OSC 133), not from a program's own report.
    public private(set) var statusFromCommand = false

    public init() {}

    /// Applies one report; true when `status` changed.
    @discardableResult
    public mutating func apply(_ report: ProgramStatusReport, now: Date) -> Bool {
        switch report.state {
        case .clear:
            let prefix = report.id + "/"
            records = records.filter { key, _ in
                report.id.isEmpty ? false : key != report.id && !key.hasPrefix(prefix)
            }
        default:
            if let existing = records[report.id] {
                let changed = existing.report.state != report.state
                if changed { serial += 1 }
                records[report.id] = Record(report: report, serial: changed ? serial : existing.serial)
            } else {
                guard records.count < Self.maxRecords else { return false }
                serial += 1
                records[report.id] = Record(report: report, serial: serial)
            }
        }
        return update(now: now)
    }

    /// Applies one shell mark; true when `status` changed.
    @discardableResult
    public mutating func apply(_ mark: ShellMark, now: Date) -> Bool {
        switch mark {
        case .promptStart:
            dropActive()
            // A prompt without `D` after a command: it ended, how is unknown — nothing to show.
            commandRunning = false
        case .commandStart:
            return false
        case .commandExecuted:
            serial += 1
            commandRunning = true
            commandStartSerial = serial
            listeningPorts = []
        case .commandFinished(let exitCode):
            // `D` without a command (an empty line) changes nothing.
            guard commandRunning else { return false }
            commandRunning = false
            listeningPorts = []
            serial += 1
            lastCommand = CommandResult(exitCode: exitCode, startSerial: commandStartSerial, serial: serial)
        }
        return update(now: now)
    }

    /// The terminal's process exited; true when `status` changed.
    @discardableResult
    public mutating func processExited(now: Date) -> Bool {
        dropActive()
        commandRunning = false
        return update(now: now)
    }

    /// The running command's processes listen on these TCP ports (a probe, see
    /// TerminalService.swift): the command shows as a service. Only a command the shell runs
    /// turns into one; what a program reports itself (OSC 7501) always wins. Empty ports keep a
    /// command that already is a service as it is. True when `status` changed.
    @discardableResult
    public mutating func noteListening(_ ports: [Int], now: Date) -> Bool {
        guard commandRunning else { return false }
        let sorted = Array(Set(ports)).sorted()
        guard !sorted.isEmpty, sorted != listeningPorts else { return false }
        listeningPorts = sorted
        return update(now: now)
    }

    /// `working` and `blocked` records end with a new prompt or the process.
    private mutating func dropActive() {
        records = records.filter { $0.value.report.state != .working && $0.value.report.state != .blocked }
        listeningPorts = []
    }

    private mutating func update(now: Date) -> Bool {
        let (next, token) = resolve()
        guard var next else {
            statusToken = ""
            statusFromCommand = false
            guard status != nil else { return false }
            status = nil
            return true
        }
        // A running command that turns into a service (or back) is still the same event.
        let running: Set<ProgramStatus.State> = [.working, .service]
        let sameState = status.map { $0.state == next.state || (running.contains($0.state) && running.contains(next.state)) } ?? false
        let sameEvent = token == statusToken && sameState
        next.since = sameEvent ? status!.since : now
        statusToken = token
        statusFromCommand = token.hasPrefix("c:")
        guard next != status else { return false }
        status = next
        return true
    }

    private func resolve() -> (ProgramStatus?, String) {
        func status(_ record: (key: String, value: Record), _ state: ProgramStatus.State, exitCode: Int32? = nil) -> (ProgramStatus?, String) {
            let report = record.value.report
            return (ProgramStatus(state: state, exitCode: exitCode, message: report.message ?? report.title,
                                  kind: state == .blocked ? report.kind : nil, app: report.app, since: .distantPast),
                    "r:\(record.key):\(record.value.serial)")
        }
        let newestFirst = records.sorted { $0.value.serial > $1.value.serial }
        if let blocked = newestFirst.first(where: { $0.value.report.state == .blocked }) {
            return status(blocked, .blocked)
        }
        if let working = newestFirst.first(where: { $0.value.report.state == .working }) {
            return status(working, .working)
        }
        // The newest settled record: done, error or idle.
        let settled = newestFirst.first { [.done, .error, .idle].contains($0.value.report.state) }
        if commandRunning, settled.map({ $0.value.serial < commandStartSerial }) ?? true {
            if !listeningPorts.isEmpty {
                return (ProgramStatus(state: .service, since: .distantPast, ports: listeningPorts), "c:\(commandStartSerial)")
            }
            return (ProgramStatus(state: .working, since: .distantPast), "c:\(commandStartSerial)")
        }
        // Reported during the last command (or after it, or with none run): it says more than the exit code.
        if let settled, lastCommand.map({ settled.value.serial > $0.startSerial }) ?? true {
            let state = settled.value.report.state
            if state == .idle { return (nil, "") }
            let exitCode = commandRunning ? nil : lastCommand?.exitCode
            return status(settled, state == .error ? .failed : .finished, exitCode: exitCode)
        }
        if let command = lastCommand {
            switch command.exitCode {
            case 130?: return (nil, "") // Ctrl+C: the user stopped it
            case let code? where code != 0:
                return (ProgramStatus(state: .failed, exitCode: code, since: .distantPast), "c:\(command.serial)")
            default:
                return (ProgramStatus(state: .finished, exitCode: command.exitCode, since: .distantPast), "c:\(command.serial)")
            }
        }
        return (nil, "")
    }
}

/// Scanner + parsers + tracker for one terminal's output.
public struct ProgramStatusMonitor: Sendable {
    private var scanner = OSCScanner(codes: [ProgramStatusParser.code, ShellMark.code])
    public private(set) var tracker = ProgramStatusTracker()

    public init() {}

    public var status: ProgramStatus? { tracker.status }

    /// Feeds raw pty output. Returns whether `status` changed and whether a query wants the reply.
    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>, now: Date) -> (changed: Bool, replyToQuery: Bool) {
        var changed = false, query = false
        var tracker = self.tracker
        scanner.scan(bytes) { code, payload in
            Self.handle(code, payload, tracker: &tracker, now: now, changed: &changed, query: &query)
        }
        self.tracker = tracker
        return (changed, query)
    }

    public mutating func feed(_ bytes: some Collection<UInt8>, now: Date) -> (changed: Bool, replyToQuery: Bool) {
        var changed = false, query = false
        var tracker = self.tracker
        scanner.scan(bytes) { code, payload in
            Self.handle(code, payload, tracker: &tracker, now: now, changed: &changed, query: &query)
        }
        self.tracker = tracker
        return (changed, query)
    }

    private static func handle(_ code: Int, _ payload: [UInt8], tracker: inout ProgramStatusTracker, now: Date,
                               changed: inout Bool, query: inout Bool) {
        if code == ProgramStatusParser.code {
            switch ProgramStatusParser.parse(payload) {
            case .query?: query = true
            case .report(let report)?: if tracker.apply(report, now: now) { changed = true }
            case nil: break
            }
        } else if code == ShellMark.code, let mark = ShellMark.parse(payload) {
            if tracker.apply(mark, now: now) { changed = true }
        }
    }

    @discardableResult
    public mutating func processExited(now: Date) -> Bool { tracker.processExited(now: now) }

    /// See `ProgramStatusTracker.noteListening`.
    @discardableResult
    public mutating func noteListening(_ ports: [Int], now: Date) -> Bool { tracker.noteListening(ports, now: now) }

    /// When the command now running started, if the status is a command the shell runs (working
    /// or already a service): the only kind the service probe looks at.
    public var commandSince: Date? {
        guard tracker.statusFromCommand, let status, status.state == .working || status.state == .service else { return nil }
        return status.since
    }
}
