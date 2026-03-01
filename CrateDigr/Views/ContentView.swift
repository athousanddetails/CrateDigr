import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            NewDownloadView()
        }
        .navigationTitle("Crate Digr")
        .frame(minWidth: 800, minHeight: 500)
        .onDrop(of: [.plainText, .url], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.blue, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                    .background(.blue.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, URLValidator.isValidYouTubeURL(url.absoluteString) {
                        Task { @MainActor in
                            downloadManager.addDownload(
                                url: url.absoluteString,
                                format: .wav,
                                settings: AudioSettings()
                            )
                        }
                    }
                }
                return true
            }

            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text, URLValidator.isValidYouTubeURL(text) {
                        Task { @MainActor in
                            downloadManager.addDownload(
                                url: text,
                                format: .wav,
                                settings: AudioSettings()
                            )
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}
