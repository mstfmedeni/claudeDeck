import AppKit
import ClaudeDeckCore
import SwiftUI

enum StatusStyle {
    static let running = Color.green
    static let blocked = Color.red
    static let idle = Color.yellow
    static let inactive = Color.secondary.opacity(0.5)
    /// A terminal's command that failed.
    static let failed = Color.orange

    static func label(for display: DisplayState) -> String {
        switch display {
        case .program(let program): programLabel(program)
        case .notStarted, .activity(.ended): String(localized: "Stopped")
        case .starting: String(localized: "Starting")
        case .shell: String(localized: "Terminal")
        case .activity(.running): String(localized: "Running")
        case .activity(.needsPermission): String(localized: "Needs permission")
        case .activity(.needsAnswer): String(localized: "Asking a question")
        case .activity(.idle): String(localized: "Your turn")
        }
    }

    static func programLabel(_ program: ProgramBadge) -> String {
        switch program.state {
        case .working: String(localized: "Running")
        case .blocked:
            switch program.kind {
            case .permission?: String(localized: "Needs permission")
            case .question?: String(localized: "Asking a question")
            case .auth?: String(localized: "Needs sign-in")
            case nil: String(localized: "Needs input")
            }
        case .finished: String(localized: "Finished")
        case .failed: program.exitCode.map { String(localized: "Failed (exit \(Int($0)))") } ?? String(localized: "Failed")
        }
    }

    /// Dark text on the light fills (yellow, green), white on the dark ones (red, blue): white on
    /// green was unreadable in dark mode.
    static func pillText(for display: DisplayState) -> Color {
        display.program?.state == .failed ? .white
            : display.isIdle || display.isRunning || display == .starting ? .black.opacity(0.8) : .white
    }

    static func color(for display: DisplayState) -> Color {
        switch display {
        case .activity(.running): running
        case .activity(.needsPermission), .activity(.needsAnswer): blocked
        case .activity(.idle): idle
        case .starting: running.opacity(0.5)
        case .shell: .blue
        case .program(let program):
            switch program.state {
            case .working: running
            case .blocked: blocked
            case .finished: idle
            case .failed: failed
            }
        case .notStarted, .activity(.ended): inactive
        }
    }
}

struct StatusDot: View {
    let display: DisplayState
    var unseen = false

    var body: some View {
        let color = StatusStyle.color(for: display)
        ZStack {
            if display.isBlocked || display.isRunning {
                PulseRing(color: NSColor(color.opacity(0.35)), filled: true, scale: 0.5...1, opacity: 1,
                          duration: display.isBlocked ? 1.0 : 1.6, active: AppVisibility.shared.windowsVisible)
                    .frame(width: 14, height: 14)
            }
            if display.isIdle && !unseen && display.program?.state != .failed {
                // Seen "your turn": a quiet grey ring; only unseen ones are yellow.
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel(Text(accessibility))
    }

    private var accessibility: String {
        switch display {
        case .activity(.running): String(localized: "Running")
        case .activity(.needsPermission): String(localized: "Needs permission")
        case .activity(.needsAnswer): String(localized: "Waiting for an answer")
        case .activity(.idle): String(localized: "Your turn")
        case .activity(.ended), .notStarted: String(localized: "Stopped")
        case .starting: String(localized: "Starting")
        case .shell: String(localized: "Terminal")
        case .program(let program): StatusStyle.programLabel(program)
        }
    }
}

/// Colored, labeled status chip — readable at a glance, not just a dot.
/// Running shows flowing dots, waiting-for-you pulses.
struct StatusPill: View {
    let display: DisplayState
    var unseen = false

    var body: some View {
        let inactive = display == .notStarted || display == .activity(.ended)
        // Seen "your turn" stays yellow but softer than a fresh one.
        let fill: Color = inactive ? Color.secondary.opacity(0.18)
            : display.isIdle && !unseen ? StatusStyle.color(for: display).opacity(0.45)
            : StatusStyle.color(for: display)
        let live = AppVisibility.shared.windowsVisible
        HStack(spacing: 0) {
            Text(StatusStyle.label(for: display))
            if display.isRunning || display == .starting {
                // Three character cells wide, like the "···" it draws.
                Text("   ").monospaced().hidden()
                    .overlay { FlowingDots(color: NSColor(StatusStyle.pillText(for: display)), active: live) }
            }
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(StatusStyle.pillText(for: display)))
        .background(Capsule().fill(fill))
        .overlay {
            if display.isBlocked {
                PulseRing(color: NSColor(StatusStyle.blocked), filled: false, lineWidth: 2, scale: 1...1.25, opacity: 0.8,
                          duration: 1.1, active: live)
            }
        }
        .fixedSize()
        .animation(.snappy, value: display)
    }
}

/// A shape that grows and fades out, over and over. Core Animation runs it in the render server,
/// so it costs the app nothing per frame — a SwiftUI `repeatForever` animation re-renders the
/// view graph (in the sidebar: the whole list's layout) on every frame. Stops while no window is
/// visible.
struct PulseRing: NSViewRepresentable {
    var color: NSColor
    /// A filled circle (the dot's halo) or a stroked capsule (the pill's ring).
    var filled: Bool
    var lineWidth: CGFloat = 0
    var scale: ClosedRange<CGFloat>
    var opacity: Float
    var duration: CFTimeInterval
    var active: Bool

    func makeNSView(context: Context) -> PulseLayerView { PulseLayerView() }

    func updateNSView(_ view: PulseLayerView, context: Context) {
        view.configure(self)
    }
}

final class PulseLayerView: NSView {
    private let shape = CAShapeLayer()
    private var config: PulseRing?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ config: PulseRing) {
        let timingChanged = self.config.map {
            $0.scale != config.scale || $0.opacity != config.opacity || $0.duration != config.duration
        } ?? true
        let shapeChanged = self.config.map { $0.filled != config.filled || $0.lineWidth != config.lineWidth } ?? true
        self.config = config
        applyColor()
        if timingChanged { shape.removeAnimation(forKey: "pulse") }
        if shapeChanged { needsLayout = true }
        refreshAnimation()
    }

    override func layout() {
        super.layout()
        guard let config else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = bounds
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let inset = bounds.insetBy(dx: config.lineWidth / 2, dy: config.lineWidth / 2)
        let radius = min(inset.width, inset.height) / 2
        shape.path = config.filled
            ? CGPath(ellipseIn: inset, transform: nil)
            : CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
        shape.lineWidth = config.lineWidth
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        guard let config else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let cg = config.color.cgColor
            shape.fillColor = config.filled ? cg : nil
            shape.strokeColor = config.filled ? nil : cg
        }
    }

    /// Animates only in a window and while someone can see it; a reused list row or a window
    /// coming back gets its animation again.
    private func refreshAnimation() {
        shape.opacity = 0
        guard let config, config.active, window != nil else {
            shape.removeAnimation(forKey: "pulse")
            return
        }
        guard shape.animation(forKey: "pulse") == nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = config.scale.lowerBound
        grow.toValue = config.scale.upperBound
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = config.opacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = config.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        shape.add(group, forKey: "pulse")
    }
}

/// The running pill's "·", "··", "···" cycle (a step every 0.35 s), drawn by Core Animation like
/// `PulseRing`; every pill shows the same step.
struct FlowingDots: NSViewRepresentable {
    var color: NSColor
    var active: Bool

    func makeNSView(context: Context) -> FlowingDotsView { FlowingDotsView() }

    func updateNSView(_ view: FlowingDotsView, context: Context) {
        view.color = color
        view.active = active
    }
}

final class FlowingDotsView: NSView {
    static let step: CFTimeInterval = 0.35
    private let dots = (0..<3).map { _ in CALayer() }
    var color: NSColor = .labelColor { didSet { if color != oldValue { applyColor() } } }
    var active = false { didSet { if active != oldValue { refreshAnimation() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for dot in dots { layer?.addSublayer(dot) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A font's middle dot sits about at the vertical center of the line.
        let cell = bounds.width / 3
        let size = max(2, (bounds.height * 0.19).rounded())
        for (i, dot) in dots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.position = CGPoint(x: cell * (CGFloat(i) + 0.5), y: bounds.midY - 0.5)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for dot in dots { dot.backgroundColor = color.cgColor }
        }
    }

    private func refreshAnimation() {
        applyColor()
        guard active, window != nil else {
            for dot in dots {
                dot.removeAnimation(forKey: "step")
                dot.opacity = 1
            }
            return
        }
        let period = Self.step * 4
        let now = CACurrentMediaTime()
        for (i, dot) in dots.enumerated() {
            dot.opacity = 0
            guard dot.animation(forKey: "step") == nil else { continue }
            // Dot i shows from step i + 1 on.
            let steps = CAKeyframeAnimation(keyPath: "opacity")
            steps.values = [0, 1]
            steps.keyTimes = [0, NSNumber(value: Double(i + 1) / 4), 1]
            steps.calculationMode = .discrete
            steps.duration = period
            steps.repeatCount = .infinity
            steps.isRemovedOnCompletion = false
            // Same phase in every pill.
            steps.beginTime = dot.convertTime(now - now.truncatingRemainder(dividingBy: period), from: nil)
            dot.add(steps, forKey: "step")
        }
    }
}

/// Briefly lights up a row when its state changes.
struct StateChangeFlash: ViewModifier {
    let display: DisplayState
    @State private var flash = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(StatusStyle.color(for: display).opacity(flash ? 0.22 : 0))
                    .padding(.horizontal, -4)
            )
            .onChange(of: display) { _, _ in
                withAnimation(.easeIn(duration: 0.15)) { flash = true }
                withAnimation(.easeOut(duration: 1.2).delay(0.25)) { flash = false }
            }
    }
}

extension View {
    func flashOnStateChange(_ display: DisplayState) -> some View { modifier(StateChangeFlash(display: display)) }
}

/// Worst state among sessions: red > green > unseen yellow.
struct AggregateBadge: View {
    @Environment(AppModel.self) private var model
    let sessionIDs: [UUID]

    var body: some View {
        let blocked = sessionIDs.filter { model.status(of: $0).display.isBlocked }.count
        let running = sessionIDs.filter { model.status(of: $0).display.isRunning }.count
        let unseen = sessionIDs.filter { model.isUnseenIdle($0) }.count
        HStack(spacing: 4) {
            if blocked > 0 { pill(blocked, StatusStyle.blocked) }
            if running > 0 { pill(running, StatusStyle.running) }
            if unseen > 0 { pill(unseen, StatusStyle.idle) }
        }
    }

    private func pill(_ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(n)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }
}

enum GroupPalette {
    static let colors: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal]
    static let names = [String(localized: "Blue"), String(localized: "Purple"), String(localized: "Pink"), String(localized: "Red"),
                         String(localized: "Orange"), String(localized: "Yellow"), String(localized: "Green"), String(localized: "Teal")]
    static var count: Int { colors.count }
    static func color(_ i: Int) -> Color { colors[((i % count) + count) % count] }
}

enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<10: return String(localized: "now")
        case ..<60: return String(localized: "\(s)s")
        case ..<3600: return String(localized: "\(s / 60)m")
        case ..<86400: return String(localized: "\(s / 3600)h")
        default: return String(localized: "\(s / 86400)d")
        }
    }
}

/// How a terminal session starts: ⚡ auto-starts with the app (startup command), ▶︎ has a startup
/// command but starts only when opened. Plain terminals and Claude sessions show nothing.
struct ShellStartBadge: View {
    let session: DeckSession

    var body: some View {
        if session.kind == .shell, let command = session.startupCommand {
            let auto = session.autoStart
            Label(auto ? String(localized: "Auto") : String(localized: "Command"), systemImage: auto ? "bolt.fill" : "play.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .foregroundStyle(auto ? Color.orange : Color.secondary)
                .background(Capsule().strokeBorder(auto ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.5), lineWidth: 1))
                .fixedSize()
                .help(auto ? String(localized: "Starts automatically when the app launches: \(command)") : String(localized: "Runs when opened: \(command)"))
        }
    }
}
