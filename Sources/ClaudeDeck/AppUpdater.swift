import ClaudeDeckCore
import Combine
import os
import Sparkle
import SwiftUI

private let updateLog = Logger(subsystem: "app.claudedeck", category: "update")

/// Sparkle updates: checks the appcast on the project site (`SUFeedURL` in Info.plist) in the
/// background, and on demand from "Check for Updates…". Updates are EdDSA-signed (`SUPublicEDKey`);
/// Sparkle only installs a DMG signed with the matching private key.
///
/// With "Install updates automatically" (default on) Sparkle downloads an update silently and
/// ClaudeDeck relaunches into it by itself at a quiet moment (UpdateInstallTiming): sessions in the
/// session helper keep running through the relaunch. Until then it installs on quit, as always.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// nil in demo mode and in unbundled `swift build` runs (no feed in the Info.plist).
    private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: AnyCancellable?

    /// Development aid: `CLAUDEDECK_UPDATE_FEED` points the updater at another appcast (e.g. a local
    /// test feed) and enables it in demo mode.
    private static let testFeed = ProcessInfo.processInfo.environment["CLAUDEDECK_UPDATE_FEED"]
    @ObservationIgnored private let delegate = UpdaterDelegate(feed: testFeed)
    /// Work held back until the launch update check is settled (see `startHoldingForUpdate`).
    @ObservationIgnored private var held: (@MainActor () -> Void)?
    @ObservationIgnored private var installing = false
    @ObservationIgnored private weak var model: AppModel?
    /// Sparkle's "install now and relaunch", kept until a quiet moment.
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var installWatch: Task<Void, Never>?
    @ObservationIgnored private var lastActiveAt = Date()
    /// Set right before relaunching into an update: quitting skips the confirmation and keeps
    /// every session the helper can keep.
    private(set) var relaunchingForUpdate = false
    /// Waiting for a quiet moment to install a downloaded update (Settings shows it).
    private(set) var updateReady = false

    nonisolated static let autoInstallKey = "updates.autoInstall"
    static var autoInstall: Bool {
        get { UserDefaults.standard.object(forKey: autoInstallKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: autoInstallKey)
            shared.controller?.updater.automaticallyDownloadsUpdates = newValue
            if newValue { shared.watchForQuietMoment() } else { shared.installWatch?.cancel(); shared.installWatch = nil }
        }
    }

    private init() {
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        guard hasFeed, !AppModel.isDemo || Self.testFeed != nil else { controller = nil; return }
        // Started in startHoldingForUpdate, so the launch check is ours.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        self.controller = controller
        delegate.owner = self
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    var isAvailable: Bool { controller != nil }

    /// Starts the updater and, when automatic checks are on, checks right away. `then` (resuming the
    /// sessions) runs once there is no update, the check fails or takes over 8 s, the user
    /// postpones or skips the update, or nobody answers within 2 minutes. If they install it, it doesn't run: the app relaunches into
    /// the new version and the sessions resume there, instead of starting twice.
    func startHoldingForUpdate(model: AppModel, then: @escaping @MainActor () -> Void) {
        self.model = model
        guard let controller else { return then() }
        controller.updater.automaticallyDownloadsUpdates = Self.autoInstall
        // Hourly instead of Sparkle's daily: with installs that wait for a quiet moment, a fix
        // reaches a running Mac within the hour.
        controller.updater.updateCheckInterval = 3600
        controller.startUpdater()
        guard controller.updater.automaticallyChecksForUpdates else { return then() }
        held = then
        // Called right after starting, this replaces Sparkle's own scheduled launch check.
        controller.updater.checkForUpdatesInBackground()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !self.foundUpdate else { return }
            self.release()
        }
        // Nobody may be looking (launched at login into the menu bar): don't hold sessions forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            self?.release()
        }
    }

    @ObservationIgnored fileprivate var foundUpdate = false

    fileprivate func release() {
        guard !installing, let work = held else { return }
        held = nil
        work()
    }

    fileprivate func userChose(_ choice: SPUUserUpdateChoice) {
        if choice == .install { installing = true } else { release() }
    }

    fileprivate func aborted() {
        installing = false
        release()
    }

    /// Sparkle downloaded an update that installs on quit. Returns whether we take it over.
    fileprivate func readyToInstall(_ install: @escaping () -> Void) -> Bool {
        guard Self.autoInstall, model != nil else { return false }
        pendingInstall = install
        updateReady = true
        updateLog.info("update downloaded; installing at a quiet moment")
        watchForQuietMoment()
        return true
    }

    /// Checks every 10 s and relaunches into the downloaded update once nothing would be lost
    /// or interrupted.
    private func watchForQuietMoment() {
        guard installWatch == nil, pendingInstall != nil else { return }
        installWatch = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.pendingInstall != nil {
                if NSApp.isActive { self.lastActiveAt = Date() }
                if let state = self.installState(), UpdateInstallTiming.decide(state) == .install {
                    self.installNow()
                    break
                }
                try? await Task.sleep(for: .seconds(10))
            }
            self?.installWatch = nil
        }
    }

    private func installState() -> UpdateInstallTiming.State? {
        guard let model else { return nil }
        let outside = model.deck.sessions.filter {
            model.terminals.isRunning($0.id) && !model.terminals.isInHelper($0.id)
        }.count
        let pending = NSApp.modalWindow != nil
            || NSApp.windows.contains { $0.isDocumentEdited || ($0.isVisible && $0.attachedSheet != nil) }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return .init(sessionsOutsideHelper: outside,
                     helperBusy: model.ptyd.restarting || model.ptyd.awaitingQuietRestart,
                     pendingUserInput: pending, systemIdle: idle,
                     inactiveFor: NSApp.isActive ? 0 : Date().timeIntervalSince(lastActiveAt))
    }

    private func installNow() {
        guard let install = pendingInstall else { return }
        pendingInstall = nil
        updateLog.info("quiet moment: relaunching into the downloaded update")
        relaunchingForUpdate = true
        install()
    }

    /// Settings › General: "Install Now" next to "an update is ready".
    func installUpdateNow() { installNow() }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let feed: String?
    @MainActor weak var owner: AppUpdater?
    init(feed: String?) { self.feed = feed }

    func feedURLString(for updater: SPUUpdater) -> String? { feed }
    /// A relaunch drops the environment (demo mode, test feed): the relaunched app would run as a
    /// normal instance on the real deck.json and resume every real session a second time.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { feed == nil }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { owner?.foundUpdate = true }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { owner?.release() }
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { owner?.userChose(choice) }
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { owner?.readyToInstall(immediateInstallHandler) ?? false }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        MainActor.assumeIsolated { owner?.aborted() }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { owner?.release() }
    }
}

/// App menu: "Check for Updates…" right under "About ClaudeDeck".
struct UpdateCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

/// Settings › General.
struct UpdateSettingsRows: View {
    @State private var automatic = AppUpdater.shared.automaticallyChecks
    @State private var autoInstall = AppUpdater.autoInstall

    var body: some View {
        let updater = AppUpdater.shared
        if updater.isAvailable {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { automatic },
                set: { automatic = $0; updater.automaticallyChecks = $0 }
            ))
            Toggle(isOn: Binding(get: { autoInstall }, set: { autoInstall = $0; AppUpdater.autoInstall = $0 })) {
                Text("Install updates automatically")
                Text("Downloads updates in the background and relaunches into them when you're away. Sessions kept in the background helper keep running; while others are open, the update waits.")
            }
            .disabled(!automatic)
            if updater.updateReady {
                HStack {
                    Text("An update is downloaded and installs at a quiet moment.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Install Now") { updater.installUpdateNow() }
                }
            }
            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
