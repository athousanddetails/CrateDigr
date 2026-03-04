import SwiftUI

enum ChopMode: String, CaseIterable, Identifiable {
    case transient = "Transient"
    case grid = "Grid"
    case manual = "Manual"
    var id: String { rawValue }
}

struct ChopPanel: View {
    @EnvironmentObject var vm: SamplerViewModel
    @State private var chopMode: ChopMode = .transient

    private let barOptions: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Slice count + clear
            HStack {
                Text("Slices: \(vm.sliceMarkers.count)")
                    .font(.headline)
                Spacer()
                Button("Clear All") { vm.clearSlices() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.sliceMarkers.isEmpty)
                    .help("Remove all slice markers")
            }

            // Mode selector
            Picker("Chop Mode", selection: $chopMode) {
                ForEach(ChopMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Transient: auto-detect hits — Grid: even bar splits — Manual: click to place")

            Divider()

            // Mode-specific controls
            switch chopMode {
            case .transient:
                transientControls
            case .grid:
                gridControls
            case .manual:
                manualControls
            }
        }
        .padding()
    }

    // MARK: - Transient Mode

    private var transientControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transient Detection")
                .fontWeight(.medium)

            HStack {
                Text("Sensitivity")
                    .foregroundStyle(.secondary)
                Slider(value: $vm.chopSensitivity, in: 0...1, step: 0.05)
                    .help("Lower = more slices, Higher = fewer slices")
                Text(vm.chopSensitivity < 0.3 ? "Many" : vm.chopSensitivity > 0.7 ? "Few" : "Medium")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 50)
            }

            Button(action: { vm.autoChop() }) {
                Label("Detect Transients", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(vm.sampleFile == nil)
            .help("Scan audio for transients and place slice markers")

            Text("Detects attack transients in the audio and places slice markers at zero-crossings")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Grid Mode

    private var gridControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grid Chop (by Bars)")
                .fontWeight(.medium)

            HStack(spacing: 8) {
                ForEach(barOptions, id: \.self) { bars in
                    Button(barLabel(bars)) {
                        vm.gridChop(bars: bars)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.sampleFile == nil || vm.sampleFile?.bpm == nil)
                    .help("Chop into \(barLabel(bars)) slices")
                }
            }

            Text("Slices evenly by bar length, snapped to zero-crossings")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Manual Mode

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Manual Chop")
                .fontWeight(.medium)
            Text("Double-click on the waveform to add a slice marker")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Markers snap to nearest zero-crossing automatically")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func barLabel(_ bars: Double) -> String {
        if bars < 1 {
            let fraction = bars == 0.25 ? "1/4" : "1/2"
            return fraction
        }
        return "\(Int(bars)) bar\(bars > 1 ? "s" : "")"
    }
}
