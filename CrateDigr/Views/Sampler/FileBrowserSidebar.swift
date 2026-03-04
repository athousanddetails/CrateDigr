import SwiftUI

struct FileBrowserSidebar: View {
    @EnvironmentObject var vm: SamplerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Folder picker
            HStack {
                Button(action: chooseFolder) {
                    Label("Browse", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Choose a folder with audio files")

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
                List(vm.audioFiles, id: \.self, selection: $vm.selectedFileURL) { url in
                    FileRow(url: url, isSelected: vm.selectedFileURL == url)
                        .contextMenu {
                            Button("Rename...") {
                                renameFile(url)
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            Button("Duplicate") {
                                duplicateFile(url)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                moveToTrash(url)
                            }
                        }
                }
                .listStyle(.sidebar)
                .onChange(of: vm.selectedFileURL) { _, newURL in
                    if let url = newURL {
                        vm.loadFile(url)
                    }
                }
            }

            Divider()

            // File info panel
            if let sf = vm.sampleFile {
                VStack(alignment: .leading, spacing: 6) {
                    Text(sf.filename)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    HStack {
                        if let bpm = sf.bpm {
                            InfoBadge(label: "\(bpm) BPM", color: .blue)
                        }
                        if let key = sf.keyDisplay {
                            InfoBadge(label: key, color: .purple)
                        }
                    }

                    HStack {
                        Text(sf.formattedDuration)
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(sf.sampleRateDisplay)
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(sf.fileExtension.uppercased())
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.bar)
            }
        }
    }

    private func renameFile(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = "Enter new name for \"\(url.deletingPathExtension().lastPathComponent)\""
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = url.deletingPathExtension().lastPathComponent
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            let ext = url.pathExtension
            let newURL = url.deletingLastPathComponent()
                .appendingPathComponent(newName)
                .appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: url, to: newURL)
                // If the renamed file was selected/loaded, update references
                if vm.selectedFileURL == url {
                    vm.selectedFileURL = newURL
                }
                vm.refreshFileList()
            } catch {
                let errAlert = NSAlert(error: error)
                errAlert.runModal()
            }
        }
    }

    private func duplicateFile(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var newURL = dir.appendingPathComponent("\(name)_copy").appendingPathExtension(ext)
        var counter = 1
        while FileManager.default.fileExists(atPath: newURL.path) {
            counter += 1
            newURL = dir.appendingPathComponent("\(name)_copy\(counter)").appendingPathExtension(ext)
        }
        do {
            try FileManager.default.copyItem(at: url, to: newURL)
            vm.refreshFileList()
        } catch {
            let errAlert = NSAlert(error: error)
            errAlert.runModal()
        }
    }

    private func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if vm.selectedFileURL == url {
                vm.selectedFileURL = nil
            }
            vm.refreshFileList()
        } catch {
            let errAlert = NSAlert(error: error)
            errAlert.runModal()
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

struct FileRow: View {
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

struct InfoBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
