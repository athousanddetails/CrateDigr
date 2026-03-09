import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var vm: SamplerViewModel

    var body: some View {
        HStack(spacing: 10) {
            // Play/Stop
            Button(action: { vm.togglePlayback() }) {
                Image(systemName: vm.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(vm.isPlaying ? "Stop (Space)" : "Play (Space)")

            // Time display
            Text(vm.currentTimeString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .leading)

            Text("/")
                .foregroundStyle(.secondary)

            Text(vm.durationString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Divider().frame(height: 20)

            // Loop controls
            HStack(spacing: 4) {
                Button(action: { vm.toggleLoop() }) {
                    Image(systemName: "repeat")
                        .foregroundStyle(vm.loopEnabled ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("l", modifiers: .command)
                .help("Toggle Loop (⌘L)")

                Picker("", selection: $vm.loopMode) {
                    Text("Free").tag(LoopMode.free)
                    Text("1/4").tag(LoopMode.bars(0.25))
                    Text("1/2").tag(LoopMode.bars(0.5))
                    Text("1 Bar").tag(LoopMode.bars(1))
                    Text("2 Bars").tag(LoopMode.bars(2))
                    Text("4 Bars").tag(LoopMode.bars(4))
                    Text("8 Bars").tag(LoopMode.bars(8))
                    Text("16 Bars").tag(LoopMode.bars(16))
                }
                .pickerStyle(.menu)
                .frame(width: 72)
                .help("Loop length — Free or snap to bar count")
                .onChange(of: vm.loopMode) { _, _ in
                    vm.applyLoopMode()
                }
            }

            // Focus mode
            if vm.isFocusMode {
                Button(action: { vm.exitFocusMode() }) {
                    Label("Return", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
                .help("Return to full track")
            } else if vm.loopRegion != nil {
                Button(action: {
                    // Enable loop if not already, then enter focus
                    if !vm.loopEnabled { vm.loopEnabled = true }
                    vm.enterFocusMode()
                }) {
                    Label("Focus", systemImage: "scope")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .controlSize(.small)
                .help("Focus on loop region for detailed editing")
            }

            Divider().frame(height: 20)

            // BPM - editable + tap tempo
            HStack(spacing: 4) {
                Image(systemName: "metronome")
                    .foregroundStyle(.secondary)

                BPMTextField(bpm: $vm.manualBPM, onCommit: { vm.applyManualBPM() })
                    .frame(width: 55)
                    .help("BPM — type a value and press Enter to set")

                Button(action: { vm.tapTempo() }) {
                    Text("TAP")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Tap tempo — tap rhythmically to set BPM")
            }

            // Key display
            if let key = vm.sampleFile?.keyDisplay {
                Text(key)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }

            Divider().frame(height: 20)

            // Grid nudge controls — BIGGER buttons, offset indicator
            if vm.sampleFile?.bpm != nil {
                HStack(spacing: 4) {
                    Text("Grid")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    RepeatButton(systemImage: "chevron.left", action: { vm.nudgeGridLeft() })
                        .help("Nudge grid left — hold to scroll")

                    // Show current offset in ms
                    if let sf = vm.sampleFile {
                        let offsetMs = Double(vm.gridOffsetSamples) / sf.sampleRate * 1000.0
                        Text(String(format: "%+.1f", offsetMs))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(vm.gridOffsetSamples != 0 ? .orange : .secondary)
                            .frame(width: 36, alignment: .center)
                    }

                    RepeatButton(systemImage: "chevron.right", action: { vm.nudgeGridRight() })
                        .help("Nudge grid right — hold to scroll")

                    Button(action: { vm.resetGrid() }) {
                        Text("R")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reset grid to auto-detected position")

                    Divider().frame(height: 16)

                    // Metronome toggle + volume
                    Button(action: { vm.toggleMetronome() }) {
                        Image(systemName: vm.metronomeEnabled ? "metronome.fill" : "metronome")
                            .font(.system(size: 13))
                            .foregroundStyle(vm.metronomeEnabled ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle metronome click")

                    if vm.metronomeEnabled {
                        Slider(value: $vm.metronomeVolume, in: 0.1...1.5, step: 0.05)
                            .frame(width: 50)
                            .help("Metronome volume")
                    }

                    Divider().frame(height: 16)

                    // Snap to grid toggle (playhead)
                    Button(action: { vm.snapToGrid.toggle() }) {
                        Image(systemName: "square.grid.3x3.topleft.filled")
                            .font(.system(size: 12))
                            .foregroundStyle(vm.snapToGrid ? .cyan : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(vm.snapToGrid ? "Snap to grid ON — playhead snaps to 16ths" : "Snap to grid OFF — free playhead")

                    // Snap to grid toggle (loop handles)
                    Button(action: { vm.loopSnapToGrid.toggle() }) {
                        Image(systemName: "repeat")
                            .font(.system(size: 10))
                            .foregroundStyle(vm.loopSnapToGrid ? .green : .secondary)
                            .overlay(
                                vm.loopSnapToGrid ?
                                Image(systemName: "square.grid.3x3.topleft.filled")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.green)
                                    .offset(x: 6, y: -5) : nil
                            )
                    }
                    .buttonStyle(.plain)
                    .help(vm.loopSnapToGrid ? "Loop snap ON — loop handles snap to 16ths" : "Loop snap OFF — free loop handles")
                }
            }

            Spacer()

            // Preview volume
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(vm.previewVolume) },
                    set: { vm.updatePreviewVolume(Float($0)) }
                ), in: 0...1.5, step: 0.05)
                    .frame(width: 55)
                    .help("Preview volume")
            }

            Divider().frame(height: 20)

            // Waveform / Spectrogram toggle
            Button(action: { vm.showSpectrogram.toggle(); vm.showStereoWaveform = false }) {
                Image(systemName: vm.showSpectrogram ? "chart.bar.xaxis" : "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(vm.showSpectrogram ? .cyan : .secondary)
            }
            .buttonStyle(.plain)
            .help(vm.showSpectrogram ? "Show Waveform" : "Show Spectrogram")

            // Stereo L/R waveform toggle
            Button(action: { vm.showStereoWaveform.toggle(); vm.showSpectrogram = false }) {
                Image(systemName: "rectangle.split.1x2")
                    .font(.system(size: 12))
                    .foregroundStyle(vm.showStereoWaveform ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help(vm.showStereoWaveform ? "Show mono waveform" : "Show stereo L/R waveform")

            // Zoom controls
            HStack(spacing: 4) {
                Button(action: { vm.zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(vm.waveformZoom <= 1)
                .help("Zoom out")

                // Draggable zoom value
                ZoomDragView(zoom: $vm.waveformZoom, offset: $vm.waveformOffset)
                    .frame(width: 40)

                Button(action: { vm.zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(vm.waveformZoom >= 100)
                .help("Zoom in")

                Button(action: { vm.zoomReset() }) {
                    Text("Fit")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Reset zoom to fit entire waveform")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// BPM text field with proper focus management:
// - Enter: commits value, loses focus
// - Escape: reverts to previous value, loses focus
// - Click outside: reverts to previous value, loses focus
// - Empty/invalid: reverts to previous value
struct BPMTextField: NSViewRepresentable {
    @Binding var bpm: Double
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.alignment = .center
        tf.isBordered = true
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.delegate = context.coordinator
        tf.stringValue = String(format: "%.0f", bpm)
        context.coordinator.textField = tf
        context.coordinator.savedValue = bpm
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Only update display if not currently editing
        if !context.coordinator.isEditing {
            nsView.stringValue = String(format: "%.0f", bpm)
            context.coordinator.savedValue = bpm
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(bpm: $bpm, onCommit: onCommit)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var bpm: Binding<Double>
        let onCommit: () -> Void
        var savedValue: Double = 120
        var isEditing = false
        weak var textField: NSTextField?

        init(bpm: Binding<Double>, onCommit: @escaping () -> Void) {
            self.bpm = bpm
            self.onCommit = onCommit
            self.savedValue = bpm.wrappedValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            savedValue = bpm.wrappedValue
            isEditing = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }

            let movementKey = obj.userInfo?["NSTextMovement"] as? Int

            if movementKey == NSReturnTextMovement {
                // User pressed Enter — commit the value
                if let val = Double(tf.stringValue), val > 20 && val < 400 {
                    bpm.wrappedValue = val
                    onCommit()
                } else {
                    // Invalid — revert
                    bpm.wrappedValue = savedValue
                    tf.stringValue = String(format: "%.0f", savedValue)
                }
            } else {
                // Lost focus by any other means (click outside, tab, etc.) — revert
                bpm.wrappedValue = savedValue
                tf.stringValue = String(format: "%.0f", savedValue)
            }

            isEditing = false

            // Ensure focus is fully removed from this field
            DispatchQueue.main.async {
                tf.window?.makeFirstResponder(tf.window?.contentView)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape pressed — revert and lose focus
                isEditing = false
                bpm.wrappedValue = savedValue
                if let tf = control as? NSTextField {
                    tf.stringValue = String(format: "%.0f", savedValue)
                    tf.abortEditing()
                    DispatchQueue.main.async {
                        tf.window?.makeFirstResponder(tf.window?.contentView)
                    }
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Enter pressed — commit and lose focus
                if let tf = control as? NSTextField {
                    if let val = Double(tf.stringValue), val > 20 && val < 400 {
                        bpm.wrappedValue = val
                        onCommit()
                    } else {
                        bpm.wrappedValue = savedValue
                        tf.stringValue = String(format: "%.0f", savedValue)
                    }
                    isEditing = false
                    tf.abortEditing()
                    DispatchQueue.main.async {
                        tf.window?.makeFirstResponder(tf.window?.contentView)
                    }
                }
                return true
            }
            return false
        }
    }
}

// Draggable zoom control — click and drag up/down to zoom, centered on playhead
struct ZoomDragView: View {
    @EnvironmentObject var vm: SamplerViewModel
    @Binding var zoom: CGFloat
    @Binding var offset: CGFloat
    @State private var isDragging = false

    var body: some View {
        Text("\(String(format: "%.1f", zoom))x")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(isDragging ? .primary : .secondary)
            .frame(width: 40, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        let delta = -value.translation.height * 0.02
                        let factor = 1.0 + delta
                        zoom = max(1, min(100, zoom * factor))
                        vm.centerOnPlayhead()
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .help("Drag up/down to zoom")
    }
}

// MARK: - Hold-to-Repeat Button

/// A button that fires once on tap and continuously while held down.
struct RepeatButton: View {
    let systemImage: String
    let action: () -> Void

    @State private var timer: Timer?
    @State private var isHolding = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .bold))
            .frame(width: 24, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHolding ? Color.gray.opacity(0.3) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        action()  // Fire immediately on press
                        let t = Timer(timeInterval: 0.05, repeats: true) { _ in
                            Task { @MainActor in action() }
                        }
                        // Must add to .common mode — during drag, RunLoop is in .tracking mode
                        RunLoop.current.add(t, forMode: .common)
                        timer = t
                    }
                    .onEnded { _ in
                        isHolding = false
                        timer?.invalidate()
                        timer = nil
                    }
            )
    }
}
