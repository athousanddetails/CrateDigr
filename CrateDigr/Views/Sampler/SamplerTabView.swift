import SwiftUI

struct SamplerTabView: View {
    @StateObject private var vm = SamplerViewModel()

    var body: some View {
        NavigationSplitView {
            FileBrowserSidebar()
                .environmentObject(vm)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if vm.sampleFile != nil {
                    // Waveform
                    WaveformView()
                        .environmentObject(vm)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)

                    // Transport
                    TransportBar()
                        .environmentObject(vm)

                    Divider()

                    // Tool panel selector — button-style tabs
                    HStack(spacing: 4) {
                        ForEach(SamplerToolPanel.allCases) { panel in
                            let isSelected = vm.activePanel == panel
                            Button(action: { vm.activePanel = panel }) {
                                HStack(spacing: 5) {
                                    Image(systemName: panel.icon)
                                        .font(.system(size: 11))
                                    Text(panel.rawValue)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                }
                                .foregroundStyle(isSelected ? .white : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected ? Color.blue : Color.gray.opacity(0.15))
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(panelTooltip(panel))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(.bar)

                    Divider()

                    // Active panel content
                    ScrollView {
                        Group {
                            switch vm.activePanel {
                            case .pitchSpeed:
                                PitchSpeedPanel()
                            case .beat:
                                BeatOverlayPanel()
                            case .chop:
                                ChopPanel()
                            case .pads:
                                MPCPadsView()
                            case .keyboard:
                                ChromaticKeyboardView()
                            case .lofi:
                                LoFiPanel()
                            case .export:
                                ExportPanel()
                            }
                        }
                        .environmentObject(vm)
                    }

                } else {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 60))
                            .foregroundStyle(.tertiary)
                        Text("Select an audio file")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Choose a file from the sidebar to start sampling")
                            .font(.body)
                            .foregroundStyle(.tertiary)

                        if vm.isLoadingFile {
                            ProgressView("Loading...")
                                .padding(.top, 8)
                        }

                        if let error = vm.loadError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Sampler")
    }

    private func panelTooltip(_ panel: SamplerToolPanel) -> String {
        switch panel {
        case .pitchSpeed: return "Warp mode, speed, pitch, EQ controls"
        case .beat: return "Drum loop overlay synced to BPM"
        case .chop: return "Slice audio by transients, grid, or manually"
        case .pads: return "MPC-style pads for triggering slices"
        case .keyboard: return "Chromatic keyboard for pitched playback"
        case .lofi: return "Lo-fi effects — bit crush, vinyl, tape"
        case .export: return "Export audio as WAV with format options"
        }
    }
}
