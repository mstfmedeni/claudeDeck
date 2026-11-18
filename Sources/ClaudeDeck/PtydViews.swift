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
        if ptyd.isReadOnly || !ptyd.held.isEmpty {
            Button("Restart Helper (Restarts Sessions)…") { model.confirmRestartHelper() }
        }
    }
}

/// Above the sessions when the helper can't be fully used: an older (incompatible) helper keeps
/// its sessions read-only, or sessions are held because the helper doesn't answer.
struct PtydBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ptyd = model.ptyd
        let readOnly = model.terminals.readOnlySessions.count
        let held = ptyd.held.count
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
