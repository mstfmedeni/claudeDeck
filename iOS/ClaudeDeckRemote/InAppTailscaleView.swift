import SwiftUI

/// Settings › In-App Tailscale: on/off, sign in and out, what the node is called and where it is.
struct InAppTailscaleView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        @Bindable var tailnet = store.tailnet
        Form {
            Section {
                Toggle("In-App Tailscale", isOn: $tailnet.enabled)
            } footer: {
                Text("Reaches your Mac's Tailscale address from this app, without the Tailscale app's VPN, alongside any VPN. When the system can reach the Mac (the Tailscale app is on), that comes first.")
            }
            if tailnet.enabled {
                Section {
                    LabeledContent("Status", value: statusText(tailnet.status))
                    if case .connected(let ip, let name) = tailnet.status {
                        if let ip { LabeledContent("Tailscale Address") { Text(ip).font(.callout.monospaced()).textSelection(.enabled) } }
                        if let name { LabeledContent("Name") { Text(name).font(.caption.monospaced()).textSelection(.enabled) } }
                    } else {
                        LabeledContent("Device Name") { Text(InAppTailnet.hostname).font(.callout.monospaced()) }
                    }
                    LabeledContent("Tag") { Text(InAppTailscale.tag).font(.callout.monospaced()) }
                    if case .failed(let message, let tagRejected) = tailnet.status {
                        Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                        if tagRejected {
                            Text("Your tailnet doesn't let you sign in a device with the tag tag:claudedeck. In the Tailscale admin console › Access controls, add it to \"tagOwners\" (see \"In-app Tailscale\" in ClaudeDeck's README), then sign in again.")
                                .font(.footnote)
                        }
                    }
                } footer: {
                    if tailnet.status == .idle { Text("Starts when a connection needs it.") }
                }
                Section {
                    switch tailnet.status {
                    case .signedOut, .failed, .off:
                        Button("Sign In to Tailscale") { tailnet.signIn() }
                    case .starting, .signingIn:
                        HStack {
                            ProgressView()
                            Button("Cancel", role: .cancel) { tailnet.cancelSignIn() }
                        }
                    case .connected, .idle:
                        Button("Sign Out of Tailscale", role: .destructive) { tailnet.signOut() }
                    }
                } footer: {
                    Text("Signing in opens Tailscale's login page. Signing out removes this device from your tailnet and deletes its Tailscale data from the app.")
                }
            }
            Section {
            } footer: {
                Text("Covers sessions, conversations, terminals, edits and files. Mac Screen doesn't use it yet: it needs the Tailscale app or the same network.")
            }
        }
        .navigationTitle("In-App Tailscale")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusText(_ status: InAppTailnet.Status) -> String {
        switch status {
        case .off: String(localized: "Off")
        case .signedOut: String(localized: "Signed out")
        case .idle: String(localized: "Signed in")
        case .starting: String(localized: "Starting…")
        case .signingIn: String(localized: "Waiting for sign-in…")
        case .connected: String(localized: "Connected")
        case .failed: String(localized: "Couldn't sign in")
        }
    }
}
