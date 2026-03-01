import SwiftUI

struct MPCPadsView: View {
    @EnvironmentObject var vm: SamplerViewModel
    @State private var activePad: Int? = nil

    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    // Keyboard mapping: asdfghjk for pads 1-8, zxcvbnm, for pads 9-16
    static let padKeys: [Character] = ["a","s","d","f","g","h","j","k","z","x","c","v","b","n","m",","]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("MPC Pads")
                    .font(.headline)
                Spacer()
                Text("\(min(vm.sliceMarkers.count, 16)) slices assigned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Pad options
            HStack(spacing: 16) {
                Toggle(isOn: $vm.padMuteOthers) {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.slash")
                        Text("Mute others")
                            .font(.caption)
                    }
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 4) {
                    Text("Length:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $vm.padPlayLength) {
                        ForEach(PadPlayLength.allCases) { length in
                            Text(length.rawValue).tag(length)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
            }

            // 4x4 Pad Grid
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<16, id: \.self) { index in
                    PadButton(
                        index: index,
                        isActive: activePad == index,
                        hasSlice: index < vm.sliceMarkers.count,
                        keyLabel: String(Self.padKeys[index]).uppercased()
                    ) {
                        triggerPad(index)
                    }
                }
            }
            .frame(maxWidth: 400)

            Text("Keys: ASDFGHJK (1-8) / ZXCVBNM, (9-16)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            // Pattern Sequencer
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pattern Sequencer")
                        .fontWeight(.medium)

                    Spacer()

                    Button(action: { vm.drumPattern.clearAll() }) {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // 16-step grid for first 4 pads (compact view)
                let activePads = min(vm.sliceMarkers.count, 4)
                ForEach(0..<activePads, id: \.self) { padIdx in
                    HStack(spacing: 2) {
                        Text("P\(padIdx + 1)")
                            .font(.caption2)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)

                        ForEach(0..<16, id: \.self) { step in
                            Rectangle()
                                .fill(vm.drumPattern.steps[padIdx][step] ? Color.orange : Color.gray.opacity(0.2))
                                .frame(height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .overlay(
                                    vm.patternPlaying && vm.currentStep == step ?
                                    RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 1) : nil
                                )
                                .onTapGesture {
                                    vm.drumPattern.toggleStep(pad: padIdx, step: step)
                                }
                        }
                    }
                }

                if activePads == 0 {
                    Text("Add slices to use the sequencer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding()
        .background(KeyboardPadListener(onKeyPress: { char in
            if let idx = Self.padKeys.firstIndex(of: char), idx < vm.sliceMarkers.count {
                triggerPad(idx)
            }
        }))
    }

    private func triggerPad(_ index: Int) {
        guard index < vm.sliceMarkers.count else { return }
        activePad = index
        vm.triggerPad(index)

        // Reset highlight after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if activePad == index { activePad = nil }
        }
    }
}

struct PadButton: View {
    let index: Int
    let isActive: Bool
    let hasSlice: Bool
    var keyLabel: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(padColor)
                    .frame(height: 60)

                VStack(spacing: 2) {
                    Text("\(index + 1)")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundColor(hasSlice ? .white : .gray)
                    if !keyLabel.isEmpty {
                        Text(keyLabel)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(hasSlice ? .white.opacity(0.6) : .gray.opacity(0.4))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasSlice)
    }

    private var padColor: Color {
        if isActive { return .orange }
        if hasSlice { return Color.gray.opacity(0.4) }
        return Color.gray.opacity(0.15)
    }
}

// NSView-based keyboard listener for pad triggering
struct KeyboardPadListener: NSViewRepresentable {
    let onKeyPress: (Character) -> Void

    func makeNSView(context: Context) -> KeyListenerNSView {
        let view = KeyListenerNSView()
        view.onKeyPress = onKeyPress
        return view
    }

    func updateNSView(_ nsView: KeyListenerNSView, context: Context) {
        nsView.onKeyPress = onKeyPress
    }
}

class KeyListenerNSView: NSView {
    var onKeyPress: ((Character) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.characters?.lowercased(), let char = chars.first else {
            super.keyDown(with: event)
            return
        }
        if MPCPadsView.padKeys.contains(char) {
            onKeyPress?(char)
        } else {
            super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
