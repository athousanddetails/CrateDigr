import SwiftUI

struct StemsBrowserSidebar: View {
    @EnvironmentObject var vm: StemsViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Folder picker
            HStack {
                Button(action: chooseFolder) {
                    Label("Browse", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(action: { vm.refreshFileList() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh file list")
            }
            .padding(8)

            // Current folder path
            Text(vm.browserFolder.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            Divider()

            // File list
            if vm.audioFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("No audio files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Choose a folder with audio files")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.audioFiles, id: \.self, selection: $vm.selectedBrowserFile) { url in
                    StemFileRow(url: url, isSelected: vm.selectedBrowserFile == url)
                }
                .listStyle(.sidebar)
                .onChange(of: vm.selectedBrowserFile) { _, newURL in
                    if let url = newURL {
                        vm.loadFile(url)
                    }
                }
            }

            Divider()

            // Separation status
            if vm.isSeparating {
                VStack(spacing: 6) {
                    ProgressView(value: vm.separationProgress)
                    Text(vm.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(10)
                .background(.bar)
            } else if let url = vm.sourceFileURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    HStack {
                        Text(url.pathExtension.uppercased())
                        if !vm.stems.isEmpty {
                            Text("•").foregroundStyle(.tertiary)
                            Text("\(vm.stems.count) stems")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.bar)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = vm.browserFolder

        if panel.runModal() == .OK, let url = panel.url {
            vm.setBrowserFolder(url)
        }
    }
}

struct StemFileRow: View {
    let url: URL
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                Text(url.pathExtension.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
