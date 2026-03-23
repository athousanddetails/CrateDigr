import SwiftUI

struct StemMixerView: View {
    @EnvironmentObject var vm: StemsViewModel
    @EnvironmentObject var samplerVM: SamplerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // TOP: Waveform editor for selected stem(s)
            if samplerVM.sampleFile != nil {
                WaveformView()
                    .environmentObject(samplerVM)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                TransportBar()
                    .environmentObject(samplerVM)

                Divider()
            }

            // MIDDLE: Header + Stem mixer rows (compact, no scroll needed for 4-6 rows)
            headerBar

            VStack(spacing: 2) {
                ForEach(vm.stems) { stem in
                    StemTrackRow(
                        stem: stem,
                        isSelected: vm.selectedStemIDs.contains(stem.id)
                    )
                    .environmentObject(vm)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            Divider()

            // BOTTOM: Tool panel selector + content (flush, no dead space)
            if samplerVM.sampleFile != nil {
                HStack(spacing: 4) {
                    ForEach(SamplerToolPanel.allCases) { panel in
                        let isSelected = samplerVM.activePanel == panel
                        Button(action: { samplerVM.activePanel = panel }) {
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
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(.bar)

                Divider()

                ScrollView {
                    Group {
                        switch samplerVM.activePanel {
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
                    .environmentObject(samplerVM)
                }
            }
        }
        .onChange(of: vm.selectedStemIDs) { _, newIDs in
            guard !newIDs.isEmpty else { return }
            vm.loadSelectedStemsIntoSampler(samplerVM: samplerVM)
        }
        .onChange(of: vm.stems.count) { _, newCount in
            if newCount > 0, vm.selectedStemIDs.isEmpty {
                if let first = vm.stems.first {
                    vm.selectedStemIDs = [first.id]
                }
            }
        }
        .onAppear {
            // Auto-select first stem if stems exist but none selected
            if !vm.stems.isEmpty, vm.selectedStemIDs.isEmpty {
                if let first = vm.stems.first {
                    vm.selectedStemIDs = [first.id]
                }
            }
            // If stems selected but samplerVM has no file, load them
            if !vm.selectedStemIDs.isEmpty, samplerVM.sampleFile == nil {
                vm.loadSelectedStemsIntoSampler(samplerVM: samplerVM)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.sourceFilename)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text("\(vm.stems.count) stems separated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if vm.selectedStemIDs.count > 1 {
                        Text("• \(vm.selectedStemIDs.count) selected (mixed)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            Button(action: { vm.exportAllStems() }) {
                Label("Export All", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: { vm.newSeparation() }) {
                Label("New", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
