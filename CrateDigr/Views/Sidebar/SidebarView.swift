import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        Group {
            if downloadManager.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No Downloads")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Paste a YouTube URL to get started")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Download All bar — shown when there are queued items
                    if downloadManager.hasQueuedItems {
                        HStack {
                            let queuedCount = downloadManager.items.filter { $0.status == .queued }.count
                            Text("\(queuedCount) queued")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button(action: { downloadManager.downloadAll() }) {
                                Label("Download All", systemImage: "arrow.down.circle.fill")
                                    .fontWeight(.semibold)
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.bar)

                        Divider()
                    }

                    List {
                        ForEach(downloadManager.items) { item in
                            QueueItemRow(
                                item: item,
                                onCancel: { downloadManager.cancelDownload(id: item.id) },
                                onRetry: { downloadManager.retryDownload(id: item.id) },
                                onRemove: { downloadManager.removeItem(id: item.id) },
                                onReveal: { revealInFinder(item) }
                            )
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if !downloadManager.items.isEmpty {
                    Button(action: { downloadManager.clearCompleted() }) {
                        Label("Clear Completed", systemImage: "trash")
                    }
                    .help("Clear completed downloads")
                    .disabled(!downloadManager.items.contains { $0.status == .done })
                }
            }
        }
    }

    private func revealInFinder(_ item: DownloadItem) {
        if let url = item.outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
