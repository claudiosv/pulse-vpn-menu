import SwiftUI

/// Add/edit form for a single `ConnectionProfile`.
struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var vpnURL: String
    /// The "Only route" list: one address or CIDR range per entry.
    @State private var routes: [String]
    /// What is typed in the list's add field, not yet added.
    @State private var newRoute = ""
    @State private var post: String
    @State private var noDefaultRoute: Bool
    @State private var debug: Bool

    private let profileID: UUID
    private let existingDSID: String?
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
        self.existingDSID = profile.lastDSID
        self._pinnedCertHash = State(initialValue: profile.pinnedCertHash)
        self.isNew = profile.name.isEmpty
        self._name = State(initialValue: profile.name)
        self._vpnURL = State(initialValue: profile.vpnURL)
        self._routes = State(initialValue: profile.splitRouteList)
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
                Section {
                    ForEach(routes, id: \.self) { route in
                        HStack {
                            Text(route)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                routes.removeAll { $0 == route }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(route)")
                            .accessibilityLabel("Remove \(route)")
                        }
                    }
                    HStack {
                        TextField("Add route", text: $newRoute, prompt: Text("169.237.0.0/16 or 10.1.2.3"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .onSubmit(addRoute)
                        Button("Add", action: addRoute)
                            .disabled(!canAddRoute)
                    }
                    if let problem = newRouteProblem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Only Route")
                } footer: {
                    Text(routes.isEmpty
                        ? "No routes: all traffic goes through the VPN (or the server's routes, if chosen below)."
                        : "Only these destinations go through the VPN.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Advanced") {
                    TextField("Post-connect command", text: $post, prompt: Text("none"))
                    Toggle("Use the server's routes instead of sending all traffic", isOn: $noDefaultRoute)
                    Toggle("Verbose logging", isOn: $debug)
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
                            splitRoutes: savedRoutes.isEmpty ? nil : savedRoutes.joined(separator: ", "),
                            post: post.isEmpty ? nil : post,
                            noDefaultRoute: noDefaultRoute,
                            debug: debug,
                            lastDSID: existingDSID,
                            pinnedCertHash: pinnedCertHash
                        )
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || vpnURL.isEmpty || newRouteProblem != nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 560)
        .background(.ultraThinMaterial)
    }

    // MARK: - Routes

    private var trimmedNewRoute: String {
        newRoute.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the typed route can't be added, or nil if it can (or the field
    /// is empty).
    private var newRouteProblem: String? {
        let route = trimmedNewRoute
        if route.isEmpty { return nil }
        if !ConnectionProfile.isValidRoute(route) {
            return "Enter an IP address or a CIDR range, e.g. 169.237.0.0/16 or 10.1.2.3."
        }
        if routes.contains(route) { return "That route is already in the list." }
        return nil
    }

    private var canAddRoute: Bool {
        !trimmedNewRoute.isEmpty && newRouteProblem == nil
    }

    private func addRoute() {
        guard canAddRoute else { return }
        routes.append(trimmedNewRoute)
        newRoute = ""
    }

    /// The list as saved. A valid route still sitting in the add field
    /// counts, so clicking Save without clicking Add first doesn't lose it.
    private var savedRoutes: [String] {
        canAddRoute ? routes + [trimmedNewRoute] : routes
    }
}
