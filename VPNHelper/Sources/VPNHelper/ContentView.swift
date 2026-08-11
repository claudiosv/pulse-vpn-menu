import SwiftUI

/// Main window: hidden title bar, segmented tab picker, and the active tab.
struct ContentView: View {
    @EnvironmentObject var store: VPNStore
    @State private var editing: VPNConnection?
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            Group {
                switch store.selectedTab {
                case .status:      StatusView()
                case .connections: ConnectionsView(onEdit: startEdit, onAdd: startAdd)
                case .general:     GeneralView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showEditor) {
            EditConnectionSheet(draft: editing ?? VPNConnection(name: "", url: "")) { saved in
                store.upsert(saved)
            }
        }
    }

    private var header: some View {
        ZStack {
            // Segmented tab control, centered
            Picker("", selection: $store.selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack {
                Spacer()
                Text("VPN Helper")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0)   // reserves layout; real title is the traffic-light row
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func startEdit(_ c: VPNConnection) {
        editing = c
        showEditor = true
    }

    private func startAdd() {
        editing = VPNConnection(name: "", url: "")
        showEditor = true
    }
}
