import SwiftUI

struct StemsTabView: View {
    @StateObject private var vm = StemsViewModel()

    var body: some View {
        NavigationSplitView {
            StemsBrowserSidebar()
                .environmentObject(vm)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Group {
                if vm.stems.isEmpty {
                    StemsEmptyStateView()
                        .environmentObject(vm)
                } else {
                    StemMixerView()
                        .environmentObject(vm)
                }
            }
        }
        .navigationTitle("Stems")
    }
}
