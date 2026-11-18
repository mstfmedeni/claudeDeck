import AppKit
import ClaudeDeckCore
import Foundation
import Observation
import os
import SwiftTerm

let ptydLog = Logger(subsystem: "ClaudeDeck", category: "ptyd")

/// The user's login shell and a clean environment for launching `claude` in it.
enum ShellEnvironment {
    /// The user's login shell if it is POSIX-compatible (the launch script uses "$0" "$@"),
    /// otherwise zsh.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            let posix: Set<String> = ["zsh", "bash", "sh", "dash", "ksh"]
            if posix.contains((path as NSString).lastPathComponent), FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/bin/zsh"
    }

    /// Session markers a parent Claude Code leaves in the environment (e.g. when ClaudeDeck itself
    /// was launched from a Claude terminal). Inherited, they make `claude` run as a "child session"
    /// with transcripts and hooks disabled. The login shell re-exports anything the user sets in
    /// their profile, so dropping them here is safe.
    static func isInheritedMarker(_ key: String) -> Bool {
        key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDEDECK_")
            || key == "CLAUDE_PROJECT_DIR" || key == "CLAUDE_ENV_FILE" || key.hasPrefix("CLAUDE_PLUGIN_")
    }

    /// Backslash-escapes a path the way Terminal.app does for dropped files.
    static func escapedPath(_ path: String) -> String {
        var out = ""
        for ch in path {
            if " '\"\\()[]{}&;|<>*?!$`#~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static var cleanEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !isInheritedMarker($0.key) }
    }

    static func environment(terminalID: UUID, extra: [String: String] = [:]) -> [String] {
        var env = cleanEnvironment.merging(extra) { $1 }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ClaudeDeck"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["CLAUDEDECK_TERMINAL_ID"] = terminalID.uuidString
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Absolute path of `claude` as the login shell sees it (nil if not installed).
    /// `CLAUDEDECK_CLAUDE_PATH` overrides it (demo mode runs a stand-in).
    static func resolveClaude() -> String? {
        if let path = ProcessInfo.processInfo.environment["CLAUDEDECK_CLAUDE_PATH"], !path.isEmpty { return path }
        for flags in ["-lc", "-lic"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: loginShell)
            p.arguments = [flags, "command -v claude"]
            p.environment = cleanEnvironment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            // A prompting or slow rc file must not hang the app.
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); continue }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let line = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces),
               line.hasPrefix("/") {
                return line
            }
        }
        return nil
    }
}

final class DeckTerminalView: LocalProcessTerminalView {
    /// Terminal background for the current appearance (dark: near-black, light: near-white).
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.1, alpha: 1)
            : NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)
    }
    static let foreground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.9, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)
    }
    let sessionID: UUID

    init(sessionID: UUID, fontSize: CGFloat = 13) {
        self.sessionID = sessionID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        optionAsMetaKey = true
        applyColors()
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Resolve the dynamic colors for the view's current appearance (SwiftTerm stores concrete colors).
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = Self.background.usingColorSpace(.deviceRGB) ?? Self.background
            nativeForegroundColor = Self.foreground.usingColorSpace(.deviceRGB) ?? Self.foreground
            caretColor = nativeForegroundColor
        }
    }

    /// Folder the session started in (project or worktree); relative paths in the output resolve here.
    var workingDirectory: String?
    /// ⌘⌥-click on a file path: open the file itself (built-in editor or default app).
    var onOpenFile: ((URL) -> Void)?

    /// ⌘-click on a detected link. URLs open in their app; file paths are resolved against the
    /// shell's reported directory, then the session folder, and shown in Finder (⌘⌥: opened).
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openedLink = true
        let dirs = [TerminalLink.directory(fromHostURI: getTerminal().hostCurrentDirectory), workingDirectory].compactMap { $0 }
        open(TerminalLink.resolve(link, in: dirs), openFile: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    private func open(_ link: TerminalLink?, openFile: Bool) {
        switch link {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .file(let url, _):
            if openFile, let onOpenFile {
                onOpenFile(url)
            } else if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case nil:
            NSSound.beep()
        }
    }

    /// The session's Claude transcript, searched for the full path of a ⌘-clicked bare file name.
    var transcriptPath: (() -> String?)?
    private var openedLink = false
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        dragged = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        super.mouseDragged(with: event)
    }

    /// ⌘-click on a file name SwiftTerm didn't detect as a link (Claude's `[file] promo.mp4`):
    /// look the name up in the session folder, the transcript and the project's files.
    override func mouseUp(with event: NSEvent) {
        openedLink = false
        super.mouseUp(with: event)
        let flags = event.modifierFlags
        guard flags.contains(.command), !openedLink, !dragged, event.clickCount == 1,
              let name = fileName(at: convert(event.locationInWindow, from: nil)) else { return }
        let dirs = [TerminalLink.directory(fromHostURI: getTerminal().hostCurrentDirectory), workingDirectory].compactMap { $0 }
        let folder = workingDirectory
        let transcript = transcriptPath?()
        let openFile = flags.contains(.option)
        Task { [weak self] in
            let url = await Task.detached(priority: .userInitiated) {
                BareFileName.locate(name, directories: dirs, sessionFolder: folder, transcriptPath: transcript)
            }.value
            self?.open(url.map { .file($0, line: nil) }, openFile: openFile)
        }
    }

    /// The file-name-like token under `point` in the visible screen, joined across wrapped rows.
    private func fileName(at point: NSPoint) -> String? {
        let terminal = getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return nil }
        // SwiftTerm's cell size isn't public; its optimal frame is cols × rows cells plus the scroller.
        let optimal = getOptimalFrameSize()
        let scroller = subviews.first { $0 is NSScroller } as? NSScroller
        let scrollerWidth = scroller == nil || scroller!.isHidden
            ? 0 : NSScroller.scrollerWidth(for: .regular, scrollerStyle: scroller!.scrollerStyle)
        let cellWidth = (optimal.width - scrollerWidth) / CGFloat(terminal.cols)
        let cellHeight = optimal.height / CGFloat(terminal.rows)
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let row = Int((frame.height - point.y) / cellHeight)
        let col = min(max(Int(point.x / cellWidth), 0), terminal.cols - 1)
        guard let line = terminal.getLine(row: row) else { return nil }

        func cells(_ line: BufferLine) -> [String] {
            (0..<terminal.cols).map { i in
                let data = line[i]
                if data.width == 0 { return "" }
                let ch = terminal.getCharacter(for: data)
                return ch == "\0" ? " " : String(ch)
            }
        }
        var first = row, last = row
        while first > 0, terminal.getLine(row: first)?.isWrapped == true { first -= 1 }
        while let next = terminal.getLine(row: last + 1), next.isWrapped { last += 1 }
        var all: [String] = []
        for r in first...last {
            all += cells(r == row ? line : terminal.getLine(row: r)!)
        }
        return BareFileName.token(inCells: all, column: (row - first) * terminal.cols + col)
    }

    /// Trackpad pinch zooms all terminals.
    var onMagnify: ((CGFloat) -> Void)?
    private var pinch: CGFloat = 0

    override func magnify(with event: NSEvent) {
        pinch += event.magnification
        if abs(pinch) >= 0.15 {
            onMagnify?(pinch > 0 ? 1 : -1)
            pinch = 0
        }
        if event.phase == .ended || event.phase == .cancelled { pinch = 0 }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?
    /// Claude sessions read images from the clipboard themselves on Ctrl+V.
    var isClaude = true

    /// ⌘V: SwiftTerm only pastes text. With an image (screenshot, copied photo) and no text on
    /// the clipboard, send Ctrl+V so Claude attaches the clipboard image — like in Terminal.app.
    /// Copied Finder files paste as escaped paths.
    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
        let hasText = !(pb.string(forType: .string) ?? "").isEmpty
        if !hasText {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                send(txt: urls.map { ShellEnvironment.escapedPath($0.path) }.joined(separator: " ") + " ")
                return
            }
            let hasImage = pb.canReadObject(forClasses: [NSImage.self], options: nil)
            if hasImage, isClaude {
                send(txt: "\u{16}")
                return
            }
        }
        super.paste(sender)
    }

    /// Terminal.app keys the menu bar doesn't route here: ⌘F find bar, ⌘G next match
    /// (⇧Return in the bar goes back; ⇧⌘G stays Changes), ⌘K clear, ⌘⌫ delete to line start.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Focus is in this terminal or its find bar (the field editor sits inside it).
        guard let focused = window?.firstResponder as? NSView, focused.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard mods == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": findAction(.showFindInterface)
        case "g": findAction(.nextMatch)
        case "k":
            // Wipe screen + scrollback, then Ctrl+L so the shell / Claude redraws its prompt.
            feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
            send(txt: "\u{0c}")
        case "\u{7f}": send(txt: "\u{15}")  // Ctrl+U
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func findAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Watching a session in a helper this app can't drive: no input.
        if helperReadOnly { return }
        onInput?(data)
        if let helperInput { helperInput(data); return }
        super.send(source: source, data: data)
    }

    // MARK: Session helper (claudedeck-ptyd)

    /// Set while the process runs in the session helper: input goes there instead of a local pty.
    var helperInput: ((ArraySlice<UInt8>) -> Void)?
    /// Attached read-only to a helper this app can't drive.
    var helperReadOnly = false
    /// The grid changed. Only helper sessions need it: LocalProcessTerminalView resizes its own
    /// pty, but reports nothing while it has no local process.
    var onGridChange: ((Int, Int) -> Void)?
    private var reportedGrid: (cols: Int, rows: Int)?

    func reportGridIfChanged() {
        guard onGridChange != nil else { return }
        let terminal = getTerminal()
        guard reportedGrid?.cols != terminal.cols || reportedGrid?.rows != terminal.rows else { return }
        reportedGrid = (terminal.cols, terminal.rows)
        onGridChange?(terminal.cols, terminal.rows)
    }

    /// Output that arrived while the scrollback was still being replayed (appended after it).
    private var replayToken: UUID?
    private var pendingLive: [UInt8] = []

    /// Live output from the helper.
    func helperOutput(_ bytes: [UInt8]) {
        if replayToken != nil { pendingLive += bytes; return }
        dataReceived(slice: bytes[...])
    }

    /// Replays the helper's scrollback a chunk at a time (a few MB per session at launch would
    /// otherwise hold up the main thread), then whatever came in meanwhile. The replay isn't
    /// streamed to remote viewers (`onOutput`): they get the finished screen.
    func replay(_ bytes: [UInt8], cols: Int, rows: Int, done: @escaping @MainActor () -> Void) {
        let token = UUID()
        replayToken = token
        pendingLive = []
        let terminal = getTerminal()
        terminal.resetToInitialState()
        // The output was drawn for the helper's grid; replay it at that size.
        if cols > 0, rows > 0, terminal.cols != cols || terminal.rows != rows { terminal.resize(cols: cols, rows: rows) }
        reportedGrid = (terminal.cols, terminal.rows)
        Task { @MainActor [weak self] in
            var offset = 0
            while offset < bytes.count {
                guard let self, self.replayToken == token else { return }
                let end = min(offset + 256 * 1024, bytes.count)
                self.feed(byteArray: bytes[offset..<end])
                // Program Status picks up what the scrollback last reported (no replies to old queries).
                if self.programMonitor != nil {
                    let now = Date()
                    if self.programMonitor?.feed(bytes[offset..<end], now: now).changed == true { self.onProgramStatus?() }
                }
                offset = end
                await Task.yield()
            }
            guard let self, self.replayToken == token else { return }
            self.replayToken = nil
            let live = self.pendingLive
            self.pendingLive = []
            if !live.isEmpty { self.dataReceived(slice: live[...]) }
            // Back to the window's grid (a SIGWINCH redraws the TUI at that size).
            if self.window != nil { self.setFrameSize(self.frame.size) }
            self.needsDisplay = true
            done()
        }
    }

    /// Detaches from the helper (the process ended, or the helper went away).
    func clearHelper() {
        helperInput = nil
        helperReadOnly = false
        onGridChange = nil
        reportedGrid = nil
        replayToken = nil
        pendingLive = []
    }

    /// Grid imposed by a remote viewer (a phone fits the terminal to its screen); nil = the frame decides.
    var forcedGrid: (cols: Int, rows: Int)? {
        didSet { applyForcedGrid(release: forcedGrid == nil && oldValue != nil) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if forcedGrid != nil { applyForcedGrid(release: false) }
        reportGridIfChanged()
    }

    private func applyForcedGrid(release: Bool) {
        if release {
            // Back to the window's size.
            setFrameSize(frame.size)
            return
        }
        guard let grid = forcedGrid else { return }
        let terminal = getTerminal()
        guard terminal.cols != grid.cols || terminal.rows != grid.rows else { return }
        terminal.resize(cols: grid.cols, rows: grid.rows)
        sizeChanged(source: terminal)  // tells the pty (SIGWINCH) and our delegate
        reportGridIfChanged()          // the same for a session in the helper
        needsDisplay = true
    }

    /// While no window is visible, output still goes into the buffer but redraws wait: AppKit
    /// draws the views of a covered window (or one on a sleeping display) too, and a busy TUI
    /// had the terminal redrawn many times a second for nobody. One full redraw on resume.
    var drawingPaused = false {
        didSet {
            guard !drawingPaused, oldValue, missedDisplay else { return }
            missedDisplay = false
            super.needsDisplay = true
        }
    }
    private var missedDisplay = false

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        if drawingPaused { missedDisplay = true; return }
        super.setNeedsDisplay(invalidRect)
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if drawingPaused, newValue { missedDisplay = true; return }
            super.needsDisplay = newValue
        }
    }

    /// Raw pty output (remote mode streams it to watching Macs).
    var onOutput: ((ArraySlice<UInt8>) -> Void)?

    /// Plain terminals with Program Status on: OSC 7501 / OSC 133 pulled from the output (nil: off,
    /// the output isn't looked at). Chunks without an escape sequence are skipped whole.
    var programMonitor: ProgramStatusMonitor?
    /// The program status changed (not called for output that leaves it as it was).
    var onProgramStatus: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if programMonitor != nil { scanProgramStatus(slice) }
        onOutput?(slice)
        if timesOutput { lastOutputAt = Date() }
    }

    private func scanProgramStatus(_ slice: ArraySlice<UInt8>) {
        let now = Date()
        let result = slice.withUnsafeBufferPointer { programMonitor?.feed($0, now: now) }
        // `OSC 7501 ; ?`: tell the program this terminal understands it (straight to the pty,
        // not through `send`, which counts as the user typing).
        if result?.replyToQuery == true {
            let reply = ArraySlice(ProgramStatusParser.queryReply.utf8)
            // A process in the session helper has no local pty; read-only viewers don't answer.
            if let helperInput { helperInput(reply) } else if !helperReadOnly { process.send(data: reply) }
        }
        if result?.changed == true { onProgramStatus?() }
    }

    /// When output last came, kept only once `claudedeck send` typed into this terminal (its
    /// `wait` goes by the output settling, too).
    var timesOutput = false
    private(set) var lastOutputAt: Date?
}

/// Owns every terminal view + process for the app's lifetime. Views are re-parented when
/// the selection changes; they are never recreated, so the claude processes survive.
@MainActor
@Observable
final class TerminalRegistry: NSObject, LocalProcessTerminalViewDelegate {
    private(set) var running: Set<UUID> = []
    private(set) var titles: [UUID: String] = [:]
    @ObservationIgnored private var views: [UUID: DeckTerminalView] = [:]
    @ObservationIgnored var onExit: ((UUID, Int32?) -> Void)?
    /// Raw pty output of any terminal (remote mode).
    @ObservationIgnored var onOutput: ((UUID, ArraySlice<UInt8>) -> Void)?
    /// A terminal's grid changed size (remote mode).
    @ObservationIgnored var onResize: ((UUID) -> Void)?

    @ObservationIgnored private var clickMonitor: Any?

    override init() {
        super.init()
        // Clicking into a terminal focuses its session (TerminalView's responder methods aren't open).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if let hit = event.window?.contentView?.hitTest(event.locationInWindow) {
                    var view: NSView? = hit
                    while let v = view, !(v is DeckTerminalView) { view = v.superview }
                    (view as? DeckTerminalView)?.onFocus?()
                }
            }
            return event
        }
        visibilityObserver = NotificationCenter.default.addObserver(forName: AppVisibility.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
    }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// Font size for every terminal (existing and future); the pty is resized to the new grid.
    @ObservationIgnored var fontSize: CGFloat = 13 {
        didSet {
            guard fontSize != oldValue else { return }
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            for view in views.values {
                view.font = font
                view.reportGridIfChanged()
            }
        }
    }

    func view(for id: UUID) -> DeckTerminalView? { views[id] }

    /// Starts `claude` for a session. With `helper`, the process runs in the session helper
    /// (claudedeck-ptyd) and outlives the app; the argv and environment are the same either way.
    func start(id: UUID, cwd: String, claudePath: String?, args: [String], environment: [String: String] = [:],
               helper: PtydClient? = nil, helperMeta: [String: String] = [:]) {
        let view = prepareView(id: id, cwd: cwd, isClaude: true)
        if running.contains(id) { return }

        let shell = ShellEnvironment.loginShell
        // exec keeps the pid: the hook's $PPID is this very process.
        let claude = claudePath ?? "claude"
        let script = #"exec "$0" "$@""#
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        view.getTerminal().resetToInitialState()
        launchProcess(id: id, view: view, executable: shell, args: ["-l", "-c", script, claude] + args,
                      environment: ShellEnvironment.environment(terminalID: id, extra: environment),
                      execName: "-" + (shell as NSString).lastPathComponent, directory: dir, helper: helper, meta: helperMeta)
    }

    private func prepareView(id: UUID, cwd: String, isClaude: Bool) -> DeckTerminalView {
        let view = views[id] ?? DeckTerminalView(sessionID: id, fontSize: fontSize)
        view.drawingPaused = !AppVisibility.shared.windowsVisible
        view.processDelegate = self
        view.onInput = { [weak self] data in self?.onUserInput?(id, data) }
        view.onOutput = { [weak self] data in self?.onOutput?(id, data) }
        view.onFocus = { [weak self] in self?.onFocus?(id) }
        view.onMagnify = { [weak self] step in self?.onZoom?(step) }
        view.onOpenFile = { [weak self] url in self?.onOpenFile?(url) }
        view.transcriptPath = { [weak self] in self?.transcriptPath?(id) }
        view.workingDirectory = cwd
        view.isClaude = isClaude
        view.onProgramStatus = { [weak self] in self?.programStatusChanged(id) }
        views[id] = view
        return view
    }

    private func launchProcess(id: UUID, view: DeckTerminalView, executable: String, args: [String], environment: [String],
                               execName: String, directory: String, helper: PtydClient?, meta: [String: String] = [:]) {
        running.insert(id)
        guard let helper else {
            view.clearHelper()
            view.startProcess(executable: executable, args: args, environment: environment, execName: execName,
                              currentDirectory: directory)
            return
        }
        let terminal = view.getTerminal()
        let spawn = PtydSpawn(id: id.uuidString, executable: executable, argv: [execName] + args, env: environment,
                              cwd: directory, cols: terminal.cols, rows: terminal.rows, meta: meta)
        connectHelper(id, view: view, client: helper, readOnly: false)
        helper.spawn(spawn) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.helperClients[id] === helper else { return }
                switch result {
                case .success(let info):
                    self.helperPIDs[id] = info.pid
                    self.onHelperStarted?(id, info, helper.welcome.instance)
                case .failure(.refused(PtydErrorCode.exists, let info?)):
                    // Already running there (e.g. started by another copy of the app): attach,
                    // never a second process.
                    self.attachHelper(id, client: helper, readOnly: false, known: info)
                case .failure(let error):
                    // No helper after all: run it here, as with the setting off.
                    ptydLog.error("helper spawn failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                    self.helperClients[id] = nil
                    view.clearHelper()
                    view.startProcess(executable: executable, args: args, environment: environment, execName: execName,
                                      currentDirectory: directory)
                }
            }
        }
    }

    /// Routes a view's input and grid to the helper.
    private func connectHelper(_ id: UUID, view: DeckTerminalView, client: PtydClient, readOnly: Bool) {
        helperClients[id] = client
        view.helperReadOnly = readOnly
        if readOnly { readOnlySessions.insert(id) } else { readOnlySessions.remove(id) }
        view.helperInput = readOnly ? nil : { [weak client] data in client?.write(id.uuidString, Array(data)) }
        view.onGridChange = { [weak self, weak client] cols, rows in
            if !readOnly { client?.resize(id.uuidString, cols: cols, rows: rows) }
            self?.onResize?(id)
        }
    }

    /// Shows a session that runs in the helper: replays its scrollback, then streams it live.
    /// Never starts a process.
    func attachHelper(_ id: UUID, cwd: String? = nil, isClaude: Bool? = nil, client: PtydClient, readOnly: Bool,
                      known: PtydSessionInfo? = nil) {
        let view = prepareView(id: id, cwd: cwd ?? views[id]?.workingDirectory ?? NSHomeDirectory(),
                               isClaude: isClaude ?? views[id]?.isClaude ?? true)
        running.insert(id)
        connectHelper(id, view: view, client: client, readOnly: readOnly)
        if let known { helperPIDs[id] = known.pid }
        client.attach(id.uuidString) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.helperClients[id] === client else { return }
                switch result {
                case .success(let (info, replay)):
                    self.helperPIDs[id] = info.pid
                    self.onHelperStarted?(id, info, client.welcome.instance)
                    view.replay(replay, cols: info.cols, rows: info.rows) { [weak self] in
                        self?.onResize?(id) // remote viewers get the replayed screen
                    }
                case .failure:
                    // Gone in the meantime: it ended.
                    self.helperEnded(id, exitCode: nil)
                }
            }
        }
    }

    /// Live output of a helper session.
    func helperOutput(_ id: UUID, _ bytes: [UInt8]) {
        guard helperClients[id] != nil else { return }
        views[id]?.helperOutput(bytes)
    }

    /// A helper session's process ended.
    func helperExited(_ info: PtydSessionInfo, from client: PtydClient) {
        guard let id = UUID(uuidString: info.id) else { return }
        if client.isFull { client.forget(info.id) }
        guard helperClients[id] === client else { return }
        helperEnded(id, exitCode: info.exitCode)
    }

    private func helperEnded(_ id: UUID, exitCode: Int32?) {
        helperClients[id] = nil
        helperPIDs[id] = nil
        readOnlySessions.remove(id)
        views[id]?.clearHelper()
        guard running.remove(id) != nil else { return }
        onExit?(id, exitCode)
    }

    /// The helper connection dropped (it quit or crashed). Its sessions stop running here
    /// without counting as ended (`onExit` isn't called): the caller decides what comes next.
    func helperLost(_ client: PtydClient) -> [UUID] {
        var lost: [UUID] = []
        for (id, owner) in helperClients where owner === client {
            lost.append(id)
            helperClients[id] = nil
            helperPIDs[id] = nil
            readOnlySessions.remove(id)
            views[id]?.clearHelper()
            running.remove(id)
        }
        return lost
    }

    /// Whether the session's process runs in the helper.
    func isInHelper(_ id: UUID) -> Bool { helperClients[id] != nil }

    var helperSessionIDs: [UUID] { Array(helperClients.keys) }

    /// Pid of the session's process (claude itself, or the shell), local or in the helper.
    func pid(for id: UUID) -> pid_t {
        if helperClients[id] != nil { return helperPIDs[id] ?? 0 }
        return views[id]?.process.shellPid ?? 0
    }

    /// Sessions watched read-only (a helper this app can't drive).
    private(set) var readOnlySessions: Set<UUID> = []
    @ObservationIgnored private var helperClients: [UUID: PtydClient] = [:]
    @ObservationIgnored private var helperPIDs: [UUID: pid_t] = [:]
    /// A session started in (or attached to) the helper: its info and the helper's instance.
    @ObservationIgnored var onHelperStarted: ((UUID, PtydSessionInfo, String) -> Void)?

    /// A plain interactive login shell in `cwd` (no ClaudeDeck terminal id: claude started
    /// inside it is not tracked as this session). With a `command` (`claudedeck open`), the shell
    /// runs it first and writes its exit code to `exitFile`, then stays as an interactive shell.
    /// With `helper`, the shell runs in the session helper (claudedeck-ptyd) and outlives the app.
    func startShell(id: UUID, cwd: String, programStatus: Bool = false, environment: [String: String] = [:],
                    command: String? = nil, exitFile: URL? = nil, helper: PtydClient? = nil, helperMeta: [String: String] = [:]) {
        let view = prepareView(id: id, cwd: cwd, isClaude: false)
        if running.contains(id) { return }
        let shell = ShellEnvironment.loginShell
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        var env = ShellEnvironment.cleanEnvironment.merging(environment) { $1 }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ClaudeDeck"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        var args = ["-l"]
        var execName = "-" + (shell as NSString).lastPathComponent
        var integration: (shell: ShellIntegration.Shell, folder: URL)?
        // Program Status: our zsh / bash integration marks each command (OSC 133). Without it
        // (other shells, or the scripts couldn't be written) OSC 7501 still works.
        if programStatus, let folder = shellIntegrationFolder, let kind = ShellIntegration.shell(forPath: shell),
           (try? ShellIntegration.install(in: folder)) != nil {
            let launch = ShellIntegration.launch(kind, folder: folder, environment: env)
            env.merge(launch.environment) { $1 }
            args = launch.args
            execName = (launch.login ? "-" : "") + (shell as NSString).lastPathComponent
            integration = (kind, folder)
        }
        view.programMonitor = programStatus ? ProgramStatusMonitor() : nil
        view.onProgramStatus = { [weak self] in self?.programStatusChanged(id) }
        view.getTerminal().resetToInitialState()
        if let command, let exitFile {
            // An interactive login shell (the user's rc files, job control) runs the command as a
            // job of its own, so Ctrl+C stops only the command and the terminal comes back to this
            // shell, which records the code and becomes the user's shell (same pid), keeping the
            // shell integration.
            args = ShellIntegration.commandArgs(shell: shell, command: command, exitFile: exitFile.path, integration: integration)
        }
        launchProcess(id: id, view: view, executable: shell, args: args, environment: env.map { "\($0.key)=\($0.value)" },
                      execName: execName, directory: dir, helper: helper, meta: helperMeta)
        latestTitles[id] = nil
        titles[id] = nil
        setProgramStatus(nil, for: id)
    }

    // MARK: Program status

    /// Plain terminals' program status (those with it on and something to show). Written when the
    /// state changes, at once, whether or not a window is visible (notifications and the phone need
    /// it); a new message for the same state at most once a second. Never per output chunk.
    private(set) var programStatuses: [UUID: ProgramStatus] = [:]
    /// A terminal's `programStatuses` entry changed.
    @ObservationIgnored var onProgramStatus: ((UUID) -> Void)?
    /// Where the shell integration scripts are written (set by the app).
    @ObservationIgnored var shellIntegrationFolder: URL?
    @ObservationIgnored private var programMessageDelayed: Set<UUID> = []

    /// Turns a running terminal's program status on or off (shell integration needs a restart).
    func showProgramStatus(_ on: Bool, for id: UUID) {
        guard let view = views[id], !view.isClaude else { return }
        if on {
            if view.programMonitor == nil { view.programMonitor = ProgramStatusMonitor() }
        } else {
            view.programMonitor = nil
            setProgramStatus(nil, for: id)
        }
    }

    private func programStatusChanged(_ id: UUID) {
        let next = views[id]?.programMonitor?.status
        if let next, let current = programStatuses[id], next.state == current.state,
           next.exitCode == current.exitCode, next.since == current.since {
            // Only the message changed: a program reporting progress mustn't redraw the sidebar
            // and republish to phones on every line.
            guard programMessageDelayed.insert(id).inserted else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.programMessageDelayed.remove(id)
                self.setProgramStatus(self.views[id]?.programMonitor?.status, for: id)
            }
            return
        }
        setProgramStatus(next, for: id)
    }

    private func setProgramStatus(_ status: ProgramStatus?, for id: UUID) {
        guard programStatuses[id] != status else { return }
        programStatuses[id] = status
        onProgramStatus?(id)
    }

    /// Whether something other than the shell has the terminal: a command is running in it
    /// (the pty's foreground process group isn't the shell's own).
    func foregroundBusy(_ id: UUID) -> Bool {
        guard let view = views[id], running.contains(id) else { return false }
        let fd = view.process.childfd, pid = view.process.shellPid
        guard fd >= 0, pid > 0 else { return false }
        let group = tcgetpgrp(fd)
        return group > 0 && group != pid
    }

    /// Whether the shell's line editor has the terminal (zsh's and bash's turn canonical input off
    /// while at their prompt): false while a command runs, and while a shell still reads its rc files.
    func lineEditing(_ id: UUID) -> Bool {
        guard let view = views[id], running.contains(id), view.process.childfd >= 0 else { return false }
        var settings = termios()
        guard tcgetattr(view.process.childfd, &settings) == 0 else { return false }
        return settings.c_lflag & tcflag_t(ICANON) == 0
    }

    /// Starts noting when `id` last printed something (see `DeckTerminalView.timesOutput`).
    func timeOutput(of id: UUID) { views[id]?.timesOutput = true }

    func lastOutput(of id: UUID) -> Date? { views[id]?.lastOutputAt }

    /// Runs `executable` directly in the terminal (no shell): ServerPlan terminals, whose process
    /// is ClaudeDeck itself bridging the pty to the panel's WebSocket. With `programStatus` the
    /// program can report its status (OSC 7501).
    func startProcess(id: UUID, cwd: String, executable: String, args: [String], environment: [String: String], programStatus: Bool = false) {
        let view = views[id] ?? DeckTerminalView(sessionID: id, fontSize: fontSize)
        view.drawingPaused = !AppVisibility.shared.windowsVisible
        view.processDelegate = self
        view.onInput = { [weak self] data in self?.onUserInput?(id, data) }
        view.onOutput = { [weak self] data in self?.onOutput?(id, data) }
        view.onFocus = { [weak self] in self?.onFocus?(id) }
        view.onMagnify = { [weak self] step in self?.onZoom?(step) }
        view.onOpenFile = { [weak self] url in self?.onOpenFile?(url) }
        view.transcriptPath = { [weak self] in self?.transcriptPath?(id) }
        view.workingDirectory = cwd
        view.isClaude = false
        views[id] = view
        if running.contains(id) { return }
        var env = ShellEnvironment.cleanEnvironment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ClaudeDeck"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.merge(environment) { _, new in new }
        view.programMonitor = programStatus ? ProgramStatusMonitor() : nil
        view.onProgramStatus = { [weak self] in self?.programStatusChanged(id) }
        view.getTerminal().resetToInitialState()
        view.startProcess(
            executable: executable,
            args: args,
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        )
        running.insert(id)
        latestTitles[id] = nil
        titles[id] = nil
        setProgramStatus(nil, for: id)
    }

    /// The grid a terminal has (or will have: the default for a new one).
    func gridSize(_ id: UUID) -> (cols: Int, rows: Int) {
        guard let terminal = views[id]?.getTerminal(), terminal.cols > 0, terminal.rows > 0 else { return (120, 40) }
        return (terminal.cols, terminal.rows)
    }

    /// Types `text`; a trailing `\r` is sent separately so it lands as Enter. Text containing
    /// newlines goes in as a bracketed paste, since a raw newline in the pty would submit early.
    func type(_ text: String, into id: UUID) {
        guard let view = views[id], running.contains(id) else { return }
        // Return on its own is a key press, not a line to paste.
        guard text != "\r" else { view.send(txt: text); return }
        let submit = text.hasSuffix("\r") && text.count > 1
        var body = submit ? String(text.dropLast()) : text
        let multiline = body.contains(where: \.isNewline)
        if multiline { body = "\u{1B}[200~" + body + "\u{1B}[201~" }
        guard submit else { view.send(txt: body); return }
        view.send(txt: body)
        let probe = Self.probe(String(text.dropLast()))
        Task { @MainActor [weak self] in
            // Longer text takes Claude Code longer to take in; a Return inside that burst counts
            // as part of a paste and the message just sits in the prompt.
            try? await Task.sleep(for: .milliseconds(multiline ? 500 : 150 + min(450, body.count / 3)))
            guard let self, self.running.contains(id) else { return }
            self.views[id]?.send(txt: "\r")
            // Still in the prompt box (Claude was busy drawing)? Return again, up to twice.
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(900))
                guard self.running.contains(id), let view = self.views[id], Self.promptHolds(probe, in: view) else { return }
                view.send(txt: "\r")
            }
        }
    }

    /// The start of a message, spaces squeezed, to look for on screen.
    private static func probe(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(24))
    }

    /// Whether Claude Code's prompt box (between the last two ─── rules at the bottom) still
    /// shows `probe`: the Return didn't submit. A permission prompt or a question has no such box.
    private static func promptHolds(_ probe: String, in view: TerminalView) -> Bool {
        guard probe.count >= 3 else { return false }
        let lines = TerminalCapture.screen(of: view, scrollback: 0).lines.suffix(16).map { $0.map(\.text).joined() }
        let rules = lines.indices.filter { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return line.count >= 20 && line.allSatisfy { $0 == "─" }
        }
        guard rules.count >= 2, let bottom = rules.last else { return false }
        let top = rules[rules.count - 2]
        guard bottom - top > 1 else { return false }
        let box = lines[(top + 1)..<bottom].joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return box.contains(probe)
    }

    /// Pastes text as the terminal would (bracketed): Claude Code turns a pasted image path into
    /// an attached image.
    func paste(_ text: String, into id: UUID) {
        guard let view = views[id], running.contains(id) else { return }
        view.send(txt: "\u{1B}[200~" + text + "\u{1B}[201~")
    }

    /// Ends the claude process. SwiftTerm's `terminate()` cancels its own exit monitor, so the
    /// exit is reported here and the child is reaped in the background (SIGKILL after 5 s).
    func terminate(_ id: UUID) {
        guard let view = views[id], running.contains(id) else { return }
        // Watched read-only in a helper this app can't drive: it can't be ended from here
        // (Restart Helper does it).
        if readOnlySessions.contains(id) {
            NSSound.beep()
            return
        }
        if let client = helperClients[id] {
            // Like closing the pty (SIGHUP) plus SIGTERM, SIGKILL after 5 s — done by the helper.
            // Its exit notice is then only forgotten: the exit is reported here and now.
            client.signal(id.uuidString, SIGHUP)
            client.signal(id.uuidString, SIGTERM, killAfter: 5)
            helperClients[id] = nil
            readOnlySessions.remove(id)
            view.clearHelper()
            running.remove(id)
            onExit?(id, nil)
            return
        }
        let pid = view.process.shellPid
        view.terminate()
        running.remove(id)
        setProgramStatus(nil, for: id)
        onExit?(id, nil)
        if pid > 0 { Self.reap(pid) }
    }

    nonisolated static func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<50 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// Remaining input hook: called with every chunk the user types into a terminal.
    @ObservationIgnored var onUserInput: ((UUID, ArraySlice<UInt8>) -> Void)?
    @ObservationIgnored var onFocus: ((UUID) -> Void)?
    @ObservationIgnored var onZoom: ((CGFloat) -> Void)?
    /// ⌘⌥-click on a file path in a terminal.
    @ObservationIgnored var onOpenFile: ((URL) -> Void)?
    /// A session's Claude transcript file, if known.
    @ObservationIgnored var transcriptPath: ((UUID) -> String?)?

    func discard(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
        running.remove(id)
        latestTitles[id] = nil
        titles[id] = nil
        programStatuses[id] = nil
    }

    /// On quit: signal every process without reporting exits (quit keeps `isOpen` for auto-resume).
    /// Sessions in the session helper keep running (the app only disconnects from it).
    func terminateAll() {
        for id in running where helperClients[id] == nil {
            guard let view = views[id] else { continue }
            let pid = view.process.shellPid
            view.terminate()
            if pid > 0 { kill(pid, SIGHUP) }
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard let id = (source as? DeckTerminalView)?.sessionID else { return }
            onResize?(id)
        }
    }

    /// Claude Code's TUI rewrites its title with a spinner several times a second; every view that
    /// shows a status reads `titles` (a plain terminal's detail line), so writing it on each
    /// sequence re-rendered the sidebar and the menu bar label all the time. Only plain
    /// terminals' titles are shown: only they are published, when they change, and while a
    /// window is visible (the latest is applied when one is again).
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            guard let view = source as? DeckTerminalView, !view.isClaude else { return }
            latestTitles[view.sessionID] = title
            publishTitles()
        }
    }

    @ObservationIgnored private var latestTitles: [UUID: String] = [:]
    @ObservationIgnored private var visibilityObserver: Any?

    private func visibilityChanged() {
        let paused = !AppVisibility.shared.windowsVisible
        for view in views.values { view.drawingPaused = paused }
        publishTitles()
    }

    private func publishTitles() {
        guard AppVisibility.shared.windowsVisible, titles != latestTitles else { return }
        titles = latestTitles
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            guard let view = source as? DeckTerminalView else { return }
            let id = view.sessionID
            // A stopped terminal shows nothing (the next start begins afresh); publishing what the
            // tracker falls back to would announce an old result as new.
            view.programMonitor?.processExited(now: Date())
            setProgramStatus(nil, for: id)
            running.remove(id)
            onExit?(id, exitCode)
        }
    }
}
