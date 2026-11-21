import ScreenSharingKit
import SwiftUI
import UIKit

/// Which keyboard types into a terminal (and the conversation's live keys): the system one, or the
/// screen-sharing Mac keyboard (ClaudeDeck's, with Ctrl/Option/Command/Esc/Tab/arrows/F-keys).
/// Kept per device.
enum TerminalKeyboardChoice: String, CaseIterable {
    case system, claudeDeck
    static let key = "terminal.keyboard"

    var title: LocalizedStringKey {
        switch self {
        case .system: "System Keyboard"
        case .claudeDeck: "ClaudeDeck Keyboard"
        }
    }

    var toggled: Self { self == .system ? .claudeDeck : .system }
}

/// A quick key: control bytes as they are, or a special key (its sequence follows the cursor mode).
enum QuickKey: Hashable {
    case bytes([UInt8])
    case keysym(UInt32)

    func bytes(applicationCursor: Bool) -> [UInt8] {
        switch self {
        case .bytes(let bytes): bytes
        case .keysym(let keysym): TerminalKeys.bytes(keysym: keysym, applicationCursor: applicationCursor) ?? []
        }
    }
}

/// The sticky Ctrl and Option of the quick-key bar: the next typed character gets them.
@Observable final class QuickKeyState {
    var control = false
    var option = false
    var modifiers: TerminalKeys.Modifiers {
        var result: TerminalKeys.Modifiers = []
        if control { result.insert(.control) }
        if option { result.insert(.option) }
        return result
    }
    func clear() { control = false; option = false }
}

extension HostKeyEvent {
    /// The bytes the ClaudeDeck keyboard's key sends to a terminal.
    func terminalBytes(applicationCursor: Bool, extra: TerminalKeys.Modifiers = []) -> [UInt8] {
        var modifiers = extra
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if command { modifiers.insert(.command) }
        switch kind {
        case .text(let text): return TerminalKeys.bytes(text: text, modifiers: modifiers)
        case .keysym(let keysym):
            return TerminalKeys.bytes(keysym: keysym, modifiers: modifiers.subtracting(.command), applicationCursor: applicationCursor) ?? []
        }
    }
}

/// Esc, ⌃C, ⌃D, ⌃Z, ⌃L, Tab, sticky Ctrl/Option, arrows (and F-keys for a terminal), scrolling
/// sideways when the screen is narrow; a trailing button switches the keyboard.
struct QuickKeysBar: View {
    let state: QuickKeyState
    var showsFunctionKeys = true
    let send: (QuickKey) -> Void
    var choice: TerminalKeyboardChoice?
    var onToggleChoice: (() -> Void)?
    var onHide: (() -> Void)?

    private typealias K = TerminalKeys.Keysym

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc", .bytes(TerminalKeys.escape), label: "Escape")
                    key("⌃C", .bytes(TerminalKeys.interrupt), label: "Control C")
                    key("⌃D", .bytes(TerminalKeys.endOfFile), label: "Control D")
                    key("⌃Z", .bytes(TerminalKeys.suspend), label: "Control Z")
                    key("⌃L", .bytes(TerminalKeys.clearScreen), label: "Control L")
                    key("tab", .bytes(TerminalKeys.tab), label: "Tab")
                    sticky("ctrl", on: state.control) { state.control.toggle() }
                    sticky("alt", on: state.option) { state.option.toggle() }
                    icon("arrow.left", .keysym(K.left), label: "Left")
                    icon("arrow.up", .keysym(K.up), label: "Up")
                    icon("arrow.down", .keysym(K.down), label: "Down")
                    icon("arrow.right", .keysym(K.right), label: "Right")
                    if showsFunctionKeys {
                        key("home", .keysym(K.home), label: "Home")
                        key("end", .keysym(K.end), label: "End")
                        key("pgup", .keysym(K.pageUp), label: "Page Up")
                        key("pgdn", .keysym(K.pageDown), label: "Page Down")
                        ForEach(1...10, id: \.self) { number in
                            key("F\(number)", .keysym(K.function(number)), label: "F\(number)")
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            if let choice, let onToggleChoice {
                Divider().frame(height: 22)
                Button(action: onToggleChoice) {
                    Image(systemName: choice == .system ? "keyboard.badge.ellipsis" : "keyboard")
                        .frame(width: 40, height: 32)
                }
                .accessibilityLabel(Text(choice.toggled.title))
            }
            if let onHide {
                Button(action: onHide) {
                    Image(systemName: "keyboard.chevron.compact.down").frame(width: 40, height: 32)
                }
                .accessibilityLabel(Text("Hide Keyboard"))
            }
        }
        .font(.system(size: 14, weight: .medium, design: .monospaced))
        .buttonStyle(.plain)
        .frame(height: 40)
    }

    private func key(_ title: String, _ key: QuickKey, label: String) -> some View {
        Button { send(key) } label: { cap(Text(verbatim: title), on: false) }
            .accessibilityLabel(Text(verbatim: label))
    }

    private func icon(_ name: String, _ key: QuickKey, label: String) -> some View {
        Button { send(key) } label: { cap(Image(systemName: name), on: false) }
            .accessibilityLabel(Text(verbatim: label))
    }

    private func sticky(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { cap(Text(verbatim: title), on: on) }
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func cap(_ face: some View, on: Bool) -> some View {
        face
            .padding(.horizontal, 10)
            .frame(minWidth: 36, minHeight: 30)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

/// The quick-key bar as the terminal's input accessory (in place of SwiftTerm's own bar, whose
/// keyboard button left its function-key panel up with no letters).
final class QuickKeyAccessory: UIInputView {
    private let host: UIHostingController<QuickKeysBar>

    init(bar: QuickKeysBar) {
        host = UIHostingController(rootView: bar)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            host.view.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ bar: QuickKeysBar) { host.rootView = bar }
}

/// Takes no screen: the conversation's keys only need the Mac to accept terminal input.
final class KeysOnlySink: RemoteTerminalSink {
    func start(cols: Int, rows: Int, screen: Data) {}
    func feed(_ bytes: Data) {}
}

/// The conversation's live keys (the toolbar's keyboard button): Esc interrupts Claude, ⌃C, Tab,
/// arrows (a menu's choice, shift+tab's mode) go to the session's terminal as typed there; with
/// the ClaudeDeck keyboard chosen, its full keyboard types live into Claude's prompt too. While
/// shown, the session's terminal is open on the Mac (without its screen being drawn here).
struct ConversationKeys: View {
    @Environment(RemoteStore.self) private var store
    let sessionID: UUID
    @AppStorage(TerminalKeyboardChoice.key) private var choice = TerminalKeyboardChoice.system
    @State private var state = QuickKeyState()
    @State private var sink = KeysOnlySink()
    @State private var keyboard = HostKeyboardModel()
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var live: Bool { store.terminalStates[sessionID] == .live }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            QuickKeysBar(state: state, showsFunctionKeys: false, send: send, choice: choice, onToggleChoice: { choice = choice.toggled })
                .padding(.vertical, 2)
            if choice == .claudeDeck {
                HostKeyboardView(model: keyboard, compact: sizeClass == .compact)
                    .frame(height: HostKeyboardView.height(compact: sizeClass == .compact))
            }
        }
        .background(.bar)
        .opacity(live ? 1 : 0.6)
        .onAppear {
            store.attachTerminal(sessionID, sink: sink)
            let id = sessionID
            keyboard.onKey = { [weak store, state] event in
                let bytes = event.terminalBytes(applicationCursor: false, extra: state.modifiers)
                state.clear()
                if !bytes.isEmpty { store?.sendTerminalInput(id, data: Data(bytes)) }
            }
        }
        .onDisappear {
            keyboard.onKey = nil
            store.detachTerminal(sessionID, sink: sink)
        }
    }

    private func send(_ key: QuickKey) {
        var bytes = key.bytes(applicationCursor: false)
        let state = store.snapshot?.session(sessionID)?.state
        if bytes == TerminalKeys.escape, !live || state == .running || state?.isBlocked == true {
            // The Mac's interrupt: Esc only while Claude works. On a permission prompt Esc would
            // Deny it, and the conversation has its own buttons for that.
            store.interrupt(sessionID)
            return
        }
        if bytes.count == 1, self.state.option { bytes.insert(0x1b, at: 0) }
        self.state.clear()
        store.sendTerminalInput(sessionID, data: Data(bytes))
    }
}
