import SwiftUI

struct OutputFolderPicker: View {
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output Folder")
                .font(.headline)

            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)

                Text(downloadManager.outputFolder.path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Choose...") {
                    chooseFolder()
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadManager.outputFolder

        if panel.runModal() == .OK, let url = panel.url {
            downloadManager.setOutputFolder(url)
        }
    }
}
