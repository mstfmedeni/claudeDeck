import AppKit
import ClaudeDeckCore
import Observation
import SwiftUI

/// Whether anyone can see the UI right now (UIVisibility combines the signals). Views read
/// `windowsVisible` to stop animations and ticks; non-view code that only feeds the screen holds
/// back and catches up on `didChange` once it's visible again. Terminal parsing, hooks, status,
/// notifications, automations, agents and the remote server never look at this.
@MainActor
@Observable
final class AppVisibility {
    static let shared = AppVisibility()
    /// Posted on the main thread whenever `windowsVisible` or `screenVisible` changes.
    static let didChange = Notification.Name("AppVisibilityDidChange")

    private(set) var state = UIVisibility()
    var windowsVisible: Bool { state.windowsVisible }
    var screenVisible: Bool { state.screenVisible }

    @ObservationIgnored private var displaysAsleep = false
    @ObservationIgnored private var sharingCheck: Task<Void, Never>?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var started = false

    private init() {}

    /// Starts listening (once, at launch).
    func start() {
        guard !started else { return }
        started = true
        displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didChangeOcclusionStateNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let checkSharing = note.name == NSApplication.didChangeScreenParametersNotification
                MainActor.assumeIsolated { self?.update(checkSharing: checkSharing) }
                // A closing window is still on screen during willClose.
                if note.name == NSWindow.willCloseNotification {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
                }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysAsleep = true
                self?.update(checkSharing: true)
            }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysAsleep = false
                self?.update(checkSharing: true)
            }
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(checkSharing: true) }
            }
        }
        update(checkSharing: true)
        #if DEBUG
        if Self.debugFile != nil {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { AppVisibility.shared.update() }
            }
        }
        #endif
    }

    #if DEBUG
    /// Development aid: with `CLAUDEDECK_VISIBILITY_FILE=<path>`, a window counts as visible
    /// exactly while that file exists (checked every second), whatever macOS reports — for
    /// measuring both states on a Mac nobody is looking at.
    private static let debugFile = ProcessInfo.processInfo.environment["CLAUDEDECK_VISIBILITY_FILE"]
    #endif

    /// Returns at once when a window is visible, otherwise when one becomes visible (or the task
    /// is cancelled). For loops that only feed a page on screen.
    func waitUntilVisible() async {
        guard !windowsVisible, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor in AppVisibility.shared.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    /// Re-reads every signal; `checkSharing` also looks for a Screen Sharing session right away.
    func update(checkSharing: Bool = false) {
        #if DEBUG
        if let file = Self.debugFile {
            var forced = UIVisibility()
            forced.windowOnScreen = FileManager.default.fileExists(atPath: file)
            apply(forced)
            return
        }
        #endif
        var next = state
        let windows = NSApp.windows.filter { $0.isVisible && !Self.isStatusBarWindow($0) }
        next.windowOnScreen = windows.contains { $0.occlusionState.contains(.visible) && !$0.isMiniaturized }
        next.appHidden = NSApp.isHidden
        next.displaysAsleep = displaysAsleep
        next.hasScreens = !NSScreen.screens.isEmpty
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        next.sessionActive = (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        next.screenLocked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        if !next.needsSharingCheck {
            // Not needed while windows are visible anyway; a stale "sharing" must not keep us awake.
            next.screenSharing = false
        } else if checkSharing || !state.needsSharingCheck {
            next.screenSharing = ScreenSharingDetector.isSessionActive()
        }
        apply(next)
        scheduleSharingCheck()
    }

    private func apply(_ next: UIVisibility) {
        guard next != state else { return }
        let changed = next.windowsVisible != state.windowsVisible || next.screenVisible != state.screenVisible
        state = next
        guard changed else { return }
        if windowsVisible { resumeWaiters() }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func resumeWaiters() {
        let pending = waiters.values
        waiters = [:]
        for waiter in pending { waiter.resume() }
    }

    /// Every 10 s while paused (or visible only through sharing): a viewer connecting with no
    /// local signal (the display stays off) shows up within that time.
    private func scheduleSharingCheck() {
        guard state.needsSharingCheck else {
            sharingCheck?.cancel()
            sharingCheck = nil
            return
        }
        guard sharingCheck == nil else { return }
        sharingCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.sharingCheck = nil
            self.update(checkSharing: true)
        }
    }

    private static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("StatusBarWindow")
    }
}

/// A periodic `TimelineView` that only ticks while a window is visible; otherwise it draws once
/// (and again, current, when a window shows up).
struct VisibleTimeline<Content: View>: View {
    let interval: TimeInterval
    @ViewBuilder let content: (Date) -> Content

    init(every interval: TimeInterval, @ViewBuilder content: @escaping (Date) -> Content) {
        self.interval = interval
        self.content = content
    }

    var body: some View {
        if AppVisibility.shared.windowsVisible {
            TimelineView(.periodic(from: .now, by: interval)) { context in content(context.date) }
        } else {
            content(Date())
        }
    }
}
