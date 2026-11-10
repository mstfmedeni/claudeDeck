import SwiftUI

/// Settings › Mac › Addresses: where to look for the Mac, in order. Each is tried 0.3 s after the
/// one before (the first to answer wins), so with this network's IP first and the Tailscale one
/// after, home connects locally at once and away falls through to Tailscale by itself.
struct AddressesView: View {
    @Environment(RemoteStore.self) private var store
    @State private var newAddress = ""

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                if store.addressOrder.isEmpty {
                    ForEach(store.addressesInOrder, id: \.self) { address in
                        AddressRow(address: address)
                    }
                } else {
                    ForEach(store.addressOrder, id: \.self) { address in
                        AddressRow(address: address)
                    }
                    .onMove { store.addressOrder.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { store.addressOrder.remove(atOffsets: $0) }
                }
            } header: {
                Text(store.addressOrder.isEmpty ? "Automatic order" : "Your order")
            } footer: {
                Text(store.addressOrder.isEmpty
                     ? "This network's addresses first, Tailscale last. Add an address or tap Edit to set your own order."
                     : "Tried top to bottom, each a moment after the one before; the first to answer is used. Addresses the Mac reports later are tried after these.")
            }
            Section("Add an Address") {
                HStack {
                    TextField("192.168.1.20 or mac.tailnet.ts.net", text: $newAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(trimmed.isEmpty)
                }
            }
            if !store.addressOrder.isEmpty {
                Section {
                    Button("Back to Automatic Order", role: .destructive) { store.addressOrder = [] }
                }
            }
        }
        .navigationTitle("Addresses")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.addressOrder.isEmpty {
                    Button("Edit") { store.addressOrder = editable(store.addressesInOrder) }
                } else {
                    EditButton()
                }
            }
        }
    }

    private var trimmed: String {
        newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression)
            .split(separator: "/").first.map(String.init) ?? ""
    }

    /// Bonjour names come and go with the network; the list keeps real addresses.
    private func editable(_ addresses: [String]) -> [String] {
        addresses.filter { RemoteBonjour.serviceName(of: $0) == nil }
    }

    private func add() {
        let address = trimmed
        guard !address.isEmpty else { return }
        var order = store.addressOrder.isEmpty ? editable(store.addressesInOrder) : store.addressOrder
        order.removeAll { $0 == address }
        order.insert(address, at: 0)
        store.addressOrder = order
        newAddress = ""
    }
}

private struct AddressRow: View {
    @Environment(RemoteStore.self) private var store
    let address: String

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Text(RemoteBonjour.serviceName(of: address).map { "\($0) (Bonjour)" } ?? address)
                .font(.body.monospaced())
            Spacer()
            if store.connection == .connected, store.connectedVia == address {
                Text("Connected").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var icon: String {
        if RemoteBonjour.serviceName(of: address) != nil || Tailscale.isPrivateLAN(address) { return "wifi" }
        if Tailscale.isTailscaleIP(address) || address.lowercased().hasSuffix(".ts.net") { return "network" }
        return "globe"
    }
}
