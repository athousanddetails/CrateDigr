import SwiftUI

struct LoFiPanel: View {
    @EnvironmentObject var vm: SamplerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with real-time toggle
            HStack {
                Text("Lo-Fi Processing")
                    .font(.headline)
                Spacer()
                Toggle(isOn: Binding(
                    get: { vm.lofiEnabled },
                    set: { _ in vm.toggleLoFi() }
                )) {
                    HStack(spacing: 4) {
                        Image(systemName: vm.lofiEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                            .font(.caption)
                        Text(vm.lofiEnabled ? "Preview ON" : "Preview OFF")
                            .font(.caption.weight(.semibold))
                    }
                }
                .toggleStyle(.switch)
                .tint(.orange)
                .help("Toggle real-time lo-fi preview on playback")
            }

            if vm.lofiEnabled {
                Text("Real-time preview — adjust sliders to hear changes live")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            // Presets
            VStack(alignment: .leading, spacing: 6) {
                Text("Presets")
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    ForEach(LoFiProcessor.LoFiPreset.all, id: \.name) { preset in
                        Button(preset.name) {
                            vm.applyLoFiPreset(preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Apply \(preset.name) lo-fi preset")
                    }
                }
            }

            Divider()

            // Bit Crusher
            HStack {
                Text("Bit Depth")
                    .fontWeight(.medium)
                    .frame(width: 90, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(vm.lofiBitDepth) },
                    set: {
                        vm.lofiBitDepth = Int($0)
                        vm.lofiParameterChanged()
                    }
                ), in: 4...16, step: 1)
                .help("Reduce bit depth for crunchy digital distortion")
                Text("\(vm.lofiBitDepth)-bit")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 45, alignment: .trailing)
            }

            // Sample Rate Reducer
            HStack {
                Text("Sample Rate")
                    .fontWeight(.medium)
                    .frame(width: 90, alignment: .leading)
                Slider(value: Binding(
                    get: { vm.lofiSampleRate },
                    set: {
                        vm.lofiSampleRate = $0
                        vm.lofiParameterChanged()
                    }
                ), in: 4000...44100, step: 1000)
                .help("Lower sample rate for aliased, retro sound")
                Text("\(Int(vm.lofiSampleRate))Hz")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }

            // Tape Saturation
            HStack {
                Text("Saturation")
                    .fontWeight(.medium)
                    .frame(width: 90, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(vm.lofiDrive) },
                    set: {
                        vm.lofiDrive = Float($0)
                        vm.lofiParameterChanged()
                    }
                ), in: 0...1, step: 0.05)
                .help("Tape-style saturation and warmth")
                Text(String(format: "%.0f%%", vm.lofiDrive * 100))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 45, alignment: .trailing)
            }

            // Vinyl Crackle
            HStack {
                Text("Vinyl Crackle")
                    .fontWeight(.medium)
                    .frame(width: 90, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(vm.lofiCrackle) },
                    set: {
                        vm.lofiCrackle = Float($0)
                        vm.lofiParameterChanged()
                    }
                ), in: 0...1, step: 0.05)
                .help("Add vinyl surface noise and crackle")
                Text(String(format: "%.0f%%", vm.lofiCrackle * 100))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 45, alignment: .trailing)
            }

            // Wow/Flutter
            HStack {
                Text("Wow/Flutter")
                    .fontWeight(.medium)
                    .frame(width: 90, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(vm.lofiWowFlutter) },
                    set: {
                        vm.lofiWowFlutter = Float($0)
                        vm.lofiParameterChanged()
                    }
                ), in: 0...1, step: 0.05)
                .help("Tape wow and flutter — pitch wobble effect")
                Text(String(format: "%.0f%%", vm.lofiWowFlutter * 100))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 45, alignment: .trailing)
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button(action: { vm.applyLoFiDestructive() }) {
                    Label("Bake In", systemImage: "wand.and.stars")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(vm.sampleFile == nil)
                .help("Apply lo-fi effects permanently to the sample")

                if vm.canUndoLoFi {
                    Button(action: { vm.undoLoFi() }) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .help("Undo last bake-in and restore original audio")
                }
            }

            Text("Preview lets you hear effects in real-time. 'Bake In' applies permanently. Export can optionally include lo-fi effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
