import SwiftUI

struct PitchSpeedPanel: View {
    @EnvironmentObject var vm: SamplerViewModel

    // turntableRange now lives in vm.turntableRange (persists across tab switches)

    // Crossover knob: logarithmic Hz → normalized 0..1
    private var crossoverKnobValue: Float {
        vm.msCrossover > 0
            ? Float(log2(Double(vm.msCrossover) / 20.0) / log2(1000.0))
            : 0
    }

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
                        .help(mode.description)
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
                        Picker("Range", selection: $vm.turntableRange) {
                            Text("±8%").tag(8.0)
                            Text("±16%").tag(16.0)
                            Text("±50%").tag(50.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .help("Pitch fader range — like the SL-1200 range switch")
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
                            let clamped = max(-vm.turntableRange, min(vm.turntableRange, newPct))
                            vm.updateSpeed(percentToSpeed(clamped))
                        }
                    ), in: -vm.turntableRange...vm.turntableRange, step: 0.1)
                    .help("Pitch fader — changes speed and pitch together like vinyl")

                    HStack {
                        Text("-\(String(format: "%.0f", vm.turntableRange))%").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("0%") {
                            vm.updateSpeed(1.0)
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .help("Reset to original speed")
                        Spacer()
                        Text("+\(String(format: "%.0f", vm.turntableRange))%").font(.caption2).foregroundStyle(.secondary)
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
                    .help("Playback speed — independent of pitch")
                    HStack {
                        Text("25%").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { vm.updateSpeed(1.0) }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .help("Reset speed to 100%")
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
                    .help("Pitch shift in semitones — independent of speed")
                    HStack {
                        Text("-24 st").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { vm.updatePitch(0) }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .help("Reset pitch to 0 semitones")
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

            // EQ / Mid·Side / Pan — consolidated knob strip
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("EQ / M·S / Pan")
                        .font(.headline)
                    Spacer()
                    Button("Reset All") { vm.resetAllEQPanMS() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .help("Reset EQ, Mid/Side, and Pan to defaults")
                }

                HStack(spacing: 6) {
                    // ── EQ ──
                    VStack(spacing: 4) {
                        Text("EQ")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            EQKnob(label: "LOW", value: vm.eqLow, color: .blue, onChange: { vm.updateEQLow($0) })
                            EQKnob(label: "MID", value: vm.eqMid, color: .orange, onChange: { vm.updateEQMid($0) })
                            EQKnob(label: "HI", value: vm.eqHigh, color: .white, onChange: { vm.updateEQHigh($0) })
                        }
                    }

                    Divider().frame(height: 56).padding(.horizontal, 4)

                    // ── Mid / Side ──
                    VStack(spacing: 4) {
                        Text("M / S")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            EQKnob(label: "M", value: vm.midGain, color: .cyan, onChange: { vm.updateMidGain($0) })
                            EQKnob(label: "S", value: vm.sideGain, color: .purple, onChange: { vm.updateSideGain($0) })
                            EQKnob(
                                label: "XOVR",
                                value: crossoverKnobValue,
                                color: .teal,
                                minValue: 0,
                                maxValue: 1,
                                sensitivity: 0.004,
                                formatValue: { _ in
                                    vm.msCrossover > 0 ? "\(Int(vm.msCrossover))" : "Off"
                                },
                                onChange: { newVal in
                                    if newVal <= 0.01 {
                                        vm.updateMsCrossover(0)
                                    } else {
                                        vm.updateMsCrossover(Float(20.0 * pow(1000.0, Double(max(0, min(1, newVal))))))
                                    }
                                }
                            )
                        }
                    }

                    Divider().frame(height: 56).padding(.horizontal, 4)

                    // ── Pan ──
                    VStack(spacing: 4) {
                        Text("PAN")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        EQKnob(
                            label: "PAN",
                            value: vm.pan,
                            color: .green,
                            minValue: -1,
                            maxValue: 1,
                            sensitivity: 0.01,
                            formatValue: { v in
                                if abs(v) < 0.02 { return "C" }
                                else if v < 0 { return "\(Int(abs(v) * 100))L" }
                                else { return "\(Int(v * 100))R" }
                            },
                            onChange: { vm.updatePan($0) }
                        )
                    }
                }
                .padding(.vertical, 4)

                if (vm.midGain != 0 || vm.sideGain != 0),
                   let sf = vm.sampleFile, sf.channelCount == 1 {
                    Text("M/S has no effect — source file is mono")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
    var minValue: Float = -96
    var maxValue: Float = 12
    var sensitivity: Float = 0.5
    var formatValue: ((Float) -> String)? = nil
    let onChange: (Float) -> Void

    private let knobSize: CGFloat = 44
    // Rotation range: 270 degrees (-135 to +135 from top, 0° = noon)
    private let startAngle: Double = -135
    private let endAngle: Double = 135

    @State private var isDragging = false
    @State private var dragStartValue: Float = 0

    /// For bipolar knobs, 0 is ALWAYS at noon (0°). Left half = negative, right half = positive.
    /// For unipolar knobs, linear mapping from min to max across the full arc.
    private var isBipolar: Bool {
        minValue < 0 && maxValue > 0
    }

    private var rotationDegrees: Double {
        if isBipolar {
            // Bipolar: 0 at noon (0°), negative goes left, positive goes right
            if value >= 0 {
                // Map [0, maxValue] → [0°, endAngle]
                let frac = maxValue > 0 ? Double(value / maxValue) : 0
                return frac * endAngle
            } else {
                // Map [minValue, 0] → [startAngle, 0°]
                let frac = minValue < 0 ? Double(value / minValue) : 0
                return frac * startAngle
            }
        } else {
            guard maxValue > minValue else { return startAngle }
            let norm = Double((value - minValue) / (maxValue - minValue))
            return startAngle + norm * (endAngle - startAngle)
        }
    }

    /// Zero is always at noon (0°) for bipolar knobs
    private var zeroDegrees: Double { 0 }

    private var displayText: String {
        if let fmt = formatValue { return fmt(value) }
        if value <= minValue + 6 && minValue <= -90 { return "KILL" }
        return "\(value >= 0 ? "+" : "")\(String(format: "%.0f", value))"
    }

    private var arcColor: Color {
        if minValue <= -90 && value <= -90 { return .red }
        return color
    }

    var body: some View {
        VStack(spacing: 3) {
            // Knob
            ZStack {
                // Track ring (full 270° background)
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 2.5)
                    .frame(width: knobSize, height: knobSize)

                // Value arc: bipolar draws from center (0), unipolar from min
                if isBipolar {
                    // Center-zero: arc from noon outward (left for -, right for +)
                    let fromDeg = value >= 0 ? zeroDegrees : rotationDegrees
                    let toDeg = value >= 0 ? rotationDegrees : zeroDegrees
                    ArcShape(startAngle: fromDeg, endAngle: toDeg)
                        .stroke(arcColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: knobSize, height: knobSize)
                } else {
                    ArcShape(startAngle: startAngle, endAngle: rotationDegrees)
                        .stroke(arcColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: knobSize, height: knobSize)
                }

                // Knob body
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.30), Color(white: 0.14)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: knobSize - 8, height: knobSize - 8)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)

                // Pointer line
                Rectangle()
                    .fill(isDragging ? color : Color.white.opacity(0.9))
                    .frame(width: 1.5, height: knobSize / 2 - 8)
                    .offset(y: -(knobSize / 4 - 4))
                    .rotationEffect(.degrees(rotationDegrees))

                // Center dot
                Circle()
                    .fill(Color(white: 0.22))
                    .frame(width: 5, height: 5)
            }
            .frame(width: knobSize + 2, height: knobSize + 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                        }
                        let deltaY = Float(-drag.translation.height)

                        if isBipolar {
                            // Drag in normalized angular space [-1, 1] where 0 = noon.
                            // Same physical drag distance for full range on both sides.
                            // Negative side feel is preserved; positive becomes proportionally slower.
                            let absMin = abs(minValue)

                            // Convert start value to normalized position
                            let startNorm: Float = dragStartValue >= 0
                                ? (maxValue > 0 ? dragStartValue / maxValue : 0)
                                : (absMin > 0 ? dragStartValue / absMin : 0)

                            // Sensitivity scaled to normalized space (based on negative range)
                            let normSens = absMin > 0 ? sensitivity / absMin : sensitivity
                            let newNorm = max(-1, min(1, startNorm + deltaY * normSens))

                            // Convert back to value
                            let newValue = newNorm >= 0
                                ? newNorm * maxValue
                                : newNorm * absMin
                            onChange(max(minValue, min(maxValue, newValue)))
                        } else {
                            let newValue = dragStartValue + deltaY * sensitivity
                            onChange(max(minValue, min(maxValue, newValue)))
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                let resetValue: Float = (minValue < -10) ? 0 : (minValue + maxValue) / 2
                onChange(resetValue)
            }
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() }
                else { NSCursor.pop() }
            }
            .help("\(label) — drag up/down, double-click to reset")

            // Label + value
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
            Text(displayText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(
                    minValue <= -90 && value <= -90 ? .red :
                    (abs(value) < 0.1 ? .gray : .white)
                )
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
