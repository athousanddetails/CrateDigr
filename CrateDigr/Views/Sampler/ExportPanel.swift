import SwiftUI
import UniformTypeIdentifiers

struct ExportPanel: View {
    @EnvironmentObject var vm: SamplerViewModel

    @State private var exportMode: ExportMode = .loop
    @State private var sampleRate: Int = 48000
    @State private var bitDepth: Int = 16
    @State private var maxDuration: Double = 66
    @State private var enforceMaxDuration = false
    @State private var mono = false
    @State private var zeroCrossing = true
    @State private var normalize = false
    @State private var includeLoFi = false
    @State private var includeTempoEffects = true
    enum ExportMode: String, CaseIterable, Identifiable {
        case loop = "Loop Region"
        case full = "Full File"
        case slices = "Slices"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.headline)

            // Export mode
            Picker("Mode", selection: $exportMode) {
                ForEach(ExportMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Show loop bar range when loop mode is selected
            if exportMode == .loop {
                if let rangeStr = vm.loopBarRangeString {
                    HStack(spacing: 6) {
                        Image(systemName: "repeat")
                            .foregroundStyle(.green)
                        Text(rangeStr)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if vm.loopRegion == nil {
                    Text("No loop region set — use ⌘L to create one")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // Duration info
                if let region = vm.loopRegion, let sf = vm.sampleFile {
                    let durationSec = Double(region.length) / sf.sampleRate
                    Text("Duration: \(String(format: "%.2f", durationSec))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Hardware Presets
            VStack(alignment: .leading, spacing: 6) {
                Text("Hardware Presets")
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Button(action: applyDigitaktPreset) {
                        VStack(spacing: 2) {
                            Text("Digitakt II")
                                .font(.caption.weight(.semibold))
                            Text("48k / 16-bit / 66s")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(action: applyMPCPreset) {
                        VStack(spacing: 2) {
                            Text("MPC")
                                .font(.caption.weight(.semibold))
                            Text("44.1k / 16-bit")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(action: applySP404Preset) {
                        VStack(spacing: 2) {
                            Text("SP-404")
                                .font(.caption.weight(.semibold))
                            Text("44.1k / 16-bit / 16s")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Format settings
            HStack {
                Text("Sample Rate")
                    .fontWeight(.medium)
                Spacer()
                Picker("Sample Rate", selection: $sampleRate) {
                    Text("44.1 kHz").tag(44100)
                    Text("48 kHz").tag(48000)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            HStack {
                Text("Bit Depth")
                    .fontWeight(.medium)
                Spacer()
                Picker("Bit Depth", selection: $bitDepth) {
                    Text("16-bit").tag(16)
                    Text("24-bit").tag(24)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            HStack {
                Toggle("Mono", isOn: $mono)
                Spacer()
                Toggle("Zero Crossing", isOn: $zeroCrossing)
            }

            // Normalize option
            Toggle(isOn: $normalize) {
                HStack {
                    Text("Normalize")
                    Text("— peak level to 0dB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if exportMode == .slices {
                HStack {
                    Toggle("Max Duration", isOn: $enforceMaxDuration)
                    if enforceMaxDuration {
                        TextField("seconds", value: $maxDuration, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("s")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Effects inclusion
            VStack(alignment: .leading, spacing: 6) {
                Text("Include Effects")
                    .fontWeight(.medium)
                Toggle(isOn: $includeTempoEffects) {
                    HStack {
                        Text("Pitch / Speed")
                        if vm.speed != 1.0 || vm.pitchSemitones != 0 {
                            Text("(\(pitchSpeedSummary))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(isOn: $includeLoFi) {
                    HStack {
                        Text("Lo-Fi FX")
                        if vm.lofiEnabled {
                            Text("(active)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Divider()

            // Export button
            HStack {
                Button(action: { performExport() }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.sampleFile == nil || vm.isExporting)
                .disabled(exportMode == .slices && vm.sliceMarkers.isEmpty)
                .disabled(exportMode == .loop && vm.loopRegion == nil)

                if vm.isExporting {
                    ProgressView(value: vm.exportProgress)
                        .frame(width: 100)
                    Text("\(Int(vm.exportProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Status
            if exportMode == .slices {
                Text("\(vm.sliceMarkers.count) slices to export")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Resample / Bounce-in-Place
            VStack(alignment: .leading, spacing: 8) {
                Text("Resample (Bounce)")
                    .fontWeight(.medium)
                Text("Renders current playback with all effects (EQ, pitch, speed) baked into a new WAV file")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: { vm.resample() }) {
                    Label("Resample", systemImage: "arrow.triangle.2.circlepath.circle")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(vm.sampleFile == nil || vm.isExporting)

                if vm.loopEnabled && vm.loopRegion != nil {
                    Text("Will resample loop region only")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding()
    }

    private func applyDigitaktPreset() {
        sampleRate = 48000
        bitDepth = 16
        mono = false
        enforceMaxDuration = true
        maxDuration = 66
        zeroCrossing = true
        normalize = true
    }

    private func applyMPCPreset() {
        sampleRate = 44100
        bitDepth = 16
        mono = false
        enforceMaxDuration = false
        zeroCrossing = true
        normalize = true
    }

    private func applySP404Preset() {
        sampleRate = 44100
        bitDepth = 16
        mono = false
        enforceMaxDuration = true
        maxDuration = 16
        zeroCrossing = true
        normalize = true
    }

    private func buildOptions() -> SampleExporter.ExportOptions {
        var options = SampleExporter.ExportOptions()
        options.format = .wav(sampleRate: sampleRate, bitDepth: bitDepth)
        options.zeroCrossing = zeroCrossing
        options.mono = mono
        options.normalize = normalize

        if includeTempoEffects {
            options.speedRatio = vm.speed
            options.pitchSemitones = vm.pitchSemitones
            options.pitchSpeedMode = vm.pitchSpeedMode
            options.eqLow = vm.eqLow
            options.eqMid = vm.eqMid
            options.eqHigh = vm.eqHigh
        }

        if includeLoFi && vm.lofiEnabled {
            options.lofi = SampleExporter.LoFiOptions(
                bitDepth: vm.lofiBitDepth,
                targetSampleRate: vm.lofiSampleRate,
                drive: vm.lofiDrive,
                crackle: vm.lofiCrackle,
                wowFlutter: vm.lofiWowFlutter
            )
        }

        if enforceMaxDuration {
            options.maxDuration = maxDuration
        }

        return options
    }

    private var pitchSpeedSummary: String {
        let pct = (vm.speed - 1.0) * 100.0
        switch vm.pitchSpeedMode {
        case .turntable:
            return String(format: "%+.0f%% Repitch", pct)
        case .independent:
            var parts: [String] = []
            if vm.speed != 1.0 { parts.append(String(format: "%+.0f%% Speed", pct)) }
            if vm.pitchSemitones != 0 { parts.append(String(format: "%+.0fst Pitch", vm.pitchSemitones)) }
            return parts.joined(separator: ", ")
        default:
            var parts: [String] = []
            if vm.speed != 1.0 { parts.append(String(format: "%+.0f%% Speed", pct)) }
            if vm.pitchSemitones != 0 { parts.append(String(format: "%+.0fst Pitch", vm.pitchSemitones)) }
            return parts.joined(separator: ", ")
        }
    }

    private func suggestedFilename() -> String {
        guard let sf = vm.sampleFile else { return "export" }
        let bpmTag = effectiveBPMTag()

        switch exportMode {
        case .full:
            return "\(sf.filename)_\(bpmTag)"
        case .loop:
            return "\(sf.filename)_loop_\(bpmTag)"
        case .slices:
            return "\(sf.filename)_\(bpmTag)"
        }
    }

    private func effectiveBPMTag() -> String {
        guard let bpm = vm.sampleFile?.bpm, bpm > 0 else { return "" }
        let eBPM = Int(round(Double(bpm) * vm.speed))
        return "\(eBPM)bpm"
    }

    private func performExport() {
        let options = buildOptions()

        let panel = NSSavePanel()
        panel.title = "Export"
        panel.nameFieldStringValue = suggestedFilename() + ".wav"
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch exportMode {
        case .full:
            vm.exportFull(options: options, outputURL: url)
        case .loop:
            vm.exportLoopRegion(options: options, outputURL: url)
        case .slices:
            let baseName = url.deletingPathExtension().lastPathComponent
            let outputDir = url.deletingLastPathComponent()
            vm.exportSlices(options: options, outputDir: outputDir, baseName: baseName)
        }
    }
}
