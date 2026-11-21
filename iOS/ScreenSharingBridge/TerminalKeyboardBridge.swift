#if os(iOS)
import Perception
import SwiftUI
import UIKit

// ClaudeDeck's file compiled into ScreenSharingKit (project.yml): the screen-sharing Mac keyboard,
// as is, for the remote app's terminal and conversation. It sees the kit's internal keyboard types
// and hands the app plain events (text or an X11 keysym, with the modifiers held).

/// One key from the on-screen keyboard.
public struct HostKeyEvent: Sendable {
    public enum Kind: Sendable {
        case text(String)
        case keysym(UInt32)
    }

    public let kind: Kind
    public let control: Bool
    public let option: Bool
    public let shift: Bool
    public let command: Bool
}

/// The keyboard's modifier state (sticky, locked, held) and its keys as events.
@Perceptible
public final class HostKeyboardModel: MacKeyboardInput {
    var stickyModifiers: Set<ModifierKey> = []
    private(set) var lockedModifiers: Set<ModifierKey> = []
    private(set) var pressedModifiers: Set<ModifierKey> = []
    var isControlling: Bool { true }

    @PerceptionIgnored public var onKey: ((HostKeyEvent) -> Void)?

    public init() {}

    private var active: Set<ModifierKey> { stickyModifiers.union(lockedModifiers).union(pressedModifiers) }

    private func emit(_ kind: HostKeyEvent.Kind) {
        let held = active
        stickyModifiers = []
        onKey?(HostKeyEvent(kind: kind, control: held.contains(.control), option: held.contains(.option),
                            shift: held.contains(.shift), command: held.contains(.command)))
    }

    func enterText(_ text: String) { emit(.text(text)) }

    func typeKey(_ key: MacKey) {
        if key.keysym == Keysym.space { emit(.text(" ")) } else { emit(.keysym(key.keysym)) }
    }

    func toggleSticky(_ modifier: ModifierKey) {
        if lockedModifiers.contains(modifier) {
            lockedModifiers.remove(modifier)
        } else if stickyModifiers.contains(modifier) {
            stickyModifiers.remove(modifier)
        } else {
            stickyModifiers.insert(modifier)
        }
    }

    func setModifier(_ modifier: ModifierKey, locked: Bool) {
        stickyModifiers.remove(modifier)
        if locked { lockedModifiers.insert(modifier) } else { lockedModifiers.remove(modifier) }
    }

    func setModifier(_ modifier: ModifierKey, pressed: Bool) {
        stickyModifiers.remove(modifier)
        if pressed { pressedModifiers.insert(modifier) } else { pressedModifiers.remove(modifier) }
    }
}

/// The screen-sharing keyboard (the layout chosen in its settings) at a given width.
public struct HostKeyboardView: View {
    let model: HostKeyboardModel
    let compact: Bool

    public init(model: HostKeyboardModel, compact: Bool) {
        self.model = model
        self.compact = compact
    }

    public static func height(compact: Bool) -> CGFloat {
        MacKeyboardView.height(rows: MacKeyboardView.rows, rowHeight: rowHeight(compact: compact))
    }

    static func rowHeight(compact: Bool) -> CGFloat { compact ? 40 : 50 }

    public var body: some View {
        MacKeyboardView(controller: model, layout: AppSettings.shared.macKeyboardLayout,
                        rowHeight: Self.rowHeight(compact: compact), isCompact: compact)
            .background(Color(white: 0.08))
    }
}

/// The keyboard as a text view's `inputView` (it takes the system keyboard's place).
public final class HostKeyboardInputView: UIInputView {
    public let model = HostKeyboardModel()
    private let host: UIHostingController<HostKeyboardView>

    public init(compact: Bool) {
        let height = HostKeyboardView.height(compact: compact)
        host = UIHostingController(rootView: HostKeyboardView(model: model, compact: compact))
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        host.view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
#endif
