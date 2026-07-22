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

    /// Takes a concrete profile (never optional) so this view always has a
    /// distinct identity per profile when presented via `.sheet(item:)` —
    /// with `.sheet(isPresented:)` + an optional profile, SwiftUI could
    /// reuse this view's already-initialized `@State` storage across
    /// presentations instead of re-seeding it from a new profile, showing
    /// stale/blank fields on the second and later edits.
    init(profile: ConnectionProfile, onSave: @escaping (ConnectionProfile) -> Void) {
        self.profileID = profile.id
        self.existingDSID = profile.lastDSID
        self._name = State(initialValue: profile.name)
        self._vpnURL = State(initialValue: profile.vpnURL)
        self._script = State(initialValue: profile.script ?? "")
        self._post = State(initialValue: profile.post ?? "")
        self._noDefaultRoute = State(initialValue: profile.noDefaultRoute)
        self._debug = State(initialValue: profile.debug)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Name", text: $name)
                TextField("VPN URL", text: $vpnURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
            }
            Section("Advanced") {
                TextField("vpnc script (openconnect -s)", text: $script)
                TextField("Post-connect command", text: $post)
                Toggle("Don't replace the default route", isOn: $noDefaultRoute)
                Toggle("Verbose openconnect logging", isOn: $debug)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
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
                .disabled(name.isEmpty || vpnURL.isEmpty)
            }
        }
    }
}
