import SwiftTerm
import SwiftUI
import UIKit

/// A terminal that keeps the Mac's grid whatever its frame (the Mac owns the size).
final class FixedGridTerminalView: TerminalView {
    var gridCols = 80
    var gridRows = 24

    override func layoutSubviews() {
        super.layoutSubviews()
        enforceGrid()
    }

    /// Ctrl+Return (the keyboard bar's Ctrl, then Return): SwiftTerm has no control character for
    /// Return and sent nothing. Sends Ctrl+J instead, which Claude Code takes as a new line.
    override func insertText(_ text: String) {
        let accessory = inputAccessoryView as? TerminalAccessory
        if text == "\n", accessory?.controlModifier == true || controlModifier {
            accessory?.controlModifier = false
            controlModifier = false
            send(data: [0x0a][...])
            return
        }
        super.insertText(text)
    }

    /// A hardware keyboard's Ctrl+Return or Shift+Return: a new line too (plain Return still sends).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key, key.keyCode == .keyboardReturnOrEnter,
           !key.modifierFlags.intersection([.control, .shift]).isEmpty, !key.modifierFlags.contains(.command) {
            send(data: [0x0a][...])
            return
        }
        super.pressesBegan(presses, with: event)
    }

    /// An app that turns the mouse on (Claude Code's full-screen mode) gets no drags: a vertical pan is its wheel
    /// (see `RemoteTerminalUIView.wheeled`), taps still click.
    override func mouseModeChanged(source: Terminal) {}

    /// SwiftTerm drops the selection at every new line while mouse reporting is allowed, and a busy
    /// program (Claude Code redraws all the time) cleared it before Copy could be chosen. A tap or
    /// Copy clears it instead (see `RemoteTerminalUIView`).
    override func linefeed(source: Terminal) {}

    /// ⌘C on a hardware keyboard copies the selection (keys otherwise go to the program).
    override var keyCommands: [UIKeyCommand]? {
        let copy = UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copySelection))
        copy.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [copy]
    }

    @objc func copySelection() {
        guard selection.active else { return }
        // SwiftTerm's own: it also drops the drag it may have added for a double-tapped selection.
        copy(nil)
        setNeedsDisplay()
    }

    @discardableResult
    func enforceGrid() -> Bool {
        let terminal = getTerminal()
        guard terminal.cols != gridCols || terminal.rows != gridRows else { return false }
        terminal.resize(cols: gridCols, rows: gridRows)
        setNeedsDisplay()
        return true
    }
}

/// Lets the wheel pan start only while the app has the mouse on, and only for a mostly vertical pan.
private final class WheelGate: NSObject, UIGestureRecognizerDelegate {
    weak var terminal: TerminalView?

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let terminal, let pan = gesture as? UIPanGestureRecognizer, terminal.getTerminal().mouseMode != .off
        else { return false }
        let velocity = pan.velocity(in: terminal)
        return abs(velocity.y) > abs(velocity.x)
    }
}

/// Lets a selection drag start only at one end of the selection (its "handle"); the tap that
/// clears a selection doesn't hold back the terminal's own taps (the program's clicks).
private final class SelectionGate: NSObject, UIGestureRecognizerDelegate {
    weak var view: RemoteTerminalUIView?

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        if gesture.name == RemoteTerminalUIView.handleDragName {
            return view.selectionEnd(near: gesture.location(in: view.terminal)) != nil
        }
        return true
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture.name == RemoteTerminalUIView.clearTapName
    }
}

/// The Mac's terminal at its exact grid, inside a scroll view that pans both ways. The font
/// starts at "fit the width" (at least 6 pt); pinching changes the font size.
final class RemoteTerminalUIView: UIView, @preconcurrency TerminalViewDelegate, RemoteTerminalSink {
    let scroll = UIScrollView()
    let terminal = FixedGridTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    var onInput: ((Data) -> Void)?
    var onNeedsRedraw: (() -> Void)?
    /// Fit mode: the grid this screen holds at the reading font; the Mac sizes its terminal to it.
    var onFitGrid: ((Int, Int) -> Void)?
    var fitToScreen = true {
        didSet {
            guard fitToScreen != oldValue else { return }
            fittedWidth = -1
            lastFitGrid = nil
            setNeedsLayout()
            if !fitToScreen { onFitGrid?(0, 0) }
        }
    }
    private var lastFitGrid: (Int, Int)?
    static let defaultFont = CGFloat(TerminalFont.standard)
    static let fontRange = CGFloat(TerminalFont.range.lowerBound)...CGFloat(TerminalFont.range.upperBound)
    /// Fit mode's font (Settings, the text size menu, a pinch): the grid asked of the Mac follows it.
    var readingFont: CGFloat = RemoteTerminalUIView.defaultFont {
        didSet {
            guard readingFont != oldValue else { return }
            fittedWidth = -1
            lastFitGrid = nil
            setNeedsLayout()
        }
    }
    /// A pinch in fit mode: the new reading font, to keep.
    var onReadingFont: ((CGFloat) -> Void)?
    /// nil = fit the width.
    private var chosenFontSize: CGFloat?
    private var fontSize: CGFloat = 0
    private var fittedWidth: CGFloat = -1
    private var pinchStart: CGFloat = 0
    private var scrolledToBottom = false
    /// A wheel pan's movement not yet sent as a wheel step.
    private var wheelRemainder: CGFloat = 0
    private let wheelGate = WheelGate()
    private let selectionGate = SelectionGate()
    static let handleDragName = "selectionHandle"
    static let clearTapName = "clearSelection"
    /// Where a long press started its selection.
    private var selectionAnchor: Position?
    /// A link (OSC 8, or a URL in the text) under the long press.
    private var pressedLink: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scroll.backgroundColor = .black
        // Vertical pans go to the terminal (its scrollback); this view pans a grid wider or taller than the screen.
        scroll.alwaysBounceVertical = false
        scroll.showsHorizontalScrollIndicator = true
        scroll.keyboardDismissMode = .interactive
        addSubview(scroll)
        terminal.terminalDelegate = self
        // The Mac sends its scrollback with the screen: swiping down reads back through it.
        terminal.isScrollEnabled = true
        terminal.alwaysBounceVertical = true
        terminal.nativeBackgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.1, alpha: 1)
        terminal.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        scroll.addSubview(terminal)
        scroll.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        // An app with the mouse on keeps no scrollback (Claude Code's full-screen mode scrolls itself): a finger,
        // trackpad or mouse wheel pan up or down is sent to it as its wheel.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        wheel.allowedScrollTypesMask = .all
        wheelGate.terminal = terminal
        wheel.delegate = wheelGate
        // A pointer click-drag selects (below); the trackpad's two-finger scroll is still the wheel.
        wheel.allowedTouchTypes = Self.fingerTouches
        terminal.addGestureRecognizer(wheel)
        setUpSelection()
        setFont(10)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        if bounds.width != fittedWidth { fit() }
        if fitToScreen { requestFitGrid() }
    }

    /// Columns x rows of this screen at the reading font.
    private func requestFitGrid() {
        guard bounds.width > 50, bounds.height > 50 else { return }
        let font = UIFont.monospacedSystemFont(ofSize: readingFont, weight: .regular)
        let cell = ("W" as NSString).size(withAttributes: [.font: font])
        let cols = Int((bounds.width - 4) / ceil(cell.width))
        let rows = Int(bounds.height / ceil(font.lineHeight + 1))
        guard lastFitGrid.map({ $0 != (cols, rows) }) ?? true else { return }
        lastFitGrid = (cols, rows)
        onFitGrid?(cols, rows)
    }

    // MARK: RemoteTerminalSink

    func start(cols: Int, rows: Int, screen: Data) {
        let changed = cols != terminal.gridCols || rows != terminal.gridRows
        terminal.gridCols = max(cols, 2)
        terminal.gridRows = max(rows, 2)
        terminal.enforceGrid()
        if changed { fit() }
        terminal.feed(byteArray: ArraySlice(screen))
        if !scrolledToBottom { scrollToCursor() }
    }

    func feed(_ bytes: Data) {
        terminal.feed(byteArray: ArraySlice(bytes))
    }

    // MARK: Layout

    private func setFont(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        terminal.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func fit() {
        guard bounds.width > 0 else { return }
        fittedWidth = bounds.width
        let before = fontSize
        if let chosenFontSize {
            setFont(chosenFontSize)
        } else if fitToScreen {
            // The Mac's terminal is (or is about to be) this screen's width.
            setFont(readingFont)
        } else {
            // Measure at 10 pt, scale to the width, step down until it fits.
            setFont(10)
            terminal.enforceGrid()
            let width = terminal.getOptimalFrameSize().width
            // Not below 7.5 pt (readable); a wider terminal pans sideways instead.
            var size = max(7.5, (10 * bounds.width / max(width, 1) * 2).rounded(.down) / 2)
            setFont(size)
            terminal.enforceGrid()
            while terminal.getOptimalFrameSize().width > bounds.width, size > 7.5 {
                size -= 0.5
                setFont(size)
                terminal.enforceGrid()
            }
        }
        place()
        if fontSize != before { onNeedsRedraw?() }
    }

    private func place() {
        terminal.enforceGrid()
        let size = terminal.getOptimalFrameSize().size
        let x = max(0, (bounds.width - size.width) / 2)
        terminal.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
        scroll.contentSize = CGSize(width: max(size.width, bounds.width), height: size.height)
        terminal.enforceGrid()
    }

    /// Shows the cursor's row (the prompt) after the first screen.
    private func scrollToCursor() {
        scrolledToBottom = true
        let rowHeight = terminal.getOptimalFrameSize().height / CGFloat(terminal.gridRows)
        let cursorY = CGFloat(terminal.getTerminal().getCursorLocation().y + 1) * rowHeight
        let target = min(max(0, cursorY - scroll.bounds.height * 0.7), max(0, scroll.contentSize.height - scroll.bounds.height))
        scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStart = fontSize
        case .changed, .ended:
            let size = min(Self.fontRange.upperBound, max(Self.fontRange.lowerBound, (pinchStart * gesture.scale * 2).rounded() / 2))
            guard size != fontSize else { return }
            if fitToScreen {
                readingFont = size
                onReadingFont?(size)
            } else {
                chosenFontSize = size
                fit()
            }
        default:
            break
        }
    }

    @objc private func wheeled(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            wheelRemainder = 0
        case .changed:
            let rowHeight = max(1, terminal.getOptimalFrameSize().height / CGFloat(max(terminal.gridRows, 1)))
            wheelRemainder += gesture.translation(in: terminal).y
            gesture.setTranslation(.zero, in: terminal)
            let steps = Int(wheelRemainder / rowHeight)
            guard steps != 0 else { return }
            wheelRemainder -= CGFloat(steps) * rowHeight
            let point = gesture.location(in: terminal)
            let col = min(max(0, Int(point.x / max(1, terminal.getOptimalFrameSize().width / CGFloat(terminal.gridCols)))), terminal.gridCols - 1)
            let row = min(max(0, Int(point.y / rowHeight)), terminal.gridRows - 1)
            // Down (the finger pulling the text down) reads back: wheel up (64); up is wheel down (65).
            for _ in 0..<abs(steps) {
                terminal.getTerminal().sendEvent(buttonFlags: steps > 0 ? 64 : 65, x: col, y: row)
            }
        default:
            break
        }
    }

    // MARK: Selection

    static let fingerTouches = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]

    /// Selecting works the same whether or not the program has the mouse on (Claude Code's full-screen
    /// mode does): a long press selects the word (or URL) under the finger and opens the menu (Copy,
    /// Open Link, Copy Screen…); dragging on from the press, or later from either end of the selection,
    /// changes it; a pointer (trackpad, mouse) click-drag selects. A plain tap stays the program's click.
    /// SwiftTerm's own long press is off: it only offered "Select" in a menu, brought the keyboard up,
    /// and with the mouse on its selection drag never started.
    private func setUpSelection() {
        terminal.gestureRecognizers?.filter { $0 is UILongPressGestureRecognizer }.forEach { $0.isEnabled = false }
        selectionGate.view = self

        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.45
        terminal.addGestureRecognizer(press)

        let handle = UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:)))
        handle.name = Self.handleDragName
        handle.delegate = selectionGate
        terminal.addGestureRecognizer(handle)

        let pointer = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged(_:)))
        pointer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        terminal.addGestureRecognizer(pointer)

        let clear = UITapGestureRecognizer(target: self, action: #selector(tappedToClear(_:)))
        clear.name = Self.clearTapName
        clear.delegate = selectionGate
        terminal.addGestureRecognizer(clear)

        // A drag at a selection end moves it instead of scrolling; a pointer click-drag selects.
        terminal.gestureRecognizers?.filter { $0.delegate is WheelGate }.forEach { $0.require(toFail: handle) }
        for scrollPan in [terminal.panGestureRecognizer, scroll.panGestureRecognizer] {
            scrollPan.require(toFail: handle)
            scrollPan.allowedTouchTypes = Self.fingerTouches
        }
        terminal.addInteraction(UIEditMenuInteraction(delegate: self))
    }

    private var cellSize: CGSize {
        let size = terminal.getOptimalFrameSize().size
        return CGSize(width: max(1, size.width / CGFloat(max(terminal.gridCols, 1))),
                      height: max(1, size.height / CGFloat(max(terminal.gridRows, 1))))
    }

    /// The buffer cell (scrollback included) at a point in the terminal's content.
    private func cell(at point: CGPoint) -> Position {
        let cell = cellSize
        let lines = Int((max(terminal.contentSize.height, terminal.bounds.height) / cell.height).rounded())
        return Position(col: min(max(0, Int(point.x / cell.width)), terminal.gridCols - 1),
                        row: min(max(0, Int(point.y / cell.height)), max(0, lines - 1)))
    }

    /// The selection's start or end when the point is on (or right next to) it.
    func selectionEnd(near point: CGPoint) -> Position? {
        guard let selection = terminal.selection, selection.active else { return nil }
        let hit = cell(at: point)
        func near(_ position: Position) -> Bool { abs(position.col - hit.col) < 3 && abs(position.row - hit.row) < 2 }
        if near(selection.end) { return selection.end }
        if near(selection.start) { return selection.start }
        return nil
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard let selection = terminal.selection else { return }
        let point = gesture.location(in: terminal)
        switch gesture.state {
        case .began:
            let hit = cell(at: point)
            selection.selectWordOrExpression(at: hit, in: terminal.getTerminal().buffer)
            selection.selectionMode = .character
            if !selection.active { selection.setSelection(start: hit, end: Position(col: hit.col + 1, row: hit.row)) }
            selectionAnchor = selection.start
            pressedLink = link(at: point)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            terminal.setNeedsDisplay()
        case .changed:
            // Dragging on from the press: from where it started to the finger.
            guard let anchor = selectionAnchor else { return }
            selection.pivot = anchor
            selection.pivotExtend(bufferPosition: cell(at: point))
            terminal.setNeedsDisplay()
        case .ended:
            selectionAnchor = nil
            showMenu(at: point)
        default:
            selectionAnchor = nil
        }
    }

    @objc private func handleDragged(_ gesture: UIPanGestureRecognizer) {
        guard let selection = terminal.selection else { return }
        let point = gesture.location(in: terminal)
        switch gesture.state {
        case .began:
            // The other end stays.
            guard let end = selectionEnd(near: point) else { return }
            selection.pivot = end == selection.end ? selection.start : selection.end
            pressedLink = nil
        case .changed:
            selection.pivotExtend(bufferPosition: cell(at: point))
            terminal.setNeedsDisplay()
        case .ended:
            showMenu(at: point)
        default:
            break
        }
    }

    @objc private func pointerDragged(_ gesture: UIPanGestureRecognizer) {
        guard let selection = terminal.selection else { return }
        let point = gesture.location(in: terminal)
        switch gesture.state {
        case .began:
            let start = cell(at: gesture.location(in: terminal))
            selection.setSelection(start: start, end: start)
            selection.selectionMode = .character
            selection.pivot = start
            pressedLink = nil
        case .changed:
            selection.pivotExtend(bufferPosition: cell(at: point))
            terminal.setNeedsDisplay()
        case .ended:
            if selection.active { showMenu(at: point) }
        default:
            break
        }
    }

    @objc private func tappedToClear(_ gesture: UITapGestureRecognizer) {
        guard let selection = terminal.selection, selection.active else { return }
        selection.selectNone()
        terminal.setNeedsDisplay()
    }

    private func link(at point: CGPoint) -> URL? {
        guard let text = terminal.getTerminal().link(at: .buffer(cell(at: point)), mode: .explicitAndImplicit),
              let url = URL(string: text), url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    func showMenu(at point: CGPoint) {
        guard let interaction = terminal.interactions.lazy.compactMap({ $0 as? UIEditMenuInteraction }).first else { return }
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    /// The terminal's text: the screen (`lines` nil) or its last lines (scrollback included),
    /// without trailing blanks.
    func text(lastLines lines: Int?) -> String {
        let data = terminal.getTerminal().getBufferAsData(kind: .active)
        var rows = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            .map { String($0.reversed().drop(while: { $0 == " " }).reversed()) }
        rows = Array(rows.suffix(lines ?? terminal.gridRows))
        while rows.last?.isEmpty == true { rows.removeLast() }
        while rows.first?.isEmpty == true { rows.removeFirst() }
        return rows.joined(separator: "\n")
    }

    func toggleKeyboard() {
        if terminal.isFirstResponder { _ = terminal.resignFirstResponder() } else { _ = terminal.becomeFirstResponder() }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.scheme == "http" || url.scheme == "https" { UIApplication.shared.open(url) }
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

extension RemoteTerminalUIView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIMenuElement] = []
        if terminal.selection?.active == true {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.terminal.copySelection()
            })
        }
        if let url = pressedLink {
            actions.append(UIAction(title: String(localized: "Open Link"), image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            })
            actions.append(UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = url
            })
        }
        actions.append(UIAction(title: String(localized: "Copy Screen"), image: UIImage(systemName: "rectangle.on.rectangle")) { [weak self] _ in
            guard let self else { return }
            UIPasteboard.general.string = self.text(lastLines: nil)
        })
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.terminal.paste(nil)
            })
        }
        return UIMenu(children: actions)
    }
}

struct RemoteTerminalRepresentable: UIViewRepresentable {
    let sessionID: UUID
    let store: RemoteStore
    let keyboardToggle: Int
    var copyRequest = TerminalCopyRequest()
    let fitToScreen: Bool
    @Binding var fontSize: Double

    final class Coordinator {
        let sessionID: UUID
        weak var store: RemoteStore?
        var lastToggle = 0
        var lastCopy = 0
        init(sessionID: UUID, store: RemoteStore) {
            self.sessionID = sessionID
            self.store = store
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(sessionID: sessionID, store: store) }

    func makeUIView(context: Context) -> RemoteTerminalUIView {
        let view = RemoteTerminalUIView(frame: .zero)
        let id = sessionID
        view.onInput = { [weak store] data in store?.sendTerminalInput(id, data: data) }
        view.onNeedsRedraw = { [weak store] in store?.redrawTerminal(id) }
        view.onFitGrid = { [weak store] cols, rows in store?.fitTerminal(id, cols: cols, rows: rows) }
        view.fitToScreen = fitToScreen
        view.readingFont = fontSize
        let size = $fontSize
        view.onReadingFont = { size.wrappedValue = $0 }
        store.attachTerminal(id, sink: view)
        context.coordinator.lastToggle = keyboardToggle
        context.coordinator.lastCopy = copyRequest.serial
        return view
    }

    func updateUIView(_ view: RemoteTerminalUIView, context: Context) {
        view.fitToScreen = fitToScreen
        view.readingFont = fontSize
        if keyboardToggle != context.coordinator.lastToggle {
            context.coordinator.lastToggle = keyboardToggle
            view.toggleKeyboard()
        }
        if copyRequest.serial != context.coordinator.lastCopy {
            context.coordinator.lastCopy = copyRequest.serial
            UIPasteboard.general.string = view.text(lastLines: copyRequest.lines)
        }
    }

    static func dismantleUIView(_ view: RemoteTerminalUIView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            view.onInput = nil
            view.onNeedsRedraw = nil
            view.onFitGrid = nil
            view.onReadingFont = nil
            coordinator.store?.fitTerminal(coordinator.sessionID, cols: 0, rows: 0)
            coordinator.store?.detachTerminal(coordinator.sessionID, sink: view)
        }
    }
}

/// One session: status, Allow / Deny, and its live terminal.
struct SessionDetailView: View {
    @Environment(RemoteStore.self) private var store
    let sessionID: UUID
    @State private var keyboardToggle = 0
    @State private var copyRequest = TerminalCopyRequest()
    /// Per window: two windows can show a conversation and a terminal side by side.
    @SceneStorage("detail.mode") private var mode = Mode.conversation
    @AppStorage("terminal.fit") private var fitToScreen = true
    @AppStorage(TerminalFont.key) private var terminalFont = TerminalFont.standard
    @State private var filesProject: RemoteProject?

    /// Claude's edits shown in the conversation, at its tool calls (the toolbar's ± switches it).
    @AppStorage(ConversationView.inlineEditsKey) private var inlineEdits = true

    enum Mode: String { case conversation, edits, terminal }

    var body: some View {
        let session = store.snapshot?.session(sessionID)
        VStack(spacing: 0) {
            if let session {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        StatusPill(state: session.state, program: store.program(of: session))
                        if let detail = store.detail(of: session) {
                            Text(MarkdownBlocks.shortToolNames(detail)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    PermissionButtons(session: session)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
            // A plain terminal has no conversation.
            let isShell = session?.state == .shell
            if !isShell {
                Picker("View", selection: $mode) {
                    Text("Conversation").tag(Mode.conversation)
                    Text("Edits").tag(Mode.edits)
                    Text("Terminal").tag(Mode.terminal)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            if mode == .conversation, !isShell {
                ConversationView(sessionID: sessionID)
            } else if mode == .edits, !isShell {
                EditsView(sessionID: sessionID)
            } else {
                terminal
            }
        }
        .navigationTitle(session?.name ?? String(localized: "Session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode == .terminal || session?.state == .shell {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { fitToScreen.toggle() } label: {
                        Image(systemName: fitToScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { terminalFont = TerminalFont.step(terminalFont, by: 1) } label: { Label("Larger Text", systemImage: "plus.magnifyingglass") }
                        Button { terminalFont = TerminalFont.step(terminalFont, by: -1) } label: { Label("Smaller Text", systemImage: "minus.magnifyingglass") }
                        Button { terminalFont = TerminalFont.standard } label: { Label("Default Size", systemImage: "arrow.counterclockwise") }
                    } label: { Image(systemName: "textformat.size") }
                        .accessibilityLabel(Text("Text Size"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // A fallback to the long press: the screen's or the latest lines' text at once.
                    Menu {
                        Button { copyRequest = TerminalCopyRequest(serial: copyRequest.serial + 1, lines: nil) } label: {
                            Label("Copy Screen", systemImage: "rectangle.on.rectangle")
                        }
                        Button { copyRequest = TerminalCopyRequest(serial: copyRequest.serial + 1, lines: 200) } label: {
                            Label("Copy Last 200 Lines", systemImage: "text.append")
                        }
                    } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel(Text("Copy"))
                        .disabled(store.terminalStates[sessionID] == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { keyboardToggle += 1 } label: { Image(systemName: "keyboard") }
                        .accessibilityLabel(Text("Keyboard"))
                        .disabled(store.terminalStates[sessionID] != .live)
                }
            } else {
                if mode == .conversation, store.supportsEdits {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { inlineEdits.toggle() } label: {
                            Image(systemName: inlineEdits ? "plusminus.circle.fill" : "plusminus.circle")
                        }
                        .accessibilityLabel(Text("Edits in the Conversation"))
                        .accessibilityValue(Text(inlineEdits ? "On" : "Off"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { ConversationTextSizeMenu() }
            }
            // The session's project files: save one here, add one to this session, upload.
            if let project = store.projects.first(where: { $0.name == session?.project }) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { filesProject = project } label: { Image(systemName: "folder") }
                        .accessibilityLabel(Text("Files"))
                }
            }
        }
        .sheet(item: $filesProject) { project in
            NavigationStack {
                DirectoryView(projectID: project.id, path: "", title: project.name)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { filesProject = nil } } }
            }
        }
    }

    private var terminal: some View {
            RemoteTerminalRepresentable(sessionID: sessionID, store: store, keyboardToggle: keyboardToggle, copyRequest: copyRequest, fitToScreen: fitToScreen, fontSize: $terminalFont)
                .overlay {
                    if let message = overlayMessage {
                        VStack(spacing: 8) {
                            if store.terminalStates[sessionID] != .ended { ProgressView() }
                            Text(message).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
    }

    private var overlayMessage: String? {
        guard store.connection == .connected else { return String(localized: "Waiting for the other Mac…") }
        switch store.terminalStates[sessionID] {
        case .live: return nil
        case .ended: return String(localized: "This session isn't running on the other Mac.")
        default: return String(localized: "Loading the terminal…")
        }
    }
}

/// A toolbar copy of the terminal's text: `lines` nil is the screen.
struct TerminalCopyRequest: Equatable {
    var serial = 0
    var lines: Int?
}

/// The terminal's font size (fit mode: the Mac's terminal is sized to the screen at it).
enum TerminalFont {
    static let key = "terminal.fontSize"
    static let standard: Double = 11
    static let range: ClosedRange<Double> = 5...24
    static func step(_ size: Double, by delta: Double) -> Double { min(max(size + delta, range.lowerBound), range.upperBound) }
}
