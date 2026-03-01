import SwiftUI
import UniformTypeIdentifiers

struct StemsEmptyStateView: View {
    @EnvironmentObject var vm: StemsViewModel
    @State private var isDragOver = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if let url = vm.sourceFileURL {
                // File loaded — show separation controls
                fileLoadedView(url: url)
            } else {
                // No file — show drop zone
                dropZoneView
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
    }

    private var dropZoneView: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 60))
                .foregroundStyle(isDragOver ? Color.blue : Color.gray.opacity(0.3))

            Text("AI Stem Separation")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Separate any audio into vocals, drums, bass, and other instruments")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: { vm.selectFile() }) {
                Label("Choose Audio File", systemImage: "folder")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("or drag and drop an audio file here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDragOver ? Color.blue : Color.gray.opacity(0.2),
                    style: StrokeStyle(lineWidth: 2, dash: isDragOver ? [] : [8])
                )
        )
        .frame(maxWidth: 500)
    }

    private func fileLoadedView(url: URL) -> some View {
        VStack(spacing: 16) {
            // File info
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.sourceFilename)
                        .fontWeight(.medium)
                    Text(url.pathExtension.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Change") { vm.selectFile() }
                    .controlSize(.small)
            }
            .padding()
            .background(Color.blue.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 500)

            // Model info
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                Text("HT Demucs v4 — 4 stems (vocals, drums, bass, other)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Separation button or progress
            if vm.isSeparating {
                separationProgressView
            } else {
                Button(action: { vm.startSeparation() }) {
                    Label("Separate Stems", systemImage: "scissors")
                        .fontWeight(.semibold)
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // Show error message if separation failed
            if !vm.isSeparating && vm.statusMessage.hasPrefix("Error:") {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Separation Failed")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.red)
                    }
                    Text(vm.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 500)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var separationProgressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: vm.separationProgress)
                .frame(maxWidth: 400)

            Text(vm.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Cancel") { vm.cancelSeparation() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let audioExtensions = ["wav", "mp3", "aiff", "aif", "flac", "m4a", "ogg", "webm"]
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { return }

                Task { @MainActor in
                    vm.loadFile(url)
                }
            }
        }
        return true
    }
}
