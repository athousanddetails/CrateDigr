import SwiftUI

@main
struct CrateDigrApp: App {
    @StateObject private var downloadManager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }

                SamplerTabView()
                    .tabItem {
                        Label("Sampler", systemImage: "waveform")
                    }

                StemsTabView()
                    .tabItem {
                        Label("Stems", systemImage: "scissors")
                    }
            }
            .environmentObject(downloadManager)
            .onAppear {
                downloadManager.cleanupOrphanedTempFiles()
            }
        }
        .defaultSize(width: 1100, height: 700)

        Settings {
            SettingsView()
        }
    }
}
