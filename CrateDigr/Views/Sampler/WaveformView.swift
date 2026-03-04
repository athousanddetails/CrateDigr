import SwiftUI
import Combine

struct WaveformView: View {
    @EnvironmentObject var vm: SamplerViewModel

    // Refresh timer for playhead
    @State private var refreshTimer: Timer? = nil
    @State private var refreshTick: Int = 0

    // Drag-to-seek state (when zoom <= 4x)
    @State private var isDraggingSeek = false

    // Drag-to-scroll state (when zoomed > 4x)
    @State private var isDraggingScroll = false
    @State private var dragScrollStartOffset: CGFloat = 0

    // Store cursor position for zoom centering
    @State private var lastScrollCursorX: CGFloat = 0

    // Ruler drag-to-zoom state (Ableton style)
    @State private var isRulerDragging = false
    @State private var rulerDragStartZoom: CGFloat = 1.0

    // Waveform height resize
    @State private var resizeDragStartHeight: CGFloat = 180

    // Store view width for auto-follow
    @State private var currentViewWidth: CGFloat = 0

    // Loop bar drag-to-move state
    @State private var isDraggingLoopBar = false
    @State private var loopDragStartSample: Int = 0
    @State private var loopDragLength: Int = 0

    private let loopBracketHeight: CGFloat = 18
    private let loopBracketHandleWidth: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            // Top ruler bar (bar numbers + time) — Ableton style with beat subdivisions
            // Drag up/down on ruler to zoom (like Ableton)
            GeometryReader { geo in
                let _ = refreshTick
                Canvas { context, size in
                    drawRuler(context: context, size: size)
                }
                .frame(height: 28)
                .background(Color(white: 0.12))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if !isRulerDragging {
                                isRulerDragging = true
                                rulerDragStartZoom = vm.waveformZoom
                            }
                            // Drag up = zoom in, drag down = zoom out (like Ableton)
                            let deltaY = -(value.translation.height)
                            let factor = pow(2.0, deltaY / 80.0)
                            let newZoom = max(1, min(100, rulerDragStartZoom * factor))

                            // Zoom centered on the drag X position
                            if let sf = vm.sampleFile, sf.totalSamples > 0 {
                                let oldZoom = vm.waveformZoom
                                let cursorSample = xToSample(value.startLocation.x, width: geo.size.width)
                                let cursorFraction = CGFloat(cursorSample) / CGFloat(sf.totalSamples)

                                vm.waveformZoom = newZoom
                                let newOffset = cursorFraction * geo.size.width * newZoom - value.startLocation.x
                                let maxOffset = max(0, geo.size.width * newZoom - geo.size.width)
                                vm.waveformOffset = max(0, min(maxOffset, newOffset))
                            } else {
                                vm.waveformZoom = newZoom
                            }
                        }
                        .onEnded { _ in
                            isRulerDragging = false
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .frame(height: 28)

            // Loop bracket bar (only shown when loop is enabled)
            if vm.loopEnabled, vm.loopRegion != nil {
                GeometryReader { geo in
                    loopBracketOverlay(width: geo.size.width)
                }
                .frame(height: loopBracketHeight)
                .background(Color(white: 0.06))
            }

            // Focus mode indicator
            if vm.isFocusMode {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                        .font(.system(size: 9))
                    Text("FOCUS MODE")
                        .font(.system(size: 9, weight: .bold))
                    Text("— editing loop region")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Return") { vm.exitFocusMode() }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.08))
            }

            // Main waveform area
            GeometryReader { geo in
                let width = geo.size.width
                let _ = refreshTick // force redraw on tick
                let _ = updateViewWidth(width) // cache for auto-follow

                ZStack {
                    Color(white: 0.08)

                    Canvas { context, size in
                        drawGrid(context: context, size: size)
                        drawLoopRegion(context: context, size: size)
                        if vm.showSpectrogram {
                            drawSpectrogram(context: context, size: size)
                        } else {
                            drawWaveform(context: context, size: size)
                        }
                        drawSliceMarkers(context: context, size: size)
                        drawPlayhead(context: context, size: size)
                    }

                    // Center zero line
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 0.5)
                }
                .clipShape(Rectangle())
                .contentShape(Rectangle())
                // Click to seek (Option+Click to audition/scrub)
                .onTapGesture { location in
                    let sample = xToSample(location.x, width: width)
                    if NSEvent.modifierFlags.contains(.option) {
                        vm.engine.scrubPlay(from: sample, duration: 3.0)
                    } else {
                        vm.seekTo(sample)
                    }
                }
                // Drag gesture: seek when zoom<=4x, scroll when zoom>4x
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if NSEvent.modifierFlags.contains(.option) {
                                // Option+drag = scrub audition (short snippets)
                                let sample = xToSample(value.location.x, width: width)
                                vm.engine.scrubPlay(from: sample, duration: 3.0)
                            } else if vm.waveformZoom > 1.05 {
                                // Drag to scroll
                                if !isDraggingScroll {
                                    isDraggingScroll = true
                                    dragScrollStartOffset = vm.waveformOffset
                                }
                                let deltaX = value.startLocation.x - value.location.x
                                let maxOffset = max(0, width * vm.waveformZoom - width)
                                vm.waveformOffset = max(0, min(maxOffset, dragScrollStartOffset + deltaX))
                            } else {
                                // Drag to seek (smooth playhead scrub)
                                isDraggingSeek = true
                                let sample = xToSample(value.location.x, width: width)
                                vm.seekTo(sample)
                            }
                        }
                        .onEnded { _ in
                            isDraggingScroll = false
                            isDraggingSeek = false
                        }
                )
                .background(
                    ScrollWheelView { delta, hasPreciseDeltas, cursorX in
                        lastScrollCursorX = cursorX
                        handleScrollWheel(delta: delta, hasPreciseDeltas: hasPreciseDeltas, viewWidth: width, cursorX: cursorX)
                    }
                )
            }
            .frame(height: max(80, vm.waveformHeight))

            // Drag handle for vertical resizing
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: 40, height: 3)
                )
                .contentShape(Rectangle())
                .onAppear { resizeDragStartHeight = vm.waveformHeight }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let newHeight = resizeDragStartHeight + value.translation.height
                            vm.waveformHeight = max(80, min(500, newHeight))
                        }
                        .onEnded { _ in
                            resizeDragStartHeight = vm.waveformHeight
                        }
                )
                .onHover { hovering in
                    if hovering { NSCursor.resizeUpDown.push() }
                    else { NSCursor.pop() }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
        .onAppear {
            // 30fps refresh for playhead animation + auto-follow
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                Task { @MainActor in
                    refreshTick += 1
                    if vm.isPlaying {
                        vm.currentPosition = vm.engine.currentPosition
                        // Auto-follow: when zoomed in and playhead leaves the visible area, scroll to it
                        if vm.waveformZoom > 1.01 && currentViewWidth > 0 && !isDraggingScroll && !isDraggingSeek {
                            autoFollowPlayhead(viewWidth: currentViewWidth)
                        }
                    }
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Loop Bracket Overlay

    @ViewBuilder
    private func loopBracketOverlay(width: CGFloat) -> some View {
        if let region = vm.loopRegion, let sf = vm.sampleFile {
            let startX = sampleToX(region.startSample, totalSamples: sf.totalSamples, width: width)
            let endX = sampleToX(region.endSample, totalSamples: sf.totalSamples, width: width)
            let clampedStartX = max(0, min(width, startX))
            let clampedEndX = max(0, min(width, endX))

            ZStack(alignment: .leading) {
                // Full-width invisible drag layer for moving the entire loop bar.
                // Placed FIRST so handles (drawn later) take gesture priority in their area.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                // Only move if drag started inside the green bar (between handles)
                                let touchX = value.startLocation.x
                                let insetStart = clampedStartX + loopBracketHandleWidth
                                let insetEnd = clampedEndX - loopBracketHandleWidth
                                guard insetEnd > insetStart, touchX >= insetStart, touchX <= insetEnd else { return }

                                // Capture original loop position at drag start
                                if !isDraggingLoopBar {
                                    isDraggingLoopBar = true
                                    guard let currentRegion = vm.loopRegion else { return }
                                    loopDragStartSample = currentRegion.startSample
                                    loopDragLength = currentRegion.length
                                }

                                // Convert drag delta from pixels to samples
                                let currentSample = xToSample(value.location.x, width: width)
                                let dragOriginSample = xToSample(value.startLocation.x, width: width)
                                let deltaSamples = currentSample - dragOriginSample
                                var newStart = loopDragStartSample + deltaSamples

                                // Snap to grid if enabled
                                if vm.loopSnapToGrid {
                                    newStart = vm.snapSampleToGrid(newStart)
                                }

                                // Clamp to track bounds (preserve loop length)
                                newStart = max(0, min(sf.totalSamples - loopDragLength, newStart))
                                let newEnd = newStart + loopDragLength

                                vm.loopRegion = LoopRegion(startSample: newStart, endSample: newEnd)
                                vm.engine.updateLoopRegion(vm.loopRegion!)
                            }
                            .onEnded { _ in
                                guard isDraggingLoopBar else { return }
                                isDraggingLoopBar = false
                                // Apply zero-crossing snapping to final position
                                if let finalRegion = vm.loopRegion {
                                    vm.setLoopRegion(start: finalRegion.startSample, end: finalRegion.endSample)
                                }
                                // Reschedule gapless loop playback with snapped region
                                if vm.isPlaying && vm.loopEnabled, let finalRegion = vm.loopRegion {
                                    vm.engine.playRegion(finalRegion, loop: true)
                                }
                            }
                    )

                // Visual green bar (no gesture, just visual)
                if clampedEndX > clampedStartX {
                    Rectangle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: clampedEndX - clampedStartX, height: loopBracketHeight)
                        .offset(x: clampedStartX)
                        .allowsHitTesting(false)
                }

                // S and E handles — drawn last so they sit on top and their gestures take priority
                loopHandle(x: startX, isStart: true, width: width, sf: sf)
                loopHandle(x: endX, isStart: false, width: width, sf: sf)
            }
        }
    }

    @ViewBuilder
    private func loopHandle(x: CGFloat, isStart: Bool, width: CGFloat, sf: SampleFile) -> some View {
        let handleColor = Color.green
        let handleX = max(-loopBracketHandleWidth / 2, min(width + loopBracketHandleWidth / 2, x))

        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(handleColor.opacity(0.85))
                .frame(width: loopBracketHandleWidth, height: loopBracketHeight)
            Rectangle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 2, height: loopBracketHeight - 6)
            Text(isStart ? "S" : "E")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .offset(y: -1)
        }
        .offset(x: handleX - loopBracketHandleWidth / 2)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    var newSample = xToSample(value.location.x, width: width)
                    // Snap loop handle to grid if loop snap is enabled
                    if vm.loopSnapToGrid {
                        newSample = vm.snapSampleToGrid(newSample)
                    }
                    if isStart {
                        let endSample = vm.loopRegion?.endSample ?? sf.totalSamples
                        if newSample < endSample - 100 {
                            vm.loopRegion = LoopRegion(startSample: max(0, newSample), endSample: endSample)
                            // Update loop region without stopping playback — next iteration uses new bounds
                            vm.engine.updateLoopRegion(vm.loopRegion!)
                        }
                    } else {
                        let startSample = vm.loopRegion?.startSample ?? 0
                        if newSample > startSample + 100 {
                            vm.loopRegion = LoopRegion(startSample: startSample, endSample: min(sf.totalSamples, newSample))
                            // Update loop region without stopping playback
                            vm.engine.updateLoopRegion(vm.loopRegion!)
                        }
                    }
                }
                .onEnded { _ in
                    // Apply zero-crossing snapping to the final loop position
                    if let region = vm.loopRegion {
                        vm.setLoopRegion(start: region.startSample, end: region.endSample)
                    }
                    // Reschedule gapless loop playback with the snapped region
                    if vm.isPlaying && vm.loopEnabled, let region = vm.loopRegion {
                        vm.engine.playRegion(region, loop: true)
                    }
                }
        )
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() }
            else { NSCursor.pop() }
        }
    }

    // MARK: - Scroll Wheel Handler (zoom centers on cursor, not playhead)

    private func handleScrollWheel(delta: CGPoint, hasPreciseDeltas: Bool, viewWidth: CGFloat, cursorX: CGFloat) {
        if hasPreciseDeltas {
            // Trackpad: horizontal = pan, vertical = zoom
            if abs(delta.x) > abs(delta.y) * 0.5 {
                let scrollAmount = -delta.x * 2.0
                let maxOffset = max(0, viewWidth * vm.waveformZoom - viewWidth)
                vm.waveformOffset = max(0, min(maxOffset, vm.waveformOffset + scrollAmount))
            }
            if abs(delta.y) > abs(delta.x) * 0.5 {
                zoomAtCursor(deltaY: delta.y, factor: delta.y > 0 ? 0.96 : 1.04, viewWidth: viewWidth, cursorX: cursorX)
            }
        } else {
            // Mouse wheel
            if abs(delta.y) > abs(delta.x) {
                zoomAtCursor(deltaY: delta.y, factor: delta.y > 0 ? 0.85 : 1.18, viewWidth: viewWidth, cursorX: cursorX)
            } else {
                let scrollAmount = delta.x * 3.0
                let maxOffset = max(0, viewWidth * vm.waveformZoom - viewWidth)
                vm.waveformOffset = max(0, min(maxOffset, vm.waveformOffset + scrollAmount))
            }
        }
    }

    /// Zoom centered on cursor position (not playhead) — like Ableton
    private func zoomAtCursor(deltaY: CGFloat, factor: CGFloat, viewWidth: CGFloat, cursorX: CGFloat) {
        let oldZoom = vm.waveformZoom
        let newZoom = max(1, min(100, oldZoom * factor))

        guard let sf = vm.sampleFile, sf.totalSamples > 0 else {
            vm.waveformZoom = newZoom
            return
        }

        // The sample under the cursor should stay at the same screen position
        let cursorSample = xToSample(cursorX, width: viewWidth)
        let cursorFraction = CGFloat(cursorSample) / CGFloat(sf.totalSamples)

        vm.waveformZoom = newZoom
        // After zoom, the cursor sample should still be at cursorX
        let newOffset = cursorFraction * viewWidth * newZoom - cursorX
        let maxOffset = max(0, viewWidth * newZoom - viewWidth)
        vm.waveformOffset = max(0, min(maxOffset, newOffset))
    }

    // MARK: - Ruler Drawing (Ableton-style: Bar.Beat.Sixteenth)

    private func drawRuler(context: GraphicsContext, size: CGSize) {
        guard let sf = vm.sampleFile, sf.totalSamples > 0 else { return }

        if let bpm = sf.bpm, bpm > 0 {
            drawBarBeatRuler(context: context, size: size, sf: sf)
        } else {
            drawTimeRuler(context: context, size: size, sf: sf)
        }
    }

    private func drawBarBeatRuler(context: GraphicsContext, size: CGSize, sf: SampleFile) {
        guard let bpm = sf.bpm, bpm > 0 else { return }

        let gridOffset = Double(vm.gridOffsetSamples)
        // Use effective BPM (adjusted for speed) so grid reflects pitch/speed changes
        let effectiveBPM = Double(bpm) * vm.speed
        let samplesPerBeat = sf.sampleRate * 60.0 / effectiveBPM
        let samplesPerBar = samplesPerBeat * 4.0
        let samplesPerSixteenth = samplesPerBeat / 4.0

        // Pixel width of one bar
        let barPixelWidth = samplesPerBar / Double(sf.totalSamples) * Double(size.width) * Double(vm.waveformZoom)
        let beatPixelWidth = barPixelWidth / 4.0
        let sixteenthPixelWidth = beatPixelWidth / 4.0

        // Determine detail level based on zoom
        let showBeats = beatPixelWidth > 20
        let showSixteenths = sixteenthPixelWidth > 15

        var barPosition = gridOffset
        var barNum = 1

        while barPosition < Double(sf.totalSamples) {
            let barX = sampleToX(Int(barPosition), totalSamples: sf.totalSamples, width: size.width)

            // Draw bar marker
            if barX >= -50 && barX <= size.width + 50 {
                var tick = Path()
                tick.move(to: CGPoint(x: barX, y: size.height - 8))
                tick.addLine(to: CGPoint(x: barX, y: size.height))
                context.stroke(tick, with: .color(.gray.opacity(0.8)), lineWidth: 1)

                if showBeats {
                    // Show "Bar.Beat" format when zoomed to beats
                    let label = Text("\(barNum)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    context.draw(label, at: CGPoint(x: barX + 8, y: 8))
                } else {
                    let label = Text("\(barNum)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                    context.draw(label, at: CGPoint(x: barX + 10, y: size.height / 2))
                }
            }

            // Draw beat markers within this bar
            if showBeats {
                for beat in 1..<4 {
                    let beatPos = barPosition + Double(beat) * samplesPerBeat
                    let bx = sampleToX(Int(beatPos), totalSamples: sf.totalSamples, width: size.width)
                    if bx >= -20 && bx <= size.width + 20 {
                        var tick = Path()
                        tick.move(to: CGPoint(x: bx, y: size.height - 5))
                        tick.addLine(to: CGPoint(x: bx, y: size.height))
                        context.stroke(tick, with: .color(.gray.opacity(0.5)), lineWidth: 0.5)

                        // "Bar.Beat" label
                        let label = Text("\(barNum).\(beat + 1)")
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.7))
                        context.draw(label, at: CGPoint(x: bx + 10, y: 8))
                    }
                }
            }

            // Draw 16th subdivisions within beats
            if showSixteenths {
                for sixteenth in 0..<16 {
                    let beat = sixteenth / 4
                    let sub = sixteenth % 4
                    if sub == 0 { continue } // Already drawn as beat marker

                    let pos = barPosition + Double(sixteenth) * samplesPerSixteenth
                    let sx = sampleToX(Int(pos), totalSamples: sf.totalSamples, width: size.width)
                    if sx >= -10 && sx <= size.width + 10 {
                        var tick = Path()
                        tick.move(to: CGPoint(x: sx, y: size.height - 3))
                        tick.addLine(to: CGPoint(x: sx, y: size.height))
                        context.stroke(tick, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)

                        // Only label if really zoomed in
                        if sixteenthPixelWidth > 30 {
                            let label = Text("\(barNum).\(beat + 1).\(sub + 1)")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.5))
                            context.draw(label, at: CGPoint(x: sx + 12, y: 18))
                        }
                    }
                }
            }

            barPosition += samplesPerBar
            barNum += 1
        }

        // Bottom line
        var line = Path()
        line.move(to: CGPoint(x: 0, y: size.height - 0.5))
        line.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(line, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
    }

    private func drawTimeRuler(context: GraphicsContext, size: CGSize, sf: SampleFile) {
        let totalSeconds = sf.duration
        guard totalSeconds > 0 else { return }

        let visibleDuration = totalSeconds / Double(vm.waveformZoom)
        let interval: Double
        if visibleDuration > 120 { interval = 30 }
        else if visibleDuration > 60 { interval = 10 }
        else if visibleDuration > 20 { interval = 5 }
        else if visibleDuration > 5 { interval = 1 }
        else { interval = 0.5 }

        var t = 0.0
        while t <= totalSeconds {
            let sample = Int(t * sf.sampleRate)
            let x = sampleToX(sample, totalSamples: sf.totalSamples, width: size.width)

            if x >= -20 && x <= size.width + 20 {
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 6))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(.gray.opacity(0.6)), lineWidth: 1)

                let mins = Int(t) / 60
                let secs = t - Double(mins * 60)
                let label = mins > 0 ? String(format: "%d:%04.1f", mins, secs) : String(format: "%.1fs", secs)
                let text = Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
                context.draw(text, at: CGPoint(x: x + 14, y: size.height / 2))
            }
            t += interval
        }

        var line = Path()
        line.move(to: CGPoint(x: 0, y: size.height - 0.5))
        line.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(line, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
    }

    // MARK: - Grid Drawing

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        guard let sf = vm.sampleFile, let bpm = sf.bpm, bpm > 0 else { return }

        let gridOffset = Double(vm.gridOffsetSamples)
        // Use effective BPM (adjusted for speed) so grid reflects pitch/speed changes
        let effectiveBPM = Double(bpm) * vm.speed
        let samplesPerBeat = sf.sampleRate * 60.0 / effectiveBPM
        let samplesPerBar = samplesPerBeat * 4.0
        let barPixelWidth = samplesPerBar / Double(sf.totalSamples) * Double(size.width) * Double(vm.waveformZoom)

        // Grid offset indicator
        if vm.gridOffsetSamples != 0 {
            let offsetMs = Double(vm.gridOffsetSamples) / sf.sampleRate * 1000.0
            let label = Text(String(format: "Grid: %+.0fms", offsetMs))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(.orange)
            context.draw(label, at: CGPoint(x: 50, y: 10))
        }

        var barPosition = gridOffset
        while barPosition < Double(sf.totalSamples) {
            let x = sampleToX(Int(barPosition), totalSamples: sf.totalSamples, width: size.width)

            if x >= 0 && x <= size.width {
                var barLine = Path()
                barLine.move(to: CGPoint(x: x, y: 0))
                barLine.addLine(to: CGPoint(x: x, y: size.height))
                let gridColor = vm.gridOffsetSamples != 0
                    ? Color.orange.opacity(0.25)
                    : Color.white.opacity(0.12)
                context.stroke(barLine, with: .color(gridColor), lineWidth: 1)
            }

            if barPixelWidth > 60 {
                for beat in 1..<4 {
                    let beatPos = barPosition + Double(beat) * samplesPerBeat
                    let bx = sampleToX(Int(beatPos), totalSamples: sf.totalSamples, width: size.width)
                    if bx >= 0 && bx <= size.width {
                        var beatLine = Path()
                        beatLine.move(to: CGPoint(x: bx, y: 0))
                        beatLine.addLine(to: CGPoint(x: bx, y: size.height))
                        let beatColor = vm.gridOffsetSamples != 0
                            ? Color.orange.opacity(0.1)
                            : Color.white.opacity(0.06)
                        context.stroke(beatLine, with: .color(beatColor), lineWidth: 0.5)
                    }
                }
            }

            // 16th subdivision grid lines when zoomed far enough
            let sixteenthPixelWidth = barPixelWidth / 16.0
            if sixteenthPixelWidth > 12 {
                for s in 0..<16 {
                    if s % 4 == 0 { continue } // Skip beat lines already drawn
                    let subPos = barPosition + Double(s) * samplesPerBeat / 4.0
                    let sx = sampleToX(Int(subPos), totalSamples: sf.totalSamples, width: size.width)
                    if sx >= 0 && sx <= size.width {
                        var subLine = Path()
                        subLine.move(to: CGPoint(x: sx, y: 0))
                        subLine.addLine(to: CGPoint(x: sx, y: size.height))
                        context.stroke(subLine, with: .color(Color.white.opacity(0.03)), lineWidth: 0.5)
                    }
                }
            }

            barPosition += samplesPerBar
        }
    }

    // MARK: - Rekordbox 3-Band Waveform
    // Blue = Low (20-200Hz), Orange/Amber = Mid (200-5000Hz), White = High (5000Hz+)
    // Bands are drawn as layered columns — low at bottom, mid in middle, high at peaks

    // Rekordbox 3-Band colors
    private let lowColor = Color(red: 0.15, green: 0.35, blue: 0.95)   // Deep blue
    private let midColor = Color(red: 0.95, green: 0.65, blue: 0.1)    // Amber/orange
    private let highColor = Color(red: 0.92, green: 0.92, blue: 0.95)  // Near-white

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let data = vm.waveformData
        let colorData = vm.frequencyColorData
        guard !data.isEmpty else { return }

        let totalBuckets = data.count
        let visibleStart = vm.waveformOffset / (size.width * vm.waveformZoom) * CGFloat(totalBuckets)
        let visibleEnd = (vm.waveformOffset + size.width) / (size.width * vm.waveformZoom) * CGFloat(totalBuckets)
        guard visibleStart < visibleEnd else { return }

        let centerY = size.height / 2
        let pixelCount = Int(size.width)
        let hasColorData = !colorData.isEmpty && colorData.count == data.count
        let scale: CGFloat = 0.9

        if !hasColorData {
            // Fallback: single-color waveform
            drawFallbackWaveform(context: context, size: size, data: data, visibleStart: visibleStart, visibleEnd: visibleEnd)
            return
        }

        // Rekordbox 3-Band layered drawing: draw each band as its own filled shape
        // Order: Low (back/blue) → Mid (amber) → High (front/white)
        // Each band is drawn symmetrically from centerY

        // 1. Draw LOW band (blue) — typically largest for kicks/bass
        drawBandFill(context: context, pixelCount: pixelCount, centerY: centerY, scale: scale,
                     visibleStart: visibleStart, visibleEnd: visibleEnd, totalBuckets: totalBuckets,
                     colorData: colorData, bandKeyPath: \.low, color: lowColor, opacity: 0.85)

        // 2. Draw MID band (amber) — vocals, snares, synths
        drawBandFill(context: context, pixelCount: pixelCount, centerY: centerY, scale: scale,
                     visibleStart: visibleStart, visibleEnd: visibleEnd, totalBuckets: totalBuckets,
                     colorData: colorData, bandKeyPath: \.mid, color: midColor, opacity: 0.8)

        // 3. Draw HIGH band (white) — hats, cymbals, air
        drawBandFill(context: context, pixelCount: pixelCount, centerY: centerY, scale: scale,
                     visibleStart: visibleStart, visibleEnd: visibleEnd, totalBuckets: totalBuckets,
                     colorData: colorData, bandKeyPath: \.high, color: highColor, opacity: 0.75)

        // 4. Draw overall outline for definition
        drawWaveformOutline(context: context, size: size, data: data,
                           visibleStart: visibleStart, visibleEnd: visibleEnd)
    }

    private func drawBandFill(context: GraphicsContext, pixelCount: Int, centerY: CGFloat, scale: CGFloat,
                              visibleStart: CGFloat, visibleEnd: CGFloat, totalBuckets: Int,
                              colorData: [(low: Float, mid: Float, high: Float)],
                              bandKeyPath: KeyPath<(low: Float, mid: Float, high: Float), Float>,
                              color: Color, opacity: Double) {
        // Build a filled path: top half from left to right, then bottom half right to left
        var topPath = Path()
        topPath.move(to: CGPoint(x: 0, y: centerY))

        for x in 0..<pixelCount {
            let bucketF = visibleStart + CGFloat(x) / CGFloat(pixelCount) * (visibleEnd - visibleStart)
            let bucketIdx = max(0, min(totalBuckets - 1, Int(bucketF)))
            let amp = CGFloat(colorData[bucketIdx][keyPath: bandKeyPath])
            let y = centerY - amp * centerY * scale
            topPath.addLine(to: CGPoint(x: CGFloat(x), y: y))
        }

        // Return along the bottom (mirrored)
        for x in stride(from: pixelCount - 1, through: 0, by: -1) {
            let bucketF = visibleStart + CGFloat(x) / CGFloat(pixelCount) * (visibleEnd - visibleStart)
            let bucketIdx = max(0, min(totalBuckets - 1, Int(bucketF)))
            let amp = CGFloat(colorData[bucketIdx][keyPath: bandKeyPath])
            let y = centerY + amp * centerY * scale
            topPath.addLine(to: CGPoint(x: CGFloat(x), y: y))
        }

        topPath.closeSubpath()
        context.fill(topPath, with: .color(color.opacity(opacity)))
    }

    private func drawWaveformOutline(context: GraphicsContext, size: CGSize, data: [(min: Float, max: Float)],
                                     visibleStart: CGFloat, visibleEnd: CGFloat) {
        let totalBuckets = data.count
        let centerY = size.height / 2
        let pixelCount = Int(size.width)

        // Top edge outline
        var outlinePath = Path()
        for x in 0..<pixelCount {
            let bucketF = visibleStart + CGFloat(x) / size.width * (visibleEnd - visibleStart)
            let bucketIdx = max(0, min(totalBuckets - 1, Int(bucketF)))
            let topY = centerY - CGFloat(data[bucketIdx].max) * centerY * 0.9
            if x == 0 { outlinePath.move(to: CGPoint(x: 0, y: topY)) }
            else { outlinePath.addLine(to: CGPoint(x: CGFloat(x), y: topY)) }
        }
        context.stroke(outlinePath, with: .color(Color.white.opacity(0.25)), lineWidth: 0.5)

        // Bottom edge outline
        var outlineNeg = Path()
        for x in 0..<pixelCount {
            let bucketF = visibleStart + CGFloat(x) / size.width * (visibleEnd - visibleStart)
            let bucketIdx = max(0, min(totalBuckets - 1, Int(bucketF)))
            let botY = centerY - CGFloat(data[bucketIdx].min) * centerY * 0.9
            if x == 0 { outlineNeg.move(to: CGPoint(x: 0, y: botY)) }
            else { outlineNeg.addLine(to: CGPoint(x: CGFloat(x), y: botY)) }
        }
        context.stroke(outlineNeg, with: .color(Color.white.opacity(0.18)), lineWidth: 0.5)
    }

    private func drawFallbackWaveform(context: GraphicsContext, size: CGSize, data: [(min: Float, max: Float)],
                                      visibleStart: CGFloat, visibleEnd: CGFloat) {
        let totalBuckets = data.count
        let centerY = size.height / 2
        let pixelCount = Int(size.width)

        var fillPath = Path()
        fillPath.move(to: CGPoint(x: 0, y: centerY))
        for x in 0..<pixelCount {
            let bucketF = visibleStart + CGFloat(x) / size.width * (visibleEnd - visibleStart)
            let bucketIdx = max(0, min(totalBuckets - 1, Int(bucketF)))
            let topY = centerY - CGFloat(data[bucketIdx].max) * centerY * 0.9
            fillPath.addLine(to: CGPoint(x: CGFloat(x), y: topY))
        }
        for x in stride(from: pixelCount - 1, through: 0, by: -1) {
            let bucketF = visibleStart + CGFloat(x) / size.width * (visibleEnd - visibleStart)
            let bucketIdx = max(0, min(totalBuckets - 1, Int(bucketF)))
            let botY = centerY - CGFloat(data[bucketIdx].min) * centerY * 0.9
            fillPath.addLine(to: CGPoint(x: CGFloat(x), y: botY))
        }
        fillPath.closeSubpath()
        context.fill(fillPath, with: .color(Color(red: 0.2, green: 0.6, blue: 0.85).opacity(0.55)))
    }

    // MARK: - Loop Region

    private func drawLoopRegion(context: GraphicsContext, size: CGSize) {
        guard vm.loopEnabled, let region = vm.loopRegion, let sf = vm.sampleFile else { return }

        let startX = sampleToX(region.startSample, totalSamples: sf.totalSamples, width: size.width)
        let endX = sampleToX(region.endSample, totalSamples: sf.totalSamples, width: size.width)

        if startX > 0 {
            context.fill(Path(CGRect(x: 0, y: 0, width: startX, height: size.height)), with: .color(.black.opacity(0.4)))
        }
        if endX < size.width {
            context.fill(Path(CGRect(x: endX, y: 0, width: size.width - endX, height: size.height)), with: .color(.black.opacity(0.4)))
        }

        context.fill(Path(CGRect(x: startX, y: 0, width: endX - startX, height: size.height)), with: .color(Color.green.opacity(0.06)))

        var sl = Path(); sl.move(to: CGPoint(x: startX, y: 0)); sl.addLine(to: CGPoint(x: startX, y: size.height))
        context.stroke(sl, with: .color(.green.opacity(0.9)), lineWidth: 2)

        var el = Path(); el.move(to: CGPoint(x: endX, y: 0)); el.addLine(to: CGPoint(x: endX, y: size.height))
        context.stroke(el, with: .color(.green.opacity(0.9)), lineWidth: 2)

        context.fill(Path(CGRect(x: startX, y: 0, width: endX - startX, height: 3)), with: .color(.green.opacity(0.8)))
    }

    // MARK: - Slice Markers

    private func drawSliceMarkers(context: GraphicsContext, size: CGSize) {
        guard let sf = vm.sampleFile else { return }

        for marker in vm.sliceMarkers {
            let x = sampleToX(marker.samplePosition, totalSamples: sf.totalSamples, width: size.width)
            guard x >= -2 && x <= size.width + 2 else { continue }

            let color: Color = {
                switch marker.type {
                case .transient: return .orange
                case .manual: return .green
                case .grid: return .yellow
                }
            }()

            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(color.opacity(0.8)), lineWidth: 1)

            var tri = Path()
            tri.move(to: CGPoint(x: x - 4, y: 0))
            tri.addLine(to: CGPoint(x: x + 4, y: 0))
            tri.addLine(to: CGPoint(x: x, y: 7))
            tri.closeSubpath()
            context.fill(tri, with: .color(color))

            if let pad = marker.padIndex {
                let text = Text("\(pad + 1)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                context.draw(text, at: CGPoint(x: x, y: 16))
            }
        }
    }

    // MARK: - Playhead

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard let sf = vm.sampleFile else { return }

        let x = sampleToX(vm.currentPosition, totalSamples: sf.totalSamples, width: size.width)
        let clampedX = max(-2, min(size.width + 2, x))

        var line = Path()
        line.move(to: CGPoint(x: clampedX, y: 0))
        line.addLine(to: CGPoint(x: clampedX, y: size.height))
        context.stroke(line, with: .color(.white), lineWidth: 2)

        var head = Path()
        head.move(to: CGPoint(x: clampedX - 6, y: 0))
        head.addLine(to: CGPoint(x: clampedX + 6, y: 0))
        head.addLine(to: CGPoint(x: clampedX, y: 10))
        head.closeSubpath()
        context.fill(head, with: .color(Color.red))
    }

    // MARK: - Coordinate Mapping

    private func sampleToX(_ sample: Int, totalSamples: Int, width: CGFloat) -> CGFloat {
        guard totalSamples > 0 else { return 0 }
        return CGFloat(sample) / CGFloat(totalSamples) * width * vm.waveformZoom - vm.waveformOffset
    }

    private func xToSample(_ x: CGFloat, width: CGFloat) -> Int {
        guard let sf = vm.sampleFile, width > 0 else { return 0 }
        let normalized = (x + vm.waveformOffset) / (width * vm.waveformZoom)
        return max(0, min(sf.totalSamples - 1, Int(normalized * CGFloat(sf.totalSamples))))
    }

    // MARK: - Auto-Follow Playhead

    @discardableResult
    private func updateViewWidth(_ w: CGFloat) -> Bool {
        if currentViewWidth != w {
            DispatchQueue.main.async { currentViewWidth = w }
        }
        vm.lastKnownViewWidth = w
        return true
    }

    private func autoFollowPlayhead(viewWidth: CGFloat) {
        guard let sf = vm.sampleFile, sf.totalSamples > 0 else { return }

        let playheadX = sampleToX(vm.currentPosition, totalSamples: sf.totalSamples, width: viewWidth)

        // If playhead is outside the visible area (with margin), scroll to center it
        let margin: CGFloat = viewWidth * 0.1
        if playheadX < margin || playheadX > viewWidth - margin {
            // Smoothly scroll so playhead is at ~25% from the left
            let targetX: CGFloat = viewWidth * 0.25
            let playheadFraction = CGFloat(vm.currentPosition) / CGFloat(sf.totalSamples)
            let idealOffset = playheadFraction * viewWidth * vm.waveformZoom - targetX
            let maxOffset = max(0, viewWidth * vm.waveformZoom - viewWidth)
            let clampedOffset = max(0, min(maxOffset, idealOffset))

            // Smooth interpolation for fluid scrolling
            let smoothing: CGFloat = 0.15
            vm.waveformOffset = vm.waveformOffset + (clampedOffset - vm.waveformOffset) * smoothing
        }
    }

    // MARK: - Spectrogram Drawing

    private func drawSpectrogram(context: GraphicsContext, size: CGSize) {
        guard let data = vm.spectrogramData, data.timeSliceCount > 0 else {
            // Fallback: show regular waveform if spectrogram not yet computed
            drawWaveform(context: context, size: size)
            return
        }

        let totalSlices = data.timeSliceCount
        let visibleStartFrac = vm.waveformOffset / (size.width * vm.waveformZoom)
        let visibleEndFrac = (vm.waveformOffset + size.width) / (size.width * vm.waveformZoom)

        let startSlice = max(0, Int(visibleStartFrac * CGFloat(totalSlices)))
        let endSlice = min(totalSlices, Int(visibleEndFrac * CGFloat(totalSlices)) + 1)
        let pixelCount = Int(size.width)

        // Focus on audible range (up to ~16kHz)
        let maxBin = min(data.frequencyBinCount, 512)
        let minDB: Float = -80
        let maxDB: Float = data.maxMagnitude
        let range = max(1, maxDB - minDB)

        let binHeight = size.height / CGFloat(maxBin)

        for x in 0..<pixelCount {
            let sliceFrac = CGFloat(x) / CGFloat(pixelCount)
            let sliceIdx = startSlice + Int(sliceFrac * CGFloat(endSlice - startSlice))
            guard sliceIdx >= 0 && sliceIdx < totalSlices else { continue }

            let slice = data.magnitudes[sliceIdx]

            for bin in stride(from: 0, to: maxBin, by: max(1, Int(1.0 / binHeight))) {
                guard bin < slice.count else { break }
                let normalized = max(0, min(1, (slice[bin] - minDB) / range))
                let color = spectrogramColor(normalized)
                let y = size.height - CGFloat(bin) * binHeight - binHeight
                let rect = CGRect(x: CGFloat(x), y: y, width: 1, height: max(1, ceil(binHeight)))
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    private func spectrogramColor(_ value: Float) -> Color {
        let v = CGFloat(value)
        if v < 0.25 {
            let t = v / 0.25
            return Color(red: 0, green: 0, blue: 0.15 + t * 0.55)
        } else if v < 0.5 {
            let t = (v - 0.25) / 0.25
            return Color(red: 0, green: t * 0.8, blue: 0.7 * (1 - t * 0.3))
        } else if v < 0.75 {
            let t = (v - 0.5) / 0.25
            return Color(red: t * 0.9, green: 0.8, blue: 0.49 * (1 - t))
        } else {
            let t = (v - 0.75) / 0.25
            return Color(red: 0.9 + t * 0.1, green: 0.8 * (1 - t * 0.5), blue: 0)
        }
    }
}

// Helper for scroll wheel on macOS — detects trackpad vs mouse, reports cursor position
struct ScrollWheelView: NSViewRepresentable {
    let handler: (CGPoint, Bool, CGFloat) -> Void  // (delta, hasPreciseDeltas, cursorX)

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }
}

class ScrollWheelNSView: NSView {
    var handler: ((CGPoint, Bool, CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let hasPrecise = event.hasPreciseScrollingDeltas
        let delta = CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        // Get cursor position within this view
        let locationInView = convert(event.locationInWindow, from: nil)
        handler?(delta, hasPrecise, locationInView.x)
    }
}
