import SwiftUI

struct PitchSpeedPanel: View {
    @EnvironmentObject var vm: SamplerViewModel

    // Turntable pitch range options (like SL-1200 range selector)
    @State private var turntableRange: Double = 8.0  // ±8%, ±16%, ±50%

    // Speed to percentage offset: speed 1.08 = +8%
    private func speedToPercent(_ speed: Double) -> Double {
        (speed - 1.0) * 100.0
    }

    // Percentage to speed: +8% = 1.08
    private func percentToSpeed(_ pct: Double) -> Double {
        1.0 + pct / 100.0
    }

    // Speed to semitones (for display)
    private func speedToSemitones(_ speed: Double) -> Double {
        guard speed > 0 else { return 0 }
        return 12.0 * log2(speed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Warp mode selector — Digitakt-style "machines"
            VStack(alignment: .leading, spacing: 6) {
                Text("Warp Mode")
                    .font(.headline)

                HStack(spacing: 4) {
                    ForEach(PitchSpeedMode.allCases) { mode in
                        let isSelected = vm.pitchSpeedMode == mode
                        Button(action: {
                            vm.pitchSpeedMode = mode
                            vm.engine.setMode(mode)
                        }) {
                            VStack(spacing: 2) {
                                Text(mode.shortLabel)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                Text(mode.displayName)
                                    .font(.system(size: 8))
                            }
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isSelected ? Color.blue : Color.gray.opacity(0.15))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(vm.pitchSpeedMode.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if vm.pitchSpeedMode == .turntable {
                // Turntable / Repitch mode
                // Turntable mode: Technics SL-1200 style pitch fader
                // Speed + pitch change together (like vinyl), measured in %
                VStack(alignment: .leading, spacing: 8) {
                    let currentPct = speedToPercent(vm.speed)
                    let currentSemitones = speedToSemitones(vm.speed)

                    // Range selector (like the SL-1200 range switch)
                    HStack {
                        Text("Range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Range", selection: $turntableRange) {
                            Text("±8%").tag(8.0)
                            Text("±16%").tag(16.0)
                            Text("±50%").tag(50.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    HStack {
                        Text("Tempo")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(currentPct >= 0 ? "+" : "")\(String(format: "%.1f", currentPct))%")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(abs(currentPct) < 0.05 ? .secondary : .primary)
                        Text("(\(currentSemitones >= 0 ? "+" : "")\(String(format: "%.1f", currentSemitones)) st)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    // Pitch fader — linear in percentage, like a real turntable
                    Slider(value: Binding(
                        get: { speedToPercent(vm.speed) },
                        set: { newPct in
                            let clamped = max(-turntableRange, min(turntableRange, newPct))
                            vm.updateSpeed(percentToSpeed(clamped))
                        }
                    ), in: -turntableRange...turntableRange, step: 0.1)

                    HStack {
                        Text("-\(String(format: "%.0f", turntableRange))%").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("0%") {
                            vm.updateSpeed(1.0)
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        Spacer()
                        Text("+\(String(format: "%.0f", turntableRange))%").font(.caption2).foregroundStyle(.secondary)
                    }

                    if let bpm = vm.sampleFile?.bpm {
                        HStack {
                            Text("Effective BPM:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(String(format: "%.1f", Double(bpm) * vm.speed))")
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                        }
                        .padding(.top, 4)
                    }
                }

            } else {
                // Independent mode: speed and pitch separate
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Speed")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(String(format: "%.0f", vm.speed * 100))%")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $vm.speed, in: 0.25...4.0, step: 0.01) { _ in
                        vm.updateSpeed(vm.speed)
                    }
                    HStack {
                        Text("25%").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { vm.updateSpeed(1.0) }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        Spacer()
                        Text("400%").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pitch")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(vm.pitchSemitones >= 0 ? "+" : "")\(String(format: "%.1f", vm.pitchSemitones)) st")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $vm.pitchSemitones, in: -24...24, step: 0.5) { _ in
                        vm.updatePitch(vm.pitchSemitones)
                    }
                    HStack {
                        Text("-24 st").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { vm.updatePitch(0) }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        Spacer()
                        Text("+24 st").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let bpm = vm.sampleFile?.bpm {
                    HStack {
                        Text("Effective BPM:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.1f", Double(bpm) * vm.speed))")
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                    }
                    .padding(.top, 4)
                }
            }

            Divider()

            // Target BPM
            HStack {
                Text("Target BPM")
                    .fontWeight(.medium)

                BPMTextField(bpm: $vm.targetBPM, onCommit: { vm.lockToBPM(vm.targetBPM) })
                    .frame(width: 80)

                Button(action: { vm.toggleBPMLock() }) {
                    Image(systemName: vm.bpmLocked ? "lock.fill" : "lock.open")
                        .foregroundStyle(vm.bpmLocked ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help(vm.bpmLocked ? "BPM locked — speed auto-adjusts" : "Lock to target BPM")

                if let originalBPM = vm.sampleFile?.bpm {
                    Text("Original: \(originalBPM)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // 3-Band EQ — Pioneer DJM-900 style potentiometers
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("3-Band EQ")
                        .font(.headline)
                    Spacer()
                    Button("Flat") { vm.resetEQ() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }

                // Horizontal layout like a real DJM-900 channel strip
                HStack(spacing: 24) {
                    Spacer()
                    EQKnob(label: "LOW", value: vm.eqLow, color: .blue) { vm.updateEQLow($0) }
                    EQKnob(label: "MID", value: vm.eqMid, color: .orange) { vm.updateEQMid($0) }
                    EQKnob(label: "HI", value: vm.eqHigh, color: .white) { vm.updateEQHigh($0) }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
    }
}

// MARK: - Rotary Potentiometer Knob (Pioneer DJM-900 style)

struct EQKnob: View {
    let label: String
    let value: Float
    let color: Color
    let onChange: (Float) -> Void

    private let knobSize: CGFloat = 48
    private let minValue: Float = -26
    private let maxValue: Float = 6
    // Rotation range: 270 degrees (-135 to +135 from top)
    private let startAngle: Double = -135
    private let endAngle: Double = 135

    @State private var isDragging = false
    @State private var dragStartValue: Float = 0

    private var normalizedValue: Double {
        Double((value - minValue) / (maxValue - minValue))
    }

    private var rotationDegrees: Double {
        startAngle + normalizedValue * (endAngle - startAngle)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)

            // Knob
            ZStack {
                // Outer ring / track
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                    .frame(width: knobSize, height: knobSize)

                // Value arc — shows how far the knob is turned
                ArcShape(startAngle: startAngle, endAngle: rotationDegrees)
                    .stroke(
                        value > 0 ? color : (value < -20 ? Color.red : color.opacity(0.6)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: knobSize, height: knobSize)

                // Knob body
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.35), Color(white: 0.15)],
                            center: .center,
                            startRadius: 0,
                            endRadius: knobSize / 2 - 4
                        )
                    )
                    .frame(width: knobSize - 8, height: knobSize - 8)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)

                // Indicator line
                Rectangle()
                    .fill(isDragging ? color : Color.white)
                    .frame(width: 2, height: knobSize / 2 - 8)
                    .offset(y: -(knobSize / 4 - 4))
                    .rotationEffect(.degrees(rotationDegrees))

                // Center dot
                Circle()
                    .fill(Color(white: 0.25))
                    .frame(width: 6, height: 6)
            }
            .frame(width: knobSize + 4, height: knobSize + 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                        }
                        // Drag up = increase, drag down = decrease
                        let deltaY = -drag.translation.height
                        let sensitivity: Float = 0.25 // dB per point
                        let newValue = dragStartValue + Float(deltaY) * sensitivity
                        let clamped = max(minValue, min(maxValue, newValue))
                        onChange(clamped)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                onChange(0) // Double-click resets to 0 dB
            }
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() }
                else { NSCursor.pop() }
            }

            // dB readout
            Text("\(value >= 0 ? "+" : "")\(String(format: "%.0f", value))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(abs(value) < 0.1 ? .gray : (value < -20 ? .red : .white))
        }
    }
}

// Arc shape for the value indicator around the knob
struct ArcShape: Shape {
    let startAngle: Double
    let endAngle: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // Convert from "0 = top" to SwiftUI's "0 = right" by subtracting 90
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startAngle - 90),
            endAngle: .degrees(endAngle - 90),
            clockwise: false
        )
        return path
    }
}
