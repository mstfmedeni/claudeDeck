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
                Text(!store.addressOrder.isEmpty ? "Your order" : store.macOrdered ? "The Mac's order" : "Automatic order")
            } footer: {
                Text(store.addressOrder.isEmpty
                     ? (store.macOrdered
                        ? "As set on the Mac (Settings › Remote › Addresses). Add an address or tap Edit to use your own order on this device."
                        : "This network's addresses first, Tailscale last. Add an address or tap Edit to set your own order.")
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
        let kind = AddressKind(address)
        HStack {
            Image(systemName: kind.symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(RemoteBonjour.serviceName(of: address) ?? address).font(.body.monospaced())
                Text(kind.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.connection == .connected, store.connectedVia == address {
                Text("Connected").font(.caption).foregroundStyle(.green)
            }
        }
    }
}

/// What an address is, for the lists: this network, Tailscale or something else.
enum AddressKind {
    case bonjour, lan, tailscale, loopback, other

    init(_ address: String) {
        let lower = address.lowercased()
        if RemoteBonjour.serviceName(of: address) != nil { self = .bonjour }
        // Tailscale first: its IPv6 range is a unique-local one, which would count as this network.
        else if Tailscale.isTailscaleIP(address) || lower.hasSuffix(".ts.net") { self = .tailscale }
        else if address == "127.0.0.1" || address == "::1" || lower == "localhost" { self = .loopback }
        else if Tailscale.isPrivateLAN(address) || lower.hasSuffix(".local") { self = .lan }
        else { self = .other }
    }

    var symbol: String {
        switch self {
        case .bonjour, .lan: "wifi"
        case .tailscale: "lock.shield"
        case .loopback: "laptopcomputer"
        case .other: "globe"
        }
    }

    var title: String {
        switch self {
        case .bonjour: String(localized: "This network (Bonjour)")
        case .lan: String(localized: "This network")
        case .tailscale: String(localized: "Tailscale")
        case .loopback: String(localized: "This device")
        case .other: String(localized: "Other")
        }
    }
}
