import SwiftUI

/// Add/edit form for a single `ConnectionProfile`.
struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var vpnURL: String
    @State private var script: String
    @State private var post: String
    @State private var noDefaultRoute: Bool
    @State private var debug: Bool

    private let profileID: UUID
    private let existingDSID: String?
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
        self.isNew = profile.name.isEmpty
        self._name = State(initialValue: profile.name)
        self._vpnURL = State(initialValue: profile.vpnURL)
        self._script = State(initialValue: profile.script ?? "")
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
                Section("Advanced") {
                    TextField("vpnc script (openconnect -s)", text: $script, prompt: Text("vpn-slice …"))
                    TextField("Post-connect command", text: $post, prompt: Text("none"))
                    Toggle("Don't replace the default route", isOn: $noDefaultRoute)
                    Toggle("Verbose openconnect logging", isOn: $debug)
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
                            script: script.isEmpty ? nil : script,
                            post: post.isEmpty ? nil : post,
                            noDefaultRoute: noDefaultRoute,
                            debug: debug,
                            lastDSID: existingDSID
                        )
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || vpnURL.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 420)
        .background(.ultraThinMaterial)
    }
}
