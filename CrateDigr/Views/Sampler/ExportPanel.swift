import SwiftUI
import UniformTypeIdentifiers

struct ExportPanel: View {
    @EnvironmentObject var vm: SamplerViewModel

    enum ExportMode: Int, CaseIterable, Identifiable {
        case loop = 0
        case full = 1
        case slices = 2

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .loop: return "Loop Region"
            case .full: return "Full File"
            case .slices: return "Slices"
            }
        }
    }

    private var exportMode: Binding<ExportMode> {
        Binding(
            get: { ExportMode(rawValue: vm.exportMode) ?? .loop },
            set: { vm.exportMode = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.headline)

            // Export mode
            Picker("Mode", selection: exportMode) {
                ForEach(ExportMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Export mode — Loop Region, Full File, or Slices")

            // Show loop bar range when loop mode is selected
            if exportMode.wrappedValue == .loop {
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
                    .help("Elektron Digitakt II — 48kHz, 16-bit, max 66s")

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
                    .help("Akai MPC — 44.1kHz, 16-bit")

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
                    .help("Roland SP-404 — 44.1kHz, 16-bit, max 16s")
                }
            }

            // Format settings
            HStack {
                Text("Sample Rate")
                    .fontWeight(.medium)
                Spacer()
                Picker("Sample Rate", selection: $vm.exportSampleRate) {
                    Text("44.1 kHz").tag(44100)
                    Text("48 kHz").tag(48000)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("Output sample rate")
            }

            HStack {
                Text("Bit Depth")
                    .fontWeight(.medium)
                Spacer()
                Picker("Bit Depth", selection: $vm.exportBitDepth) {
                    Text("16-bit").tag(16)
                    Text("24-bit").tag(24)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("Output bit depth — 16-bit for hardware samplers, 24-bit for DAWs")
            }

            HStack {
                Toggle("Mono", isOn: $vm.exportMono)
                    .help("Mix down to mono")
                Spacer()
                Toggle("Zero Crossing", isOn: $vm.exportZeroCrossing)
                    .help("Snap export boundaries to zero-crossings to avoid clicks")
            }

            // Normalize option
            Toggle(isOn: $vm.exportNormalize) {
                HStack {
                    Text("Normalize")
                    Text("— peak level to 0dB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help("Normalize peak level to 0 dB for maximum loudness")

            if exportMode.wrappedValue == .slices {
                HStack {
                    Toggle("Max Duration", isOn: $vm.exportEnforceMaxDuration)
                        .help("Truncate slices longer than the specified duration")
                    if vm.exportEnforceMaxDuration {
                        TextField("seconds", value: $vm.exportMaxDuration, format: .number)
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
                Toggle(isOn: $vm.exportIncludeTempoEffects) {
                    HStack {
                        Text("Pitch / Speed / EQ")
                        if vm.speed != 1.0 || vm.pitchSemitones != 0 {
                            Text("(\(pitchSpeedSummary))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .help("Include pitch/speed/EQ/pan/M-S changes in the exported file")
                Toggle(isOn: $vm.exportIncludeLoFi) {
                    HStack {
                        Text("Lo-Fi FX")
                        if vm.lofiEnabled {
                            Text("(active)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .help("Include lo-fi effects in the exported file")
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
                .disabled(exportMode.wrappedValue == .slices && vm.sliceMarkers.isEmpty)
                .disabled(exportMode.wrappedValue == .loop && vm.loopRegion == nil)
                .help("Export audio to WAV file")

                if vm.isExporting {
                    ProgressView(value: vm.exportProgress)
                        .frame(width: 100)
                    Text("\(Int(vm.exportProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Status
            if exportMode.wrappedValue == .slices {
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
                .help("Render playback with all effects baked into a new WAV")

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
        vm.exportSampleRate = 48000
        vm.exportBitDepth = 16
        vm.exportMono = false
        vm.exportEnforceMaxDuration = true
        vm.exportMaxDuration = 66
        vm.exportZeroCrossing = true
        vm.exportNormalize = true
    }

    private func applyMPCPreset() {
        vm.exportSampleRate = 44100
        vm.exportBitDepth = 16
        vm.exportMono = false
        vm.exportEnforceMaxDuration = false
        vm.exportZeroCrossing = true
        vm.exportNormalize = true
    }

    private func applySP404Preset() {
        vm.exportSampleRate = 44100
        vm.exportBitDepth = 16
        vm.exportMono = false
        vm.exportEnforceMaxDuration = true
        vm.exportMaxDuration = 16
        vm.exportZeroCrossing = true
        vm.exportNormalize = true
    }

    private func buildOptions() -> SampleExporter.ExportOptions {
        var options = SampleExporter.ExportOptions()
        options.format = .wav(sampleRate: vm.exportSampleRate, bitDepth: vm.exportBitDepth)
        options.zeroCrossing = vm.exportZeroCrossing
        options.mono = vm.exportMono
        options.normalize = vm.exportNormalize

        if vm.exportIncludeTempoEffects {
            options.speedRatio = vm.speed
            options.pitchSemitones = vm.pitchSemitones
            options.pitchSpeedMode = vm.pitchSpeedMode
            options.eqLow = vm.eqLow
            options.eqMid = vm.eqMid
            options.eqHigh = vm.eqHigh
            options.pan = vm.pan
            options.midGain = vm.midGain
            options.sideGain = vm.sideGain
            options.msCrossover = vm.msCrossover
        }

        if vm.exportIncludeLoFi && vm.lofiEnabled {
            options.lofi = SampleExporter.LoFiOptions(
                bitDepth: vm.lofiBitDepth,
                targetSampleRate: vm.lofiSampleRate,
                drive: vm.lofiDrive,
                crackle: vm.lofiCrackle,
                wowFlutter: vm.lofiWowFlutter
            )
        }

        if vm.exportEnforceMaxDuration {
            options.maxDuration = vm.exportMaxDuration
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

        switch exportMode.wrappedValue {
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

        switch exportMode.wrappedValue {
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
