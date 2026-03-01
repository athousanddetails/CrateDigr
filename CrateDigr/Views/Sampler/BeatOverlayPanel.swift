import SwiftUI

struct BeatOverlayPanel: View {
    @EnvironmentObject var vm: SamplerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // MARK: - Genre Filter
            HStack(spacing: 6) {
                ForEach(DrumLoopGenre.allCases) { genre in
                    Button(action: { vm.selectedBeatGenre = genre }) {
                        HStack(spacing: 4) {
                            Image(systemName: genre.icon)
                                .font(.caption2)
                            Text(genre.rawValue)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(vm.selectedBeatGenre == genre ? Color.blue : Color.gray.opacity(0.2))
                        .foregroundStyle(vm.selectedBeatGenre == genre ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // MARK: - Loop List
            let loops = vm.filteredDrumLoops
            if loops.isEmpty && vm.selectedBeatGenre != .user {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No loops for \(vm.selectedBeatGenre.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Add loops to DrumLoops folder or load your own")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(loops) { loop in
                        Button(action: { vm.selectDrumLoop(loop) }) {
                            HStack {
                                Image(systemName: vm.selectedDrumLoop?.id == loop.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(vm.selectedDrumLoop?.id == loop.id ? .blue : .secondary)
                                    .font(.body)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(loop.name)
                                        .font(.system(.body, design: .default))
                                        .lineLimit(1)
                                    if !loop.attribution.isEmpty {
                                        Text(loop.attribution)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Text("\(Int(loop.originalBPM)) BPM")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(vm.selectedDrumLoop?.id == loop.id ? Color.blue.opacity(0.08) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // User loop section
            if vm.selectedBeatGenre == .user {
                if vm.userDrumLoops.isEmpty {
                    Text("No user loops loaded yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                Button(action: addUserLoop) {
                    Label("Load Drum Loop", systemImage: "plus.circle")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // MARK: - Controls
            VStack(spacing: 12) {
                // Volume slider
                HStack {
                    Image(systemName: "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(vm.beatOverlayVolume) },
                        set: { vm.updateBeatOverlayVolume(Float($0)) }
                    ), in: 0...1)
                    Text("\(Int(vm.beatOverlayVolume * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }

                // Sync info
                if let loop = vm.selectedDrumLoop {
                    let rate = vm.effectiveBPM / loop.originalBPM
                    HStack {
                        Image(systemName: "metronome")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Loop: \(Int(loop.originalBPM)) BPM → \(Int(vm.effectiveBPM)) BPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("(\(String(format: "%.1f", rate))x)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Enable/Disable toggle
                Button(action: { vm.toggleBeatOverlay() }) {
                    HStack {
                        Image(systemName: vm.beatOverlayEnabled ? "stop.fill" : "play.fill")
                        Text(vm.beatOverlayEnabled ? "Beat Overlay ON" : "Enable Beat Overlay")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(vm.beatOverlayEnabled ? Color.blue : Color.gray.opacity(0.2))
                    .foregroundStyle(vm.beatOverlayEnabled ? .white : .primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(vm.selectedDrumLoop == nil)
            }
        }
        .padding()
    }

    private func addUserLoop() {
        let panel = NSOpenPanel()
        panel.title = "Choose Drum Loop"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            vm.addUserDrumLoop(url)
        }
    }
}
