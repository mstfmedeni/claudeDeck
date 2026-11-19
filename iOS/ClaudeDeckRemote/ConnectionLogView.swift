import SwiftUI
import UIKit

/// Settings › Connection Log: the last connection attempts (newest first), each address with the
/// way it was tried, how it ended and how long it took, and the waits before the next round. For
/// "can't connect" reports; kept in memory only, Copy puts it on the clipboard as text.
struct ConnectionLogView: View {
    @Environment(RemoteStore.self) private var store
    @State private var copied = false

    var body: some View {
        let entries = Array(store.connectionLog.entries.reversed())
        List {
            if entries.isEmpty {
                ContentUnavailableView("No Attempts Yet", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Connection attempts to the Mac show up here."))
            } else {
                Section {
                    ForEach(entries) { entry in row(entry) }
                } footer: {
                    Text("The last \(RemoteConnectionLog.capacity) attempts, kept until the app quits.")
                }
            }
        }
        .navigationTitle("Connection Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = store.connectionLog.text()
                    copied = true
                } label: { Label("Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .disabled(entries.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { store.clearConnectionLog() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(entries.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: RemoteConnectionLog.Entry) -> some View {
        switch entry.kind {
        case .attempt(let address, let route, let outcome, let duration):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.icon(outcome)).foregroundStyle(Self.color(outcome)).frame(width: 20).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(RemoteBonjour.serviceName(of: address) ?? address).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(entry.at, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(Self.routeLabel(route))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        Text(Self.result(outcome)).font(.caption.weight(.medium)).foregroundStyle(Self.color(outcome))
                        Text(Self.seconds(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let reason = Self.reason(outcome) {
                        Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 1)
        case .backoff(let wait, let reason):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hourglass").foregroundStyle(.secondary).frame(width: 20).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Waiting \(Self.seconds(wait)) before trying again").font(.callout)
                        Spacer(minLength: 4)
                        Text(entry.at, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 1)
        }
    }

    static func routeLabel(_ route: RemoteConnectionLog.Route) -> String {
        switch route {
        case .lan: String(localized: "Local network")
        case .tailscale: String(localized: "Tailscale")
        case .inAppTailscale: String(localized: "In-App Tailscale")
        case .other: String(localized: "Other")
        }
    }

    static func result(_ outcome: RemoteConnectionLog.Outcome) -> String {
        switch outcome {
        case .connected: String(localized: "Connected")
        case .failed: String(localized: "Failed")
        case .refused: String(localized: "Refused")
        case .cancelled: String(localized: "Not needed")
        case .skipped: String(localized: "Skipped")
        }
    }

    static func reason(_ outcome: RemoteConnectionLog.Outcome) -> String? {
        switch outcome {
        case .failed(let reason): reason
        case .refused(let reason): reason
        case .skipped(let reason): reason
        case .connected, .cancelled: nil
        }
    }

    static func icon(_ outcome: RemoteConnectionLog.Outcome) -> String {
        switch outcome {
        case .connected: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .refused: "lock.circle.fill"
        case .cancelled: "minus.circle"
        case .skipped: "arrow.uturn.right.circle"
        }
    }

    static func color(_ outcome: RemoteConnectionLog.Outcome) -> Color {
        switch outcome {
        case .connected: .green
        case .failed: .red
        case .refused: .orange
        case .cancelled, .skipped: .secondary
        }
    }

    static func seconds(_ value: TimeInterval) -> String {
        value < 10 ? String(format: "%.1f s", value) : String(format: "%.0f s", value)
    }
}
