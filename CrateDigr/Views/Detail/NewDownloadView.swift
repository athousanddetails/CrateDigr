import SwiftUI

struct NewDownloadView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var urlText = ""
    @State private var format: AudioFormat = .wav
    @State private var settings = AudioSettings()
    @State private var showInvalidURLAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Download")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Paste a YouTube URL to download audio")
                        .foregroundStyle(.secondary)
                }

                // URL Input
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("YouTube URLs")
                            .font(.headline)
                        Spacer()
                        if urlLineCount > 1 {
                            Text("\(urlLineCount) URLs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $urlText)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(4)

                        if urlText.isEmpty {
                            Text("Paste one or more YouTube URLs, one per line...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 40, maxHeight: urlEditorHeight)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.gray.opacity(0.3))
                    )

                    HStack(spacing: 12) {
                        Button(action: addToQueue) {
                            Label("Add to Queue", systemImage: "plus.circle")
                                .fontWeight(.medium)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(urlFieldEmpty)
                        .disabled(!downloadManager.binariesAvailable)

                        Button(action: startDownload) {
                            Label("Download Now", systemImage: "arrow.down.circle.fill")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(urlFieldEmpty)
                        .disabled(!downloadManager.binariesAvailable)

                        Spacer()

                        if !urlFieldEmpty {
                            Button(action: { urlText = "" }) {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // Format & Quality
                FormatPickerView(format: $format, settings: $settings)

                Divider()

                // Output folder
                OutputFolderPicker()

                Divider()

                // yt-dlp Log Viewer
                ytdlpLogViewer

                Spacer()
            }
            .padding(24)
        }
        .alert("Invalid URL", isPresented: $showInvalidURLAlert) {
            Button("OK") {}
        } message: {
            Text("Please enter a valid YouTube URL.")
        }
        .alert("Binaries Missing", isPresented: .constant(downloadManager.binaryError != nil && !downloadManager.binariesAvailable)) {
            Button("OK") {}
        } message: {
            Text(downloadManager.binaryError ?? "yt-dlp or ffmpeg binaries are missing from the app bundle.")
        }
    }

    /// The most relevant download to show logs for (active first, then most recent error/done)
    private var logSourceItem: DownloadItem? {
        downloadManager.items.first(where: { $0.status.isActive && !$0.logLines.isEmpty })
        ?? downloadManager.items.first(where: { !$0.logLines.isEmpty })
    }

    private var ytdlpLogViewer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("yt-dlp Log")
                    .font(.headline)
                Spacer()
                if let item = logSourceItem {
                    Text(item.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let item = logSourceItem {
                            ForEach(Array(item.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(logLineColor(line))
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        } else {
                            Text("No download activity yet")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.gray.opacity(0.2))
                )
                .onChange(of: logSourceItem?.logLines.count) { _, _ in
                    if let count = logSourceItem?.logLines.count, count > 0 {
                        withAnimation {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logLineColor(_ line: String) -> Color {
        if line.contains("ERROR") || line.contains("error") || line.contains("[timeout]") {
            return .red
        } else if line.contains("WARNING") || line.contains("warning") {
            return .orange
        }
        return .primary.opacity(0.8)
    }

    private var urlFieldEmpty: Bool {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Number of non-empty URL lines
    private var urlLineCount: Int {
        urlText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    /// Dynamic height: single line when empty, grows with content up to a max
    private var urlEditorHeight: CGFloat {
        let lineCount = max(1, urlText.components(separatedBy: .newlines).count)
        let lineHeight: CGFloat = 20
        let padding: CGFloat = 12
        let calculated = CGFloat(lineCount) * lineHeight + padding
        return min(max(calculated, 40), 160)  // Min 40, max 160 (about 7 lines)
    }

    private func parseURLs() -> [String]? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let urls = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let validURLs = urls.filter { URLValidator.isValidYouTubeURL($0) }

        if validURLs.isEmpty {
            showInvalidURLAlert = true
            return nil
        }
        return validURLs
    }

    private func startDownload() {
        guard let urls = parseURLs() else { return }
        downloadManager.addDownloads(urls: urls, format: format, settings: settings)
        urlText = ""
    }

    private func addToQueue() {
        guard let urls = parseURLs() else { return }
        downloadManager.addMultipleToQueue(urls: urls, format: format, settings: settings)
        urlText = ""
    }
}
