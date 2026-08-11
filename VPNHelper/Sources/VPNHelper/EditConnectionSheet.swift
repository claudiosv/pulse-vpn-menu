import SwiftUI

/// Add / Edit sheet. Edits a local copy so Cancel discards changes;
/// Save hands the finished connection back to the caller.
struct EditConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: VPNConnection
    let onSave: (VPNConnection) -> Void

    private var isNew: Bool { draft.name.isEmpty && draft.url.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Connection" : "Edit Connection")
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)

            Form {
                Section("Connection") {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. coe"))
                    TextField("VPN URL", text: $draft.url, prompt: Text("https://vpn.example.edu"))
                }
                Section("Advanced") {
                    TextField("vpnc script", text: $draft.vpncScript, prompt: Text("vpn-slice …"))
                    TextField("Post-connect command", text: $draft.postConnect, prompt: Text("none"))
                    Toggle("Don't replace the default route", isOn: $draft.noDefaultRoute)
                    Toggle("Verbose openconnect logging", isOn: $draft.verboseLogging)
                }
            }
            .formStyle(.grouped)

            Divider().opacity(0.5)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 520)
        .background(.ultraThinMaterial)
    }
}
