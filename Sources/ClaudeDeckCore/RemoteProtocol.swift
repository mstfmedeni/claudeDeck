import CommonCrypto
import CryptoKit
import Foundation

// Remote mode: one Mac (the host) runs the sessions, another ClaudeDeck (the remote) shows their
// status, gets the notifications and answers permission prompts. The connection is plain TCP over
// Tailscale (WireGuard already encrypts it); both sides prove they hold the pairing key with an
// HMAC challenge before anything else is sent.
//
// Wire format: frames of [kind: UInt8][length: UInt32 big-endian][payload]. Control messages are
// JSON (`RemoteMessage`) in `.message` frames; later frame kinds can carry raw terminal bytes.

public enum RemoteFrameKind: UInt8, Sendable {
    case message = 1
    /// Raw pty output of one session (`RemoteTerminalOutput`).
    case terminalOutput = 2
    /// Any frame, encrypted (RemoteCrypto.swift). Everything after the handshake is sealed.
    case sealed = 3
}

public struct RemoteFrame: Sendable, Equatable {
    public var kind: UInt8
    public var payload: Data

    public init(kind: UInt8, payload: Data) {
        self.kind = kind
        self.payload = payload
    }

    public static let headerSize = 5
    /// Larger frames are a protocol error (a snapshot is a few KB).
    public static let maxPayload = 8 << 20

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(kind)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

/// Splits a byte stream into frames; bytes of an unfinished frame wait for the next `append`.
public struct RemoteFrameDecoder: Sendable {
    public enum DecodeError: Error, Equatable { case frameTooLarge(Int) }

    private var buffer = Data()
    /// Frames announcing more than this are a protocol error (a host lowers it until the peer has
    /// proved the key, see `RemoteChannel.maxPayloadBeforeHandshake`).
    public var maxPayload = RemoteFrame.maxPayload

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [RemoteFrame] {
        buffer.append(bytes)
        var frames: [RemoteFrame] = []
        // Walk the buffer and drop what was read once at the end: copying the rest after every
        // frame made a read full of small frames (terminal output) quadratic.
        var start = buffer.startIndex
        defer { buffer = start == buffer.endIndex ? Data() : Data(buffer[start...]) }
        while buffer.endIndex - start >= RemoteFrame.headerSize {
            let length = buffer[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
            guard length <= maxPayload else { throw DecodeError.frameTooLarge(length) }
            guard buffer.endIndex - start >= RemoteFrame.headerSize + length else { break }
            let payloadStart = start + RemoteFrame.headerSize
            frames.append(RemoteFrame(kind: buffer[start], payload: Data(buffer[payloadStart..<(payloadStart + length)])))
            start = payloadStart + length
        }
        return frames
    }
}

// MARK: Messages

public enum RemoteMessage: Codable, Sendable, Equatable {
    /// Remote → host, first message.
    case hello(version: Int, nonce: Data, deviceName: String)
    /// Host → remote: its own nonce.
    case challenge(nonce: Data)
    /// Remote → host: the remote's proof of the key (first, so the host can count wrong
    /// passwords and nobody learns anything from the host before proving the key).
    case auth(proof: Data)
    /// Host → remote, after a valid `auth`: the host's proof of the key.
    case welcome(proof: Data)
    /// Host → remote: every session's state; sent after auth and on every change.
    case snapshot(RemoteSnapshot)
    /// Remote → host: answer the permission prompt identified by `stamp` (the hook timestamp the
    /// remote saw). The host ignores it if a different prompt is showing by now.
    case permission(sessionID: UUID, stamp: Double, approve: Bool)
    /// Host → remote: whether the keystroke was sent.
    case permissionResult(sessionID: UUID, approve: Bool, applied: Bool)
    /// Remote → host: answer the AskUserQuestion prompt of tool call `toolUseID` (one answer per
    /// question); the host types the keys. Answered with `permissionResult(approve: true)`.
    case answerQuestion(sessionID: UUID, toolUseID: String, answers: [QuestionAnswer])
    /// Remote → host: start watching a session's terminal.
    case terminalOpen(sessionID: UUID)
    /// Remote → host: stop watching.
    case terminalClose(sessionID: UUID)
    /// Remote → host: keystrokes / paste, typed into the session as if on the host.
    case terminalInput(sessionID: UUID, data: Data)
    /// Host → remote: the terminal's size and current screen (ANSI); output frames follow.
    /// Sent again after a resize or when the remote fell behind.
    case terminalStart(sessionID: UUID, cols: Int, rows: Int, screen: Data)
    /// Remote → host: size the session's terminal to this grid while watched (a phone fits it to
    /// its screen); `cols == 0` gives the size back to the host's window.
    case terminalFit(sessionID: UUID, cols: Int, rows: Int)
    /// Host → remote: the session isn't running (any more).
    case terminalEnded(sessionID: UUID)
    /// Remote → host: a page of a session's conversation (ConversationLog.swift): the latest
    /// `limit` entries, the ones before `before`, or the ones after `after`.
    case historyRequest(sessionID: UUID, before: String?, after: String?, limit: Int)
    /// Host → remote: the answer.
    case history(sessionID: UUID, page: ChatPage)
    /// Remote → host: the session's conversation is on screen / no longer (counted per session
    /// on the remote; sent once each way). While it's open the host says when its transcript
    /// changes. Hosts with `Feature.conversationPush`.
    case conversationOpen(sessionID: UUID)
    case conversationClose(sessionID: UUID)
    /// Host → remote: the open conversation's transcript changed: ask for what's new now
    /// (polling stays as a fallback).
    case conversationChanged(sessionID: UUID)
    /// Remote → host: Claude's edits in a session after the change `after` (nil: from the first),
    /// a page at a time (RemoteEdits.swift). Hosts with `Feature.edits`.
    case editsRequest(sessionID: UUID, after: String?)
    /// Host → remote: the answer.
    case edits(sessionID: UUID, page: RemoteEditsPage)
    /// Remote → host: a changed file's net diff. Hosts with `Feature.edits`.
    case netDiffRequest(sessionID: UUID, path: String)
    /// Host → remote: the answer.
    case netDiff(sessionID: UUID, path: String, diff: RemoteNetDiff)
    /// Remote → host: start a Claude session in a project (and type `prompt` once it's ready).
    case startSession(projectID: UUID, prompt: String?)
    /// Host → remote: the session `startSession` created (the phone opens it).
    case sessionStarted(sessionID: UUID)
    /// Remote → host: a plain terminal in a project, optionally running `command`.
    case startShell(projectID: UUID, command: String?)
    /// Remote → host: the project's past Claude conversations (like the Mac's Resume window).
    case pastConversationsRequest(projectID: UUID)
    case pastConversations(projectID: UUID, items: [RemotePastConversation])
    /// Remote → host: a new session resuming one of those conversations.
    case resumeConversation(projectID: UUID, conversationID: String)
    /// Remote → host: a folder of a project (path relative to the project, "" = its root).
    case listDirectory(projectID: UUID, path: String)
    case directory(projectID: UUID, path: String, entries: [RemoteFileEntry], error: String?)
    /// Remote → host: a text file of a project (at most `RemoteFiles.maxFileSize`).
    case readFile(projectID: UUID, path: String)
    case file(projectID: UUID, path: String, text: String?, size: Int, error: String?)
    /// Remote → host: the next piece of any file of a project, from `offset` (download). Answered
    /// with `fileChunk`; the remote asks for the next piece when one arrives.
    case downloadFile(projectID: UUID, path: String, offset: Int)
    /// Host → remote: up to `RemoteTransfer.chunkSize` bytes of the file at `offset`, of `total`.
    case fileChunk(projectID: UUID, path: String, offset: Int, total: Int, data: Data, error: String?)
    /// Remote → host: a piece of a file for the project folder `folder` (upload). The host saves it
    /// as `name` (or "name 2"… when taken) once `total` bytes are in. Answered with `uploadAck`.
    case uploadFile(projectID: UUID, folder: String, name: String, offset: Int, total: Int, data: Data)
    /// Host → remote: bytes in so far; `path` (relative to the project) once the file is saved.
    case uploadAck(projectID: UUID, folder: String, name: String, received: Int, path: String?, error: String?)
    /// Remote → host: press Esc in a working session (interrupts Claude).
    case interrupt(sessionID: UUID)
    /// Remote → host: end a running session / resume a closed one (a closed terminal starts again
    /// on hosts with `Feature.closedTerminals`).
    case stopSession(sessionID: UUID)
    case resumeSession(sessionID: UUID)
    /// Remote → host: the user looked at this session (clears "your turn").
    case markSeen(sessionID: UUID)
    /// Remote → host: type this message into the session and press Enter.
    case sendPrompt(sessionID: UUID, text: String)
    /// Remote → host: put this message in the session's queue (sent at "your turn"; at once when
    /// it's the user's turn already). The next snapshot shows the queue.
    case queuePrompt(sessionID: UUID, text: String)
    /// Remote → host: remove / edit / send now / move up a queued message.
    case queueAction(sessionID: UUID, promptID: UUID, action: QueueAction)
    /// Remote → host: ask these agents about the session (`request`: what to look at). Their
    /// notes come with the conversation pages.
    case askAgents(sessionID: UUID, agentIDs: [UUID], request: String)
    /// Remote → host: dismiss a note, or send its answer to Claude (now or queued).
    case agentNoteAction(sessionID: UUID, noteID: UUID, action: AgentNoteAction)
    /// Remote → host: approve or reject an agent that signed itself up (`pendingAgents`), with the
    /// webhook URL and Authorization header the user pasted when it registered without them
    /// (hosts with `Feature.agentCompletion`). Sent over the encrypted channel, never logged.
    case agentRegistration(agentID: UUID, approve: Bool, url: String? = nil, authHeader: String? = nil)
    /// Remote → host: the agents with their settings and the recent activity (the phone's
    /// read-only Agents screen). Answered with `agentDetailsAre`.
    case agentDetails
    /// Host → remote: the answer to `agentDetails`.
    case agentDetailsAre(RemoteAgentDetails)
    /// Remote → host: a message with files. The host saves them and puts them in with the text
    /// (images as pasted images, other files as @mentions). Answered with `promptResult`.
    case sendPromptWithFiles(sessionID: UUID, text: String, files: [RemoteUpload])
    /// Remote → host: files dropped / pasted into a watched terminal (another Mac). The host saves
    /// them and pastes them in like `sendPromptWithFiles`, without Enter. Answered with `promptResult`.
    case pasteFiles(sessionID: UUID, files: [RemoteUpload])
    /// Host → remote: whether the message with files went in (nil) or why not.
    case promptResult(sessionID: UUID, error: String?)
    /// Remote → host: the session's permission mode, after pressing Shift+Tab once when `cycle`
    /// (manual → accept edits → plan → auto…). Answered with `permissionModeIs`.
    case permissionMode(sessionID: UUID, cycle: Bool)
    /// Host → remote: the mode as Claude Code's status line shows it ("plan mode"), nil if unknown.
    case permissionModeIs(sessionID: UUID, mode: String?)
    /// Remote → host: pin / unpin or rename one of its projects (the next snapshot shows it).
    case projectAction(projectID: UUID, action: RemoteProjectAction)
    /// Host → remote: why a `renameFolder` didn't rename the folder (nil: it did).
    case projectActionResult(projectID: UUID, error: String?)
    /// Remote → host: the folders in `path` ("" = home), to pick a new project. Answered with `folder`.
    case browseFolder(path: String)
    /// Host → remote: `path` resolved (absolute) and its subfolders (no hidden ones).
    case folder(requested: String, path: String, folders: [String], error: String?)
    /// Remote → host: add this folder as a project.
    case addProject(path: String)
    /// Remote → host: what the Mac's session menu does (rename, restart, close, start fresh, remove).
    case sessionAction(sessionID: UUID, action: RemoteSessionAction)
    /// Remote → host: Fix with Claude for a failed ServerPlan deploy (the Mac's own repair flow).
    /// Hosts with `Feature.serverPlanRepair`; answered with `serverPlanRepairResult`.
    case serverPlanRepair(deploymentID: Int)
    /// Host → remote: the session the repair went to, or why it didn't start.
    case serverPlanRepairResult(deploymentID: Int, sessionID: UUID?, error: String?)
    /// Remote → host: clear these failed deploys from the Mac's sidebar and the phone's list
    /// (local bookkeeping: nothing changes on the panel). `all`: every ServerPlan failure the Mac
    /// shows, server and panel errors too. Hosts with `Feature.dismissServerIssues`; the next
    /// snapshot leaves them out.
    case dismissServerIssues(deploymentIDs: [Int], all: Bool)
    /// Remote → host: the owner's answer to a decision a session left (`decisions` in the
    /// snapshot; hosts with `Feature.decisions`). The next snapshot shows it answered; a decision
    /// answered elsewhere first keeps that answer.
    case answerDecision(id: String, answer: String)
    /// Remote → host: the owner removes a pending decision without answering (hosts with
    /// `Feature.dismissDecision`). The asking session is told; the next snapshot drops it.
    case dismissDecision(id: String)
    /// Remote → host: the owner changes an answer already given (hosts with
    /// `Feature.changeDecisionAnswer`). The asking session gets the new answer as a message.
    case changeDecisionAnswer(id: String, answer: String)
    /// Remote → host: the owner's answer to a pending approval (`approvals` in the snapshot;
    /// hosts with `Feature.approvals`). The host only takes what the approval allows from a
    /// phone (`phoneMayApprove` / `phoneMayRefuse`); the next snapshot drops it.
    case answerApproval(id: String, approve: Bool)
    /// Phone → host: send push notifications to this device (APNs.swift).
    case registerPush(token: Data, topic: String, environment: String, deviceName: String)
    case ping
    case pong
    /// Either side, before closing.
    case refused(reason: String)

    /// 2: frames after the handshake are encrypted; the remote proves the key first.
    public static let protocolVersion = 2

    public func frame() throws -> RemoteFrame {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return RemoteFrame(kind: RemoteFrameKind.message.rawValue, payload: try encoder.encode(self))
    }

    public static func decode(_ frame: RemoteFrame) throws -> RemoteMessage? {
        guard frame.kind == RemoteFrameKind.message.rawValue else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(RemoteMessage.self, from: frame.payload)
    }
}

/// What a remote may change about one of the host's projects.
public enum RemoteProjectAction: Codable, Sendable, Equatable {
    case pin(Bool)
    case rename(String)
    /// Rename the project and its folder on disk (hosts with `Feature.renameFolder`); answered
    /// with `projectActionResult`.
    case renameFolder(String)
}

/// The Mac's session menu, for a remote.
public enum RemoteSessionAction: Codable, Sendable, Equatable {
    case rename(String)
    /// Restart Session / Restart Terminal.
    case restart
    /// End Session / Close Terminal (stopSession, for terminals too).
    case close
    /// A closed Claude session started again without its conversation; a closed terminal reopened.
    case startFresh
    /// End and Remove: off the list (the conversation stays resumable from the project).
    case remove
    /// Put text in the session's prompt without Enter, as a paste (a project file's @mention).
    /// Hosts with `Feature.transfer` only.
    case insert(String)
}

/// Claude Code's permission mode, read from the line under its input box
/// ("⏸ plan mode on (shift+tab to cycle) · ← for agents", "⏵⏵ accept edits on").
public enum PermissionModeLine {
    public static func mode(in lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let match = line.firstMatch(of: /(?:⏸|⏵⏵|⏵)\s*(.+?)\s+on\b/) else { continue }
            return String(match.1)
        }
        return nil
    }
}

/// A file the phone attaches to a message (photos are resized and made JPEG on the phone).
public struct RemoteUpload: Codable, Sendable, Equatable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    /// For all files of one message: base64 in JSON must stay under `RemoteFrame.maxPayload`.
    public static let maxTotalBytes = 5 << 20

    /// The host's folder for them (in its temporary folder).
    public static let folderName = "ClaudeDeckUploads"

    /// Pasted into Claude Code, a path with one of these extensions becomes an attached image.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// A file name safe to type into a prompt: no spaces (they end an @mention) or odd characters.
    public static func safeName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var safe = String(name.map { allowed.contains($0) ? $0 : "-" }.prefix(80))
        while safe.hasPrefix(".") || safe.hasPrefix("-") { safe.removeFirst() }
        return safe.isEmpty ? "file" : safe
    }
}

/// The host's sessions as the remote shows them.
public struct RemoteSnapshot: Codable, Sendable, Equatable {
    public var hostName: String
    public var sessions: [RemoteSession]
    /// Projects a remote can start sessions in.
    public var projects: [RemoteProject]?
    /// The plan's usage meter (Settings › usage on the Mac), when known.
    public var usage: RemoteUsage?
    /// The host's stable id (matches its Bonjour TXT record) and Tailscale addresses: a phone
    /// paired on the local network learns how to reach the host when away.
    public var hostID: UUID?
    public var addresses: [String]?
    /// `addresses` are in the order set on the Mac: devices try them as listed (no re-sorting).
    public var addressesOrdered: Bool?
    /// What the host understands beyond the basics (`Feature`); nil from hosts older than 0.4.6,
    /// which skip messages they don't know, so a remote checks before sending them.
    public var features: Set<String>?
    /// The agents the Mac can ask (hosts with `Feature.agents`).
    public var agents: [RemoteAgent]?
    /// Agents waiting for approval (hosts with `Feature.agentApproval`).
    public var pendingAgents: [RemotePendingAgent]?
    /// The host's home folder (hosts with `Feature.homeFiles`): Files' "Home" entry, absolute paths there.
    public var homePath: String?
    /// The host's ServerPlan servers and recent failed deploys (hosts with `Feature.serverPlan`,
    /// and only while ServerPlan is set up there). Older remotes ignore it.
    public var serverPlan: RemoteServerPlan?
    /// The Dashboard in brief (hosts with `Feature.dashboard`; only while a remote is connected).
    public var dashboard: RemoteDashboard?
    /// Booted and recently used simulators (hosts with `Feature.simulators`; only while the Mac's
    /// Simulators setting is on and a remote is connected).
    public var simulators: [RemoteSimulator]?
    /// Decisions sessions left for the owner: every pending one and the recently answered ones
    /// (hosts with `Feature.decisions`).
    public var decisions: [OwnerDecision]?
    /// The projects' `docs/AGENDA.md` boards (hosts with `Feature.agenda`; read-only).
    public var agendas: [RemoteAgenda]?
    /// The Agents overview's header (hosts with `Feature.agentTree`): sessions started by
    /// sessions that are running, the cap on them, and starts queued under it.
    public var agentsRunning: Int?
    public var agentsCap: Int?
    public var agentsQueued: Int?
    /// Approvals a session waits on (ServerPlan gates, domain purchases), the one expiring first
    /// on top (hosts with `Feature.approvals`).
    public var approvals: [OwnerApproval]?

    public enum Feature {
        /// `sendPromptWithFiles` (phone) and `pasteFiles` (another Mac).
        public static let files = "files"
        /// `permissionMode`.
        public static let permissionMode = "permissionMode"
        /// `projectAction`.
        public static let projectActions = "projectActions"
        /// `sessionAction`.
        public static let sessionActions = "sessionActions"
        /// `browseFolder` / `addProject`.
        public static let addProject = "addProject"
        /// `downloadFile` / `uploadFile`.
        public static let transfer = "transfer"
        /// `queuePrompt` / `queueAction`.
        public static let queue = "queue"
        /// `askAgents` / `agentNoteAction`, `agents` in the snapshot, notes in conversation pages.
        public static let agents = "agents"
        /// `agentRegistration`, `pendingAgents` in the snapshot.
        public static let agentApproval = "agentApproval"
        /// `agentDetails`.
        public static let agentDetails = "agentDetails"
        /// `agentRegistration` with `url` / `authHeader`, `needs` in `pendingAgents`.
        public static let agentCompletion = "agentCompletion"
        /// File requests for `RemoteFiles.homeID`: the Mac's home folder, not just projects.
        public static let homeFiles = "homeFiles"
        /// `RemoteProjectAction.renameFolder`, answered with `projectActionResult`.
        public static let renameFolder = "renameFolder"
        /// `editsRequest` / `netDiffRequest`.
        public static let edits = "edits"
        /// `ChatPage.updated`: pages after an anchor also carry the entries up to it that changed
        /// since (tool results that came in out of order).
        public static let historyUpdates = "historyUpdates"
        /// `conversationOpen` / `conversationClose`, answered with `conversationChanged`.
        public static let conversationPush = "conversationPush"
        /// `RemoteSession.program` on plain terminals that show their program's status.
        public static let programStatus = "programStatus"
        /// `serverPlan` in the snapshot (read-only; actions stay on the Mac).
        public static let serverPlan = "serverPlan"
        /// `serverPlanRepair` (Fix with Claude for a failed deploy), `projects` in `serverPlan`.
        public static let serverPlanRepair = "serverPlanRepair"
        /// `dashboard` in the snapshot.
        public static let dashboard = "dashboard"
        /// `simulators` in the snapshot (read-only).
        public static let simulators = "simulators"
        /// `decisions` in the snapshot, `answerDecision`.
        public static let decisions = "decisions"
        /// `agendas` in the snapshot (read-only).
        public static let agenda = "agenda"
        /// `dismissDecision`.
        public static let dismissDecision = "dismissDecision"
        /// `changeDecisionAnswer`; answered decisions carry `answerHistory` / `changedAt`.
        public static let changeDecisionAnswer = "changeDecisionAnswer"
        /// `RemoteSession.agent` and the `agents…` counts in the snapshot (read-only).
        public static let agentTree = "agentTree"
        /// `dismissServerIssues`; `RemoteServerPlan.Project.lastDeployCleared`.
        public static let dismissServerIssues = "dismissServerIssues"
        /// `RemoteServerPlan.registrarBalance` (the Namecheap balance, ServerPlan 1.4).
        public static let registrarBalance = "registrarBalance"
        /// `RemoteSession.kind`; stopped terminals come with the closed sessions, and
        /// `resumeSession` / `sessionAction(.startFresh)` start them again (same folder, same command).
        public static let closedTerminals = "closedTerminals"
        /// `approvals` in the snapshot, `answerApproval`.
        public static let approvals = "approvals"
        public static let all: Set<String> = [files, permissionMode, projectActions, sessionActions, addProject, transfer, queue, agents, agentApproval,
                                              agentDetails, agentCompletion, homeFiles, renameFolder, edits,
                                              historyUpdates, conversationPush, programStatus, serverPlan,
                                              serverPlanRepair, dashboard, simulators, decisions, agenda, dismissDecision,
                                              changeDecisionAnswer, agentTree, dismissServerIssues, registrarBalance,
                                              closedTerminals, approvals]
    }

    public func supports(_ feature: String) -> Bool { features?.contains(feature) == true }

    public init(hostName: String, sessions: [RemoteSession], hostID: UUID? = nil, addresses: [String]? = nil) {
        self.hostName = hostName
        self.sessions = sessions
        self.hostID = hostID
        self.addresses = addresses
    }

    public func session(_ id: UUID) -> RemoteSession? { sessions.first { $0.id == id } }
}

/// ServerPlan as the host sees it (RemoteSnapshot.serverPlan).
public struct RemoteServerPlan: Codable, Sendable, Equatable {
    public struct Server: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var name: String
        /// online | offline | unknown
        public var status: String
        public init(id: Int, name: String, status: String) {
            self.id = id
            self.name = name
            self.status = status
        }
    }

    public struct Deploy: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var project: String
        public var server: String?
        /// pending | building | transferring | deploying | success | failed | cancelled
        public var status: String
        public var error: String?
        public var finishedAt: Date?
        public init(id: Int, project: String, server: String?, status: String, error: String?, finishedAt: Date?) {
            self.id = id
            self.project = project
            self.server = server
            self.status = status
            self.error = error
            self.finishedAt = finishedAt
        }
    }

    /// A ServerPlan project with its last deploy (hosts with `Feature.serverPlanRepair`).
    public struct Project: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var name: String
        /// The server it deploys to.
        public var serverID: Int?
        public var lastDeployID: Int?
        /// As `Deploy.status`.
        public var lastDeployStatus: String?
        public var lastDeployAt: Date?
        /// The last deploy failed and that failure was cleared on the Mac (hosts with
        /// `Feature.dismissServerIssues`): shown without the alarm.
        public var lastDeployCleared: Bool?
        public init(id: Int, name: String, serverID: Int?, lastDeployID: Int?, lastDeployStatus: String?, lastDeployAt: Date?) {
            self.id = id
            self.name = name
            self.serverID = serverID
            self.lastDeployID = lastDeployID
            self.lastDeployStatus = lastDeployStatus
            self.lastDeployAt = lastDeployAt
        }
    }

    /// The Namecheap balance (hosts with `Feature.registrarBalance`, a 1.4 panel with Namecheap).
    public struct Balance: Codable, Sendable, Equatable {
        public var available: Double
        public var currency: String
        /// The threshold in force (the panel's, else the Mac's setting); nil: no alert.
        public var threshold: Double?
        public var low: Bool
        public init(available: Double, currency: String, threshold: Double?, low: Bool) {
            self.available = available
            self.currency = currency
            self.threshold = threshold
            self.low = low
        }
    }

    public var servers: [Server]
    /// Running and recently failed deploys, newest first.
    public var deploys: [Deploy]
    /// nil from hosts without `Feature.serverPlanRepair`.
    public var projects: [Project]?
    /// nil from older hosts, older panels, or a panel without Namecheap.
    public var registrarBalance: Balance?

    public init(servers: [Server], deploys: [Deploy]) {
        self.servers = servers
        self.deploys = deploys
    }
}

public struct RemoteUsage: Codable, Sendable, Equatable {
    public var fiveHour: Double?
    public var fiveHourResetsAt: Date?
    public var week: Double?
    public var weekResetsAt: Date?
    public init(fiveHour: Double?, fiveHourResetsAt: Date?, week: Double?, weekResetsAt: Date?) {
        self.fiveHour = fiveHour
        self.fiveHourResetsAt = fiveHourResetsAt
        self.week = week
        self.weekResetsAt = weekResetsAt
    }
}

public struct RemoteFileEntry: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int
    public var id: String { name }
    /// Dot-file hidden by default on the phone (except the useful ones, as on the Mac).
    public var isHidden: Bool { name.hasPrefix(".") && name != ".claude" && name != ".github" }
    public init(name: String, isDirectory: Bool, size: Int) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct RemotePastConversation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var modifiedAt: Date
    public init(id: String, title: String, modifiedAt: Date) {
        self.id = id
        self.title = title
        self.modifiedAt = modifiedAt
    }
}

public struct RemoteProject: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Pinned on the host: shown first, even without a running session.
    public var pinned: Bool
    /// The folder on the host (Copy Path); nil from older hosts.
    public var path: String?
    public init(id: UUID, name: String, pinned: Bool = false, path: String? = nil) {
        self.id = id
        self.name = name
        self.pinned = pinned
        self.path = path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false  // older hosts
        path = try c.decodeIfPresent(String.self, forKey: .path)
    }
}

public struct RemoteSession: Codable, Sendable, Equatable, Identifiable {
    /// Mirrors the host sidebar's display state.
    public enum State: String, Codable, Sendable {
        case notStarted, starting, shell, running, needsPermission, needsAnswer, idle, ended

        public var isBlocked: Bool { self == .needsPermission || self == .needsAnswer }
    }

    public var id: UUID
    public var name: String
    public var project: String
    public var state: State
    public var detail: String?
    public var updatedAt: Date?
    /// Finished and not yet looked at on the host.
    public var unseen: Bool
    /// Set while a permission prompt can be answered with Allow / Deny (see `pendingPermissionStamp`).
    public var permissionStamp: Double?
    /// Messages waiting for "your turn" (hosts with `Feature.queue`).
    public var queue: [QueuedPrompt]?
    /// Changes whenever the session's agent notes do: a remote with the conversation open asks
    /// for the page (the notes come with it).
    public var notesRevision: Int?
    /// What the program in a plain terminal is doing (hosts with `Feature.programStatus`). `state`
    /// stays `.shell`, so older remotes still treat it as a terminal; `detail` says it in words.
    public var program: RemoteProgramStatus?
    /// Claude sessions in an agent tree (`claudedeck new`): who started it, its launch options,
    /// what it holds (hosts with `Feature.agentTree`). Older remotes ignore it.
    public var agent: RemoteAgentInfo?
    /// "claude" or "terminal" (hosts with `Feature.closedTerminals`; nil from older hosts). A
    /// string, so a newer host's kinds don't break decoding. A stopped terminal stays
    /// `.notStarted` on the wire, so older remotes list it with the closed sessions.
    public var kind: String?

    public static let terminalKind = "terminal"
    public static let claudeKind = "claude"

    public init(
        id: UUID, name: String, project: String, state: State, detail: String? = nil,
        updatedAt: Date? = nil, unseen: Bool = false, permissionStamp: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.project = project
        self.state = state
        self.detail = detail
        self.updatedAt = updatedAt
        self.unseen = unseen
        self.permissionStamp = permissionStamp
    }

    /// A plain terminal: running (`.shell`), or stopped on a host that says so.
    public var isTerminal: Bool { state == .shell || kind == Self.terminalKind }

    public var needsAttention: Bool {
        if state == .shell, let program { return program.isBlocked || (program.isOutcome && unseen) }
        return state.isBlocked || (state == .idle && unseen)
    }

    /// Identifies one attention-worthy moment: a second permission request in the same turn has
    /// a new timestamp and notifies again. nil when nothing needs the user.
    public var attentionKey: String? {
        guard needsAttention else { return nil }
        return "\(state.rawValue)|\(updatedAt?.timeIntervalSince1970 ?? 0)"
    }
}

/// A session's place in an agent tree on the wire (`RemoteSession.agent`). Sent only for sessions
/// in a tree; `startedBy` nil marks a lead.
public struct RemoteAgentInfo: Codable, Sendable, Equatable {
    public var startedBy: UUID?
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    /// The Claude account's label, when the host has more than one account.
    public var account: String?
    /// `limit_reached` / `switching_account` while that's so (the session's `state` says the rest).
    public var limitState: String?
    /// When its process started (nil while it isn't running).
    public var runningSince: Date?
    public var simulators: Int?
    public var pendingDecisions: Int?
    public var queuedStarts: Int?

    public init(startedBy: UUID? = nil, model: String? = nil, effort: String? = nil, permissionMode: String? = nil,
                account: String? = nil, limitState: String? = nil, runningSince: Date? = nil,
                simulators: Int? = nil, pendingDecisions: Int? = nil, queuedStarts: Int? = nil) {
        self.startedBy = startedBy
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.account = account
        self.limitState = limitState
        self.runningSince = runningSince
        self.simulators = simulators
        self.pendingDecisions = pendingDecisions
        self.queuedStarts = queuedStarts
    }
}

/// A plain terminal's program status on the wire (ProgramStatus.swift on the host).
public struct RemoteProgramStatus: Codable, Sendable, Equatable {
    /// "working", "blocked", "finished", "failed" or "service" (a dev server or watcher: running,
    /// not working; newer hosts). A string, so a newer host's states don't break decoding;
    /// remotes ignore ones they don't know (a service then reads as a plain terminal).
    public var state: String
    /// The command's exit code, when known.
    public var exitCode: Int32?
    /// What a blocked program waits for: "permission", "question" or "auth".
    public var kind: String?
    /// "service": the TCP ports it listens on (absent when marked a service by hand).
    public var ports: [Int]?

    public init(state: String, exitCode: Int32? = nil, kind: String? = nil, ports: [Int]? = nil) {
        self.state = state
        self.exitCode = exitCode
        self.kind = kind
        self.ports = ports
    }

    public var isBlocked: Bool { state == "blocked" }
    public var isWorking: Bool { state == "working" }
    public var isService: Bool { state == "service" }
    /// Finished or failed: the result is ready.
    public var isOutcome: Bool { state == "finished" || state == "failed" }
}

extension RemoteSnapshot {
    /// Sessions that need the user in `new` and didn't (for the same reason) in `old`.
    /// The first snapshot after connecting (`old == nil`) is a baseline: nothing to announce.
    public static func newAttention(from old: RemoteSnapshot?, to new: RemoteSnapshot) -> [RemoteSession] {
        guard let old else { return [] }
        return new.sessions.filter { session in
            guard let key = session.attentionKey else { return false }
            return old.session(session.id)?.attentionKey != key
        }
    }
}

// MARK: Handshake

/// Mutual proof of the pairing key. Each side signs both nonces with its own role label, so a
/// proof can't be replayed in the other direction or in another connection.
public enum RemoteHandshake {
    public static func makeNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    public static func proof(key: Data, role: String, first: Data, second: Data) -> Data {
        var message = Data(role.utf8)
        message.append(0)
        message.append(first)
        message.append(second)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    public static func hostProof(key: Data, remoteNonce: Data, hostNonce: Data) -> Data {
        proof(key: key, role: "claudedeck-host", first: remoteNonce, second: hostNonce)
    }

    public static func remoteProof(key: Data, remoteNonce: Data, hostNonce: Data) -> Data {
        proof(key: key, role: "claudedeck-remote", first: hostNonce, second: remoteNonce)
    }

    /// The pairing key for a password typed on both Macs (PBKDF2-SHA256). The salt is fixed so
    /// both sides derive the same key without talking first; the connection only exists inside
    /// the tailnet, and the host throttles wrong guesses.
    public static func key(fromPassword password: String, rounds: UInt32 = 300_000) -> Data {
        let salt = Data("claudedeck-remote-v1".utf8)
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        var key = Data(count: 32)
        let keyCount = key.count
        let status = key.withUnsafeMutableBytes { keyBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordBytes.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress, keyCount
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return key
    }

    public static let minimumPasswordLength = 8

    /// Constant-time comparison.
    public static func matches(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: Pairing

/// Everything a remote needs to reach a host: shared through iCloud Drive, or as a QR code /
/// copyable `claudedeck://pair?…` link.
public struct RemotePairing: Codable, Sendable, Equatable, Identifiable {
    /// Stable id of the host Mac (survives renames and key changes).
    public var id: UUID
    public var hostName: String
    /// Tailscale MagicDNS name first, then Tailscale IPs.
    public var addresses: [String]
    public var port: UInt16
    public var key: Data
    public var updatedAt: Date

    public init(id: UUID, hostName: String, addresses: [String], port: UInt16, key: Data, updatedAt: Date) {
        self.id = id
        self.hostName = hostName
        self.addresses = addresses
        self.port = port
        self.key = key
        self.updatedAt = updatedAt
    }

    public static let defaultPort: UInt16 = 47821

    /// The port the host listens on: `CLAUDEDECK_REMOTE_PORT` (demo copies), else the default.
    public static func listenPort(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16 {
        environment["CLAUDEDECK_REMOTE_PORT"].flatMap(UInt16.init) ?? defaultPort
    }

    /// Ports another listener of this app (the agents' API) must leave alone: the remote one in
    /// use, and the default one (a demo copy must not take the real app's).
    public static func reservedPorts(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<Int> {
        [Int(defaultPort), Int(listenPort(environment: environment))]
    }

    public static func makeKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RemotePairing {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(RemotePairing.self, from: data)
    }

    /// `claudedeck://pair?d=<base64url JSON>` — the QR code's and the copy button's content.
    public func link() throws -> String {
        let encoded = try encoded().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "claudedeck://pair?d=\(encoded)"
    }

    /// Accepts the link, with surrounding whitespace (pasted text).
    public static func parse(link: String) -> RemotePairing? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme == "claudedeck",
              components.host == "pair",
              var base64 = components.queryItems?.first(where: { $0.name == "d" })?.value
        else { return nil }
        base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let pairing = try? decode(data),
              !pairing.key.isEmpty, !pairing.addresses.isEmpty
        else { return nil }
        return pairing
    }
}

// MARK: Local state

/// The secrets in `RemoteLocalState` that live in the Keychain once migrated (RemoteSecrets.swift).
public enum RemoteSecret: String, Codable, Sendable, CaseIterable {
    case hostKey
    case passwordKey
    /// The APNs .p8 key's PEM (its key and team ids stay in the file).
    case apnsKey
}

/// This Mac's remote-mode identity and pairing, in `remote.json` next to `deck.json` (0600).
/// The keys go to the Keychain (`RemoteLocalStore`): the file keeps one only while the Keychain
/// can't take it, and lists the ones the Keychain holds.
public struct RemoteLocalState: Codable, Sendable, Equatable {
    /// Stable id of this Mac as a host.
    public var hostID = UUID()
    /// The key remotes must prove (host side). Replaced by "New key". Empty while the Keychain
    /// hasn't given it back (`unreadSecrets`).
    public var hostKey = RemotePairing.makeKey() { didSet { unreadSecrets.remove(.hostKey) } }
    /// Host chosen among the ones found in iCloud Drive (remote side).
    public var pairedHostID: UUID?
    /// Pairing pasted from a link / QR code; wins over iCloud Drive.
    public var manualPairing: RemotePairing?
    /// Host side: `hostKey` was derived from a password the user chose.
    public var hostUsesPassword = false
    /// Remote side: key derived from the password typed here (finds the host through Tailscale).
    public var passwordKey: Data? { didSet { unreadSecrets.remove(.passwordKey) } }
    /// Remote side: the address the password-found host answered on last time (tried first).
    public var lastHostAddress: String?
    /// Host side: the APNs auth key for iPhone pushes, and the phones that registered.
    public var apns: APNsCredentials? { didSet { unreadSecrets.remove(.apnsKey) } }
    public var pushDevices: [PushDevice] = []
    /// Secrets the Keychain holds instead of the file (listed in the file as `keychain`).
    public var keychainSecrets: Set<RemoteSecret> = []
    /// Secrets the Keychain didn't give back at load (locked, access denied): left alone there and
    /// asked for again later. Setting a new value clears its entry. Not saved.
    public var unreadSecrets: Set<RemoteSecret> = []
    /// What the Keychain was last seen holding, by secret (saves skip unchanged ones). Not saved.
    public var verified: [RemoteSecret: Data] = [:]

    /// The host key is known: this Mac can host and publish its pairing.
    public var hasHostKey: Bool { !hostKey.isEmpty && !unreadSecrets.contains(.hostKey) }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case hostID, hostKey, pairedHostID, manualPairing, hostUsesPassword, passwordKey, lastHostAddress, apns, pushDevices
        case keychainSecrets = "keychain"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let inKeychain = Set(try c.decodeIfPresent([RemoteSecret].self, forKey: .keychainSecrets) ?? [])
        hostID = try c.decodeIfPresent(UUID.self, forKey: .hostID) ?? UUID()
        // A key in the file wins (put there because the Keychain failed, or by an older version).
        // Absent and held by the Keychain: empty until `RemoteLocalStore` reads it. Absent
        // otherwise: a new identity, as before.
        let fileKey = try c.decodeIfPresent(Data.self, forKey: .hostKey).flatMap { $0.isEmpty ? nil : $0 }
        hostKey = fileKey ?? (inKeychain.contains(.hostKey) ? Data() : RemotePairing.makeKey())
        pairedHostID = try c.decodeIfPresent(UUID.self, forKey: .pairedHostID)
        manualPairing = try c.decodeIfPresent(RemotePairing.self, forKey: .manualPairing)
        hostUsesPassword = try c.decodeIfPresent(Bool.self, forKey: .hostUsesPassword) ?? false
        passwordKey = try c.decodeIfPresent(Data.self, forKey: .passwordKey)
        lastHostAddress = try c.decodeIfPresent(String.self, forKey: .lastHostAddress)
        apns = try c.decodeIfPresent(APNsCredentials.self, forKey: .apns)
        pushDevices = try c.decodeIfPresent([PushDevice].self, forKey: .pushDevices) ?? []
        // Only what the file doesn't hold itself is the Keychain's.
        keychainSecrets = inKeychain.filter { secret in
            switch secret {
            case .hostKey: fileKey == nil
            case .passwordKey: passwordKey == nil
            case .apnsKey: apns != nil && apns?.keyPEM.isEmpty == true
            }
        }
        unreadSecrets = []
    }

    /// Leaves out the secrets in `keychainSecrets` (the APNs entry keeps its ids, without the key).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hostID, forKey: .hostID)
        if !keychainSecrets.contains(.hostKey) { try c.encode(hostKey, forKey: .hostKey) }
        try c.encodeIfPresent(pairedHostID, forKey: .pairedHostID)
        try c.encodeIfPresent(manualPairing, forKey: .manualPairing)
        try c.encode(hostUsesPassword, forKey: .hostUsesPassword)
        if !keychainSecrets.contains(.passwordKey) { try c.encodeIfPresent(passwordKey, forKey: .passwordKey) }
        try c.encodeIfPresent(lastHostAddress, forKey: .lastHostAddress)
        if var apns {
            if keychainSecrets.contains(.apnsKey) { apns.keyPEM = "" }
            try c.encode(apns, forKey: .apns)
        }
        try c.encode(pushDevices, forKey: .pushDevices)
        if !keychainSecrets.isEmpty { try c.encode(keychainSecrets.map(\.rawValue).sorted(), forKey: .keychainSecrets) }
    }

    /// A secret's value (nil: none).
    public func secretData(_ secret: RemoteSecret) -> Data? {
        switch secret {
        case .hostKey: hostKey.isEmpty ? nil : hostKey
        case .passwordKey: passwordKey
        case .apnsKey: apns.flatMap { $0.keyPEM.isEmpty ? nil : Data($0.keyPEM.utf8) }
        }
    }

    /// Puts a secret read back from the Keychain in place.
    public mutating func setSecretData(_ secret: RemoteSecret, _ data: Data) {
        switch secret {
        case .hostKey: hostKey = data
        case .passwordKey: passwordKey = data
        case .apnsKey: apns?.keyPEM = String(decoding: data, as: UTF8.self)
        }
    }

    /// The file alone (no Keychain: see `RemoteLocalStore.load`), or a fresh identity, saved.
    /// An unreadable file is kept aside, not overwritten silently.
    public static func load(from url: URL) -> RemoteLocalState {
        if let state = read(from: url) { return state }
        let state = RemoteLocalState()
        try? state.save(to: url)
        return state
    }

    /// The file as it is; nil when it's missing or unreadable (then copied aside).
    public static func read(from url: URL) -> RemoteLocalState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let state = try? decoder.decode(RemoteLocalState.self, from: data) { return state }
        let broken = url.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: url, to: broken)
        return nil
    }

    /// Atomically, readable by this user only from the first byte.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(try encoder.encode(self), to: url)
    }
}

/// A file only this user may read, replaced atomically and created 0600 (never briefly with the
/// default permissions, as a write followed by chmod would be).
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}


#if os(macOS)
/// Pairing records in a shared folder (iCloud Drive `ClaudeDeck/Remote/<host id>.json`).
public enum RemotePairingFolder {
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard DeckSyncFile.iCloudDriveAvailable(home: home) else { return nil }
        return DeckSyncFile.iCloudDriveRoot(home: home).appending(path: "ClaudeDeck/Remote")
    }

    public static func readAll(in folder: URL) -> [RemotePairing] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            // Not downloaded yet (".<id>.json.icloud"): ask for it; the folder watcher fires when it lands.
            if url.lastPathComponent.hasPrefix("."), url.pathExtension == "icloud" {
                let name = String(url.deletingPathExtension().lastPathComponent.dropFirst())
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appending(path: name))
                return nil
            }
            guard url.pathExtension == "json", !url.lastPathComponent.hasPrefix("."),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? RemotePairing.decode(data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func url(for id: UUID, in folder: URL) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }

    /// Writes only when the content changed (an iCloud upload per write).
    public static func write(_ pairing: RemotePairing, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = url(for: pairing.id, in: folder)
        if let data = try? Data(contentsOf: url), var existing = try? RemotePairing.decode(data) {
            existing.updatedAt = pairing.updatedAt
            if existing == pairing { return }
        }
        try pairing.encoded().write(to: url, options: .atomic)
    }

    public static func remove(_ id: UUID, in folder: URL) {
        try? FileManager.default.removeItem(at: url(for: id, in: folder))
    }
}
#endif

/// An approval a session asks the owner for and waits on (Approvals.swift on the Mac): a ServerPlan
/// action the panel wants confirmed, or a domain purchase. Sent to phones in the snapshot.
public struct OwnerApproval: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A gated `claudedeck server` action (the panel's 428).
        case serverPlan
        /// `claudedeck server domain buy`: real money from the Namecheap balance.
        case domainPurchase
        case other

        /// Kinds a newer Mac sends that this side doesn't know read as `other`.
        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    public var id: String
    public var kind: Kind
    /// One line: who wants what ("api-dev wants to run “container stop” on web").
    public var title: String
    /// The panel's own summary (what the action does; for a purchase the price and the balance).
    public var summary: String
    /// The command and its target as the session sent them.
    public var command: String
    public var target: String
    public var sessionID: UUID?
    public var session: String
    public var project: String
    public var createdAt: Date
    /// No answer by then: refused.
    public var expiresAt: Date
    /// Whether a phone may approve it. False for purchases (they're approved on the Mac only)
    /// and, for now, for every ServerPlan gate (those were only ever approved on the Mac).
    public var phoneMayApprove: Bool
    /// Whether a phone may refuse it (refusing never changes anything; purchases stay read-only
    /// on the phone all the same).
    public var phoneMayRefuse: Bool

    public init(id: String, kind: Kind, title: String, summary: String, command: String, target: String,
                sessionID: UUID?, session: String, project: String, createdAt: Date, expiresAt: Date,
                phoneMayApprove: Bool = false, phoneMayRefuse: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.command = command
        self.target = target
        self.sessionID = sessionID
        self.session = session
        self.project = project
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.phoneMayApprove = kind == .domainPurchase ? false : phoneMayApprove
        self.phoneMayRefuse = kind == .domainPurchase ? false : (phoneMayRefuse ?? true)
    }

    public var isPurchase: Bool { kind == .domainPurchase }

    /// An id as the Mac makes it: `a_` and letters or digits (checked before a phone's answer is used).
    public static func isValidID(_ id: String) -> Bool {
        id.hasPrefix("a_") && id.count > 2 && id.count <= 40 && id.dropFirst(2).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
