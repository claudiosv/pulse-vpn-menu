import SwiftUI

/// A list of short text entries being edited in the form (routes, DNS
/// servers, DNS domains): the entries, what is typed in its add field, and
/// the rule an entry has to pass.
private struct EditableList {
    var items: [String]
    /// What is typed in the add field, not yet added.
    var draft = ""
    let isValid: (String) -> Bool
    let invalidMessage: String

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the typed entry can't be added, or nil if it can (or the field
    /// is empty).
    var problem: String? {
        let entry = trimmedDraft
        if entry.isEmpty { return nil }
        if !isValid(entry) { return invalidMessage }
        if items.contains(entry) { return "That is already in the list." }
        return nil
    }

    var canAdd: Bool { !trimmedDraft.isEmpty && problem == nil }

    mutating func add() {
        guard canAdd else { return }
        items.append(trimmedDraft)
        draft = ""
    }

    /// The list as saved. A valid entry still sitting in the add field
    /// counts, so clicking Save without clicking Add first doesn't lose it.
    var saved: String? {
        let all = canAdd ? items + [trimmedDraft] : items
        return all.isEmpty ? nil : all.joined(separator: ", ")
    }
}

/// One form section editing an `EditableList`: a row per entry with a
/// remove button, then an add field.
private struct ListSection: View {
    let title: String
    let prompt: String
    let footer: String
    @Binding var list: EditableList

    var body: some View {
        Section {
            ForEach(list.items, id: \.self) { item in
                HStack {
                    Text(item)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        list.items.removeAll { $0 == item }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(item)")
                    .accessibilityLabel("Remove \(item)")
                }
            }
            HStack {
                TextField("Add to \(title)", text: $list.draft, prompt: Text(prompt))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit { list.add() }
                Button("Add") { list.add() }
                    .disabled(!list.canAdd)
            }
            if let problem = list.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Add/edit form for a single `ConnectionProfile`.
struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var vpnURL: String
    @State private var routes: EditableList
    @State private var dnsServers: EditableList
    @State private var dnsDomains: EditableList
    @State private var onDemandDomains: EditableList
    @State private var post: String
    @State private var noDefaultRoute: Bool
    @State private var debug: Bool

    private let profileID: UUID
    @State private var savedLogin: String?
    @State private var pinnedCertHash: String?
    private let onSave: (ConnectionProfile) -> Void
    /// Captured once from the profile this sheet was opened with, so the
    /// title doesn't flip from "Add" to "Edit" as soon as a name is typed.
    private let isNew: Bool

    /// Takes a concrete profile (never optional) so this view always has a
    /// distinct identity per profile when presented via `.sheet(item:)` —
    /// with `.sheet(isPresented:)` + an optional profile, SwiftUI could
    /// reuse this view's already-initialized `@State` storage across
    /// presentations instead of re-seeding it from a new profile, showing
    /// stale/blank fields on the second and later edits.
    init(profile: ConnectionProfile, onSave: @escaping (ConnectionProfile) -> Void) {
        self.profileID = profile.id
        self._savedLogin = State(initialValue: profile.lastDSID)
        self._pinnedCertHash = State(initialValue: profile.pinnedCertHash)
        self.isNew = profile.name.isEmpty
        self._name = State(initialValue: profile.name)
        self._vpnURL = State(initialValue: profile.vpnURL)
        self._routes = State(initialValue: EditableList(
            items: profile.splitRouteList,
            isValid: ConnectionProfile.isValidRoute,
            invalidMessage: "Enter an IP address or a CIDR range, e.g. 169.237.0.0/16 or 10.1.2.3."))
        self._dnsServers = State(initialValue: EditableList(
            items: profile.dnsServerList,
            isValid: ConnectionProfile.isValidAddress,
            invalidMessage: "Enter the IP address of a DNS server, e.g. 169.237.250.250."))
        self._dnsDomains = State(initialValue: EditableList(
            items: profile.dnsDomainList,
            isValid: ConnectionProfile.isValidDomain,
            invalidMessage: "Enter a domain name, e.g. example.edu or *.example.edu."))
        self._onDemandDomains = State(initialValue: EditableList(
            items: profile.onDemandDomainList,
            isValid: ConnectionProfile.isValidDomain,
            invalidMessage: "Enter a domain name, e.g. example.edu or *.example.edu."))
        self._post = State(initialValue: profile.post ?? "")
        self._noDefaultRoute = State(initialValue: profile.noDefaultRoute)
        self._debug = State(initialValue: profile.debug)
        self.onSave = onSave
    }

    /// A sheet has no navigation/toolbar chrome of its own on macOS, so the
    /// title and the Cancel/Save pair are laid out explicitly here rather
    /// than left to `.toolbar { ToolbarItem(placement: .confirmationAction) }`,
    /// which had nowhere to render and left the sheet with no way out but
    /// Escape.
    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Connection" : "Edit Connection")
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Form {
                Section("Connection") {
                    TextField("Name", text: $name, prompt: Text("e.g. coe"))
                    TextField("VPN URL", text: $vpnURL, prompt: Text("https://vpn.example.edu"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                }
                ListSection(
                    title: "Routes",
                    prompt: "169.237.0.0/16 or 10.1.2.3",
                    footer: routes.items.isEmpty
                        ? "No routes: all traffic goes through the VPN (or the server's routes, if chosen below)."
                        : "Only these destinations go through the VPN.",
                    list: $routes
                )
                ListSection(
                    title: "DNS Servers",
                    prompt: "169.237.250.250",
                    footer: dnsServers.items.isEmpty
                        ? "No servers: the VPN server's own DNS servers are used."
                        : "Used instead of the DNS servers the VPN server provides.",
                    list: $dnsServers
                )
                ListSection(
                    title: "DNS Domains",
                    prompt: "example.edu or *.example.edu",
                    footer: dnsDomains.items.isEmpty
                        ? "No domains: the VPN's DNS answers everything when all traffic goes through it, otherwise only the domains the server names."
                        : "Only names in these domains, and their subdomains, are looked up through the VPN's DNS.",
                    list: $dnsDomains
                )
                ListSection(
                    title: "Connect on Demand",
                    prompt: "example.edu or *.example.edu",
                    footer: onDemandDomains.items.isEmpty
                        ? "No domains: the VPN only connects when you ask it to."
                        : "Looking up a name in these domains, or their subdomains, connects the VPN when the name can't be resolved without it. OpenConnect Menu must be running to sign in. Disconnecting turns this off until you connect again or restart the app.",
                    list: $onDemandDomains
                )
                Section("Advanced") {
                    TextField("Post-connect command", text: $post, prompt: Text("none"))
                    Toggle("Use the server's routes instead of sending all traffic", isOn: $noDefaultRoute)
                    Toggle("Verbose logging", isOn: $debug)
                    if let login = savedLogin, !login.isEmpty {
                        LabeledContent("Saved login") {
                            HStack {
                                Text("reused on the next connect")
                                    .foregroundStyle(.secondary)
                                Button("Clear") { savedLogin = nil }
                            }
                        }
                    }
                    if let pinnedCertHash {
                        LabeledContent("Trusted certificate") {
                            HStack {
                                Text(pinnedCertHash)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Button("Forget") { self.pinnedCertHash = nil }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider().opacity(0.5)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(
                        ConnectionProfile(
                            id: profileID,
                            name: name.isEmpty ? "Untitled" : name,
                            vpnURL: vpnURL,
                            splitRoutes: routes.saved,
                            dnsServers: dnsServers.saved,
                            dnsDomains: dnsDomains.saved,
                            onDemandDomains: onDemandDomains.saved,
                            post: post.isEmpty ? nil : post,
                            noDefaultRoute: noDefaultRoute,
                            debug: debug,
                            lastDSID: savedLogin,
                            pinnedCertHash: pinnedCertHash
                        )
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || vpnURL.isEmpty || hasInvalidEntry)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 640)
        .background(.ultraThinMaterial)
    }

    /// Something typed in one of the add fields can't be saved as it is.
    private var hasInvalidEntry: Bool {
        routes.problem != nil || dnsServers.problem != nil || dnsDomains.problem != nil
            || onDemandDomains.problem != nil
    }
}
