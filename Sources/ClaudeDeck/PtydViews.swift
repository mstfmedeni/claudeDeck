import AppKit
import ClaudeDeckCore
import SwiftUI

/// Settings › Sessions: "Keep sessions running when ClaudeDeck quits" and the helper's status.
struct PtydSettingsRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ptyd = model.ptyd
        Toggle(isOn: Binding(
            get: { model.deck.settings.keepSessionsRunning },
            set: { model.setKeepSessionsRunning($0) }
        )) {
            HStack(spacing: 6) {
                Text("Keep sessions running when ClaudeDeck quits")
                Text("Experimental")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.15), in: Capsule())
            }
        }
        Text("New sessions run in a small background helper and keep running when ClaudeDeck quits, crashes or updates. At launch ClaudeDeck reattaches to them, with their recent output, instead of resuming them. Sessions already open stay as they are. Restarting the Mac or logging out still ends them.")
            .font(.caption).foregroundStyle(.secondary)
        if ptyd.isConnected {
            let count = model.terminals.helperSessionIDs.count
            Text("Helper running (build \(ptyd.helperBuild ?? "?")), sessions in it: \(count)")
                .font(.caption).foregroundStyle(.secondary)
            if ptyd.isOutdated, let build = ptyd.helperBuild {
                Text("Helper is outdated (build \(build), app build \(PtydController.appBuild))")
                    .font(.caption).foregroundStyle(.orange)
                Text("It keeps serving the sessions running in it. Restart it to run this build's helper; with no sessions in it, ClaudeDeck replaces it by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.deck.settings.keepSessionsRunning {
                PtydAccessRows()
            }
        }
        if let problem = ptyd.problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
        if !ptyd.orphans.isEmpty {
            HStack {
                Text("Sessions in the helper that belong to no project here: \(ptyd.orphans.count)")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("End Them") { ptyd.endOrphans() }
                    .disabled(ptyd.isReadOnly)
            }
        }
        // Always offered while a helper runs (or holds sessions): it's also how an outdated helper
        // is upgraded and how a new privacy grant (Full Disk Access) takes effect.
        if ptyd.isConnected || !ptyd.held.isEmpty {
            PtydRestartButton()
        }
    }
}

/// Settings › Sessions, while sessions run in the helper: what privacy (TCC) lets the helper
/// open, and how to give it Full Disk Access when the app has more than the helper.
struct PtydAccessRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ptyd = model.ptyd
        HStack {
            Text("Session helper's disk access: \(Self.levelName(ptyd.helperAccess?.level ?? .unknown))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "ptyd.access.checkAgain", defaultValue: "Check Again")) { Task { await ptyd.checkAccess() } }
                .controlSize(.small)
        }
        if ptyd.helperLacksAccess {
            VStack(alignment: .leading, spacing: 6) {
                Text("ClaudeDeck can open folders the session helper can't. macOS treats the helper (claudedeck-ptyd) as a separate app, so ClaudeDeck's Full Disk Access doesn't cover the sessions running in it: they get \"Operation not permitted\" there.")
                    .font(.caption).foregroundStyle(.orange)
                Text("In Full Disk Access: + › ⌘⇧G › paste › Open, and turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Settings and Copy Path") { Self.openFullDiskAccessSettings() }
                Text("The grant applies once the helper restarts:")
                    .font(.caption).foregroundStyle(.secondary)
                PtydRestartButton()
            }
        }
    }

    static func levelName(_ level: PtydAccessReport.Level) -> String {
        switch level {
        case .full: String(localized: "ptyd.access.full", defaultValue: "Full")
        case .desktopOnly: String(localized: "ptyd.access.desktopOnly", defaultValue: "Desktop only")
        case .none: String(localized: "ptyd.access.none", defaultValue: "None")
        case .unknown: String(localized: "ptyd.access.unknown", defaultValue: "Unknown")
        }
    }

    /// The helper's path on the pasteboard (for ⌘⇧G in the file panel), then Privacy & Security ›
    /// Full Disk Access.
    static func openFullDiskAccessSettings() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/MacOS/claudedeck-ptyd").path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(helper, forType: .string)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// "Restart Helper (Restarts Sessions)…", disabled while a restart runs.
struct PtydRestartButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.confirmRestartHelper()
        } label: {
            model.ptyd.restarting ? Text("Restarting…") : Text("Restart Helper (Restarts Sessions)…")
        }
        .disabled(model.ptyd.restarting)
    }
}

/// Above the sessions when the helper can't be fully used: an older (incompatible) helper keeps
/// its sessions read-only, or sessions are held because the helper doesn't answer.
struct PtydBanner: View {
    @Environment(AppModel.self) private var model
    /// The privacy hint is shown until dismissed once (per Mac user, not per deck).
    @AppStorage("ptyd.accessHintDismissed") private var accessHintDismissed = false

    var body: some View {
        let ptyd = model.ptyd
        let readOnly = model.terminals.readOnlySessions.count
        let held = ptyd.held.count
        if readOnly == 0, held == 0, ptyd.helperLacksAccess, !accessHintDismissed,
           model.deck.settings.keepSessionsRunning {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(.orange)
                Text("Sessions in the session helper can't open folders ClaudeDeck can: give claudedeck-ptyd Full Disk Access too (Settings › Sessions).")
                    .font(.callout)
                Spacer()
                Button("Open Settings and Copy Path") { PtydAccessRows.openFullDiskAccessSettings() }
                Button {
                    accessHintDismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(Text("Don't show again"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
        }
        if readOnly > 0 || held > 0 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    if readOnly > 0 {
                        Text("Restart sessions to upgrade: \(readOnly) sessions run in an older session helper and are read-only.")
                    }
                    if held > 0 {
                        Text("\(held) sessions may still be running in a session helper that doesn't answer; they are left alone so nothing runs twice.")
                    }
                }
                .font(.callout)
                Spacer()
                Button {
                    model.confirmRestartHelper()
                } label: {
                    ptyd.restarting ? Text("Restarting…") : Text("Restart Helper (Restarts Sessions)…")
                }
                .disabled(ptyd.restarting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
        }
    }
}
