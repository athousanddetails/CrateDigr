import Foundation
import SwiftUI

enum SamplerToolPanel: String, CaseIterable, Identifiable {
    case pitchSpeed = "Pitch/Speed"
    case beat = "Beat"
    case chop = "Chop"
    case pads = "Pads"
    case keyboard = "Keys"
    case lofi = "Lo-Fi"
    case export = "Export"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pitchSpeed: return "dial.medium"
        case .beat: return "waveform.badge.plus"
        case .chop: return "scissors"
        case .pads: return "square.grid.4x3.fill"
        case .keyboard: return "pianokeys"
        case .lofi: return "waveform.path.badge.minus"
        case .export: return "square.and.arrow.up"
        }
    }
}

enum LoopMode: Hashable {
    case free
    case bars(Double)
}

enum PadPlayLength: String, CaseIterable, Identifiable {
    case full = "Full"
    case steps2 = "2 Steps"
    case steps4 = "4 Steps"
    case steps8 = "8 Steps"
    case steps16 = "16 Steps"
    case bar1 = "1 Bar"
    case bar2 = "2 Bars"
    case bar4 = "4 Bars"

    var id: String { rawValue }

    func maxSamples(sampleRate: Double, bpm: Int?) -> Int? {
        guard let bpm = bpm, bpm > 0 else {
            return nil // Full length if no BPM
        }
        let samplesPerBeat = sampleRate * 60.0 / Double(bpm)
        switch self {
        case .full: return nil
        case .steps2: return Int(samplesPerBeat * 0.5)
        case .steps4: return Int(samplesPerBeat * 1.0)
        case .steps8: return Int(samplesPerBeat * 2.0)
        case .steps16: return Int(samplesPerBeat * 4.0)
        case .bar1: return Int(samplesPerBeat * 4.0)
        case .bar2: return Int(samplesPerBeat * 8.0)
        case .bar4: return Int(samplesPerBeat * 16.0)
        }
    }
}

@MainActor
final class SamplerViewModel: ObservableObject {
    // MARK: - File Browser
    @Published var browserFolder: URL = AppConstants.defaultOutputFolder
    @Published var audioFiles: [URL] = []
    @Published var selectedFileURL: URL?

    // MARK: - Loaded Sample
    @Published var sampleFile: SampleFile?
    @Published var waveformData: [(min: Float, max: Float)] = []
    @Published var frequencyColorData: [(low: Float, mid: Float, high: Float)] = []
    @Published var isLoadingFile = false
    @Published var loadError: String?

    // MARK: - Playback
    @Published var isPlaying = false
    @Published var currentPosition: Int = 0
    @Published var loopEnabled = false
    @Published var loopRegion: LoopRegion?
    @Published var loopMode: LoopMode = .free

    // MARK: - Pitch/Speed
    @Published var pitchSpeedMode: PitchSpeedMode = .turntable
    @Published var speed: Double = 1.0       // 0.7 to 1.3 turntable, 0.25 to 4.0 independent
    @Published var pitchSemitones: Double = 0 // -24 to +24
    @Published var targetBPM: Double = 0
    @Published var bpmLocked = false

    // MARK: - Slicing
    @Published var sliceMarkers: [SliceMarker] = []
    @Published var chopSensitivity: Double = 0.5
    @Published var gridBars: Double = 1

    // MARK: - MPC
    @Published var drumPattern = DrumPattern()
    @Published var patternPlaying = false
    @Published var currentStep: Int = 0
    @Published var padMuteOthers = true

    // (Jam section removed)

    // MARK: - Export
    @Published var exportProgress: Double = 0
    @Published var isExporting = false
    @Published var exportFolder: URL = AppConstants.defaultOutputFolder

    // MARK: - Grid / BPM / Metronome
    @Published var manualBPM: Double = 120
    @Published var gridOffsetSamples: Int = 0
    @Published var padPlayLength: PadPlayLength = .full
    @Published var metronomeEnabled = false
    @Published var metronomeVolume: Double = 0.8
    @Published var snapToGrid = false
    @Published var loopSnapToGrid = false
    @Published var previewVolume: Float = 1.0
    @Published var eqLow: Float = 0    // dB, -26 to +6
    @Published var eqMid: Float = 0
    @Published var eqHigh: Float = 0
    private var tapTimes: [Date] = []
    private var metronomeTimer: Timer?

    // MARK: - Beat Overlay
    @Published var beatOverlayEnabled = false
    @Published var selectedDrumLoop: DrumLoop?
    @Published var beatOverlayVolume: Float = 0.7
    @Published var selectedBeatGenre: DrumLoopGenre = .boombap
    @Published var availableDrumLoops: [DrumLoop] = []
    @Published var userDrumLoops: [DrumLoop] = []
    private var beatLoopLoaded = false

    // MARK: - Focus Mode
    @Published var isFocusMode = false
    private var preFocusState: PreFocusState?

    struct PreFocusState {
        let sampleFile: SampleFile
        let waveformData: [(min: Float, max: Float)]
        let frequencyColorData: [(low: Float, mid: Float, high: Float)]
        let sliceMarkers: [SliceMarker]
        let loopRegion: LoopRegion?
        let loopEnabled: Bool
        let currentPosition: Int
        let waveformZoom: CGFloat
        let waveformOffset: CGFloat
    }

    // MARK: - Lo-Fi (Real-Time Preview)
    @Published var lofiBitDepth: Int = 12
    @Published var lofiSampleRate: Double = 26040
    @Published var lofiDrive: Float = 0.2
    @Published var lofiCrackle: Float = 0.0
    @Published var lofiWowFlutter: Float = 0.0
    @Published var lofiEnabled: Bool = false          // Real-time preview toggle
    private var lofiOriginalSamples: SampleFile?       // Clean original for re-processing
    private var lofiUndoSamples: SampleFile?           // For destructive apply undo
    private var lofiDebounceTask: Task<Void, Never>?   // Debounce rapid slider changes

    // MARK: - Spectrogram
    @Published var showSpectrogram = false
    @Published var spectrogramData: SpectrogramData?

    // MARK: - UI
    @Published var activePanel: SamplerToolPanel = .pitchSpeed
    @Published var waveformZoom: CGFloat = 1.0
    @Published var waveformOffset: CGFloat = 0
    @Published var showGrid = false
    @Published var waveformHeight: CGFloat = 180  // User-resizable waveform height

    // MARK: - Services
    let engine = SampleEngine()
    private let analyzer = AudioAnalyzer()
    private let exporter = SampleExporter()

    init() {
        refreshFileList()
        loadBeatOverlayLoops()

        // Listen for "Send to Sampler" from Stems tab
        NotificationCenter.default.addObserver(
            forName: .sendStemToSampler,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let url = notification.userInfo?["url"] as? URL {
                Task { @MainActor [weak self] in
                    self?.loadFile(url)
                }
            }
        }
    }

    // MARK: - File Browser

    func setBrowserFolder(_ url: URL) {
        browserFolder = url
        refreshFileList()
    }

    func refreshFileList() {
        let fm = FileManager.default
        let extensions = ["wav", "mp3", "aiff", "aif", "flac", "m4a", "ogg", "webm"]

        guard let contents = try? fm.contentsOfDirectory(
            at: browserFolder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            audioFiles = []
            return
        }

        audioFiles = contents
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - File Loading

    /// Generation counter to discard stale background analysis results
    private var loadGeneration: Int = 0
    /// Track which file is actually loaded (separate from List selection binding)
    private var loadedFileURL: URL?

    func loadFile(_ url: URL) {
        // Don't reload the same file that's already loaded
        if loadedFileURL == url && sampleFile != nil { return }

        // Stop any current playback and beat overlay when switching files
        if isPlaying {
            engine.stop()
            isPlaying = false
        }
        engine.stopBeatLoop()
        beatLoopLoaded = false

        isLoadingFile = true
        loadError = nil
        loadedFileURL = url
        currentPosition = 0
        loadGeneration += 1
        let myGeneration = loadGeneration

        Task {
            do {
                // ── Phase 1: INSTANT ──
                // Load audio samples (single file read, shared with analyzer)
                var file = try SampleFile.load(from: url)

                // Set provisional BPM=120 so grid/metronome/snap controls ALWAYS appear
                file.bpm = 120

                // Compute basic waveform (vDSP-accelerated, very fast)
                let waveform = file.waveformData(bucketCount: 4000)

                // Check we're still the active load
                guard self.loadGeneration == myGeneration else { return }

                // Display immediately — waveform visible, playback ready
                self.sampleFile = file
                self.waveformData = waveform
                self.frequencyColorData = []  // Will be filled by Phase 2
                self.targetBPM = 120
                self.manualBPM = 120
                self.drumPattern.bpm = 120
                self.gridOffsetSamples = 0

                // Load into engine — playback available NOW
                engine.loadSample(file)

                // Reset state
                self.sliceMarkers = []
                self.loopRegion = nil
                self.loopEnabled = false
                self.speed = 1.0
                self.pitchSemitones = 0
                self.waveformZoom = 1.0
                self.waveformOffset = 0

                self.isLoadingFile = false

                // ── Phase 2: BACKGROUND ──
                // BPM/Key analysis + frequency colors run async, UI updates when ready
                let samples = file.samples
                let sampleRate = file.sampleRate

                // Run analysis on background thread (reuses already-loaded samples, no file I/O)
                let analysis = await Task.detached(priority: .userInitiated) { [analyzer] in
                    return analyzer.analyze(samples: samples, sampleRate: sampleRate)
                }.value

                // Check we're still the active load
                guard self.loadGeneration == myGeneration else { return }

                // Update BPM/Key with real values
                self.sampleFile?.bpm = analysis.bpm
                self.sampleFile?.key = analysis.key
                self.sampleFile?.scale = analysis.scale
                self.targetBPM = Double(analysis.bpm)
                self.manualBPM = Double(analysis.bpm)
                self.drumPattern.bpm = Double(analysis.bpm)

                // Compute frequency color data on background thread
                let colorData = await Task.detached(priority: .userInitiated) {
                    return file.frequencyColorData(bucketCount: 4000)
                }.value

                guard self.loadGeneration == myGeneration else { return }
                self.frequencyColorData = colorData

                // Compute spectrogram data in background
                let spectro = await Task.detached(priority: .utility) {
                    SpectrogramComputer.compute(samples: samples, sampleRate: sampleRate)
                }.value

                guard self.loadGeneration == myGeneration else { return }
                self.spectrogramData = spectro

            } catch {
                guard self.loadGeneration == myGeneration else { return }
                self.loadError = error.localizedDescription
                self.isLoadingFile = false
            }
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            engine.stop()
            if beatOverlayEnabled { engine.stopBeatLoop() }
            isPlaying = false
        } else {
            if loopEnabled, let region = loopRegion {
                engine.playRegion(region, loop: true)
            } else {
                engine.play(from: currentPosition)
            }
            isPlaying = true
            // Start beat overlay synced to beat grid
            if beatOverlayEnabled, beatLoopLoaded {
                startBeatOverlaySynced()
            }
        }
    }

    func stopPlayback() {
        engine.stop()
        if beatOverlayEnabled { engine.stopBeatLoop() }
        isPlaying = false
    }

    func seekTo(_ position: Int) {
        var pos = max(0, min(position, sampleFile?.totalSamples ?? 0))
        // Snap to nearest 16th note if snap mode is on
        if snapToGrid, let sf = sampleFile, let bpm = sf.bpm, bpm > 0 {
            pos = snapSampleToGrid(pos, sf: sf)
        }
        currentPosition = pos
        if isPlaying {
            engine.seek(to: pos)
        } else {
            // When not playing, just update positions without triggering playback
            engine.currentPosition = pos
        }
    }

    /// Snap a sample position to the nearest 16th note on the grid (uses effective BPM)
    func snapSampleToGrid(_ position: Int, sf: SampleFile? = nil) -> Int {
        guard let sf = sf ?? sampleFile, let bpm = sf.bpm, bpm > 0 else { return position }
        let effectiveBPM = Double(bpm) * speed
        let samplesPerBeat = sf.sampleRate * 60.0 / effectiveBPM
        let samplesPerSixteenth = samplesPerBeat / 4.0
        let gridStart = Double(gridOffsetSamples)
        let relativePos = Double(position) - gridStart
        let nearestSixteenth = round(relativePos / samplesPerSixteenth) * samplesPerSixteenth
        return max(0, min(sf.totalSamples, Int(nearestSixteenth + gridStart)))
    }

    func seekToSeconds(_ seconds: Double) {
        guard let sr = sampleFile?.sampleRate else { return }
        seekTo(Int(seconds * sr))
    }

    // MARK: - Preview Volume

    func updatePreviewVolume(_ vol: Float) {
        previewVolume = vol
        engine.setPreviewVolume(vol)
    }

    // MARK: - 3-Band EQ

    func updateEQLow(_ gain: Float) {
        eqLow = gain
        engine.setEQBand(0, gain: gain)
    }

    func updateEQMid(_ gain: Float) {
        eqMid = gain
        engine.setEQBand(1, gain: gain)
    }

    func updateEQHigh(_ gain: Float) {
        eqHigh = gain
        engine.setEQBand(2, gain: gain)
    }

    func resetEQ() {
        eqLow = 0
        eqMid = 0
        eqHigh = 0
        engine.resetEQ()
    }

    // MARK: - Beat Overlay

    func loadBeatOverlayLoops() {
        availableDrumLoops = DrumLoop.loadBundled()
    }

    /// All loops for the currently selected genre (bundled + user)
    var filteredDrumLoops: [DrumLoop] {
        if selectedBeatGenre == .user {
            return userDrumLoops
        }
        return availableDrumLoops.filter { $0.genre == selectedBeatGenre }
    }

    func selectDrumLoop(_ loop: DrumLoop) {
        selectedDrumLoop = loop
        beatLoopLoaded = false

        // Load the drum loop audio into the engine
        do {
            let file = try SampleFile.load(from: loop.url)
            engine.loadBeatLoop(samples: file.samples, sampleRate: file.sampleRate)
            engine.setBeatLoopVolume(beatOverlayVolume)
            beatLoopLoaded = true

            // If beat overlay is enabled and sample is playing, start the beat synced
            if beatOverlayEnabled && isPlaying {
                startBeatOverlaySynced()
            }
        } catch {
            print("Failed to load drum loop: \(error)")
        }
    }

    func toggleBeatOverlay() {
        beatOverlayEnabled.toggle()

        if beatOverlayEnabled {
            // Start beat synced to current beat grid position
            if beatLoopLoaded, isPlaying {
                startBeatOverlaySynced()
            }
        } else {
            engine.stopBeatLoop()
        }
    }

    func updateBeatOverlayVolume(_ vol: Float) {
        beatOverlayVolume = vol
        engine.setBeatLoopVolume(vol)
    }

    /// Calculate the playback rate to sync a drum loop to the current effective BPM
    private func beatOverlayRate(for loop: DrumLoop) -> Float {
        let targetBPM = effectiveBPM
        guard loop.originalBPM > 0 else { return 1.0 }
        return Float(targetBPM / loop.originalBPM)
    }

    /// Calculate the beat-phase offset in seconds at the drum loop's ORIGINAL tempo.
    /// This tells the engine where in the loop to start so it's synced to the main track's beat grid.
    private func beatPhaseOffsetSeconds(for loop: DrumLoop) -> Double {
        guard let sf = sampleFile, let bpm = sf.bpm, bpm > 0 else { return 0 }

        let currentEffectiveBPM = effectiveBPM
        guard currentEffectiveBPM > 0 else { return 0 }

        // How far are we into the beat grid, in seconds at the effective BPM?
        let samplesPerBeat = sf.sampleRate * 60.0 / currentEffectiveBPM
        let gridStart = Double(gridOffsetSamples)
        let relativePos = Double(currentPosition) - gridStart
        guard relativePos >= 0, samplesPerBeat > 0 else { return 0 }

        // Current position in beats (fractional)
        let currentBeat = relativePos / samplesPerBeat

        // Convert the beat position to seconds at the loop's ORIGINAL tempo.
        // The loop plays at originalBPM, so 1 beat = 60/originalBPM seconds.
        let secondsPerBeatOriginal = 60.0 / loop.originalBPM
        let offsetSeconds = currentBeat * secondsPerBeatOriginal

        return offsetSeconds
    }

    /// Start beat overlay with phase alignment to current beat grid position
    func startBeatOverlaySynced() {
        guard beatOverlayEnabled, beatLoopLoaded, let loop = selectedDrumLoop else { return }
        let rate = beatOverlayRate(for: loop)
        let offset = isPlaying ? beatPhaseOffsetSeconds(for: loop) : 0
        engine.playBeatLoop(rate: rate, offsetSeconds: offset)
    }

    /// Call when BPM or speed changes to keep beat overlay in sync.
    /// Restarts the loop from the correct phase position.
    func updateBeatOverlaySync() {
        guard beatOverlayEnabled, beatLoopLoaded, let loop = selectedDrumLoop else { return }
        let rate = beatOverlayRate(for: loop)
        if engine.isBeatLoopPlaying {
            // Restart with new rate and correct phase
            let offset = beatPhaseOffsetSeconds(for: loop)
            engine.playBeatLoop(rate: rate, offsetSeconds: offset)
        } else {
            engine.updateBeatLoopRate(rate)
        }
    }

    func addUserDrumLoop(_ url: URL) {
        // Detect BPM from the loop
        do {
            let file = try SampleFile.load(from: url)
            let analysis = analyzer.analyze(samples: file.samples, sampleRate: file.sampleRate)

            let loop = DrumLoop(
                id: "user_\(UUID().uuidString.prefix(8))",
                name: url.deletingPathExtension().lastPathComponent,
                genre: .user,
                originalBPM: Double(analysis.bpm),
                url: url,
                attribution: ""
            )
            userDrumLoops.append(loop)
        } catch {
            print("Failed to load user drum loop: \(error)")
        }
    }

    // MARK: - Pitch/Speed

    /// The effective BPM after speed changes
    var effectiveBPM: Double {
        guard let bpm = sampleFile?.bpm, bpm > 0 else { return 120 }
        return Double(bpm) * speed
    }

    func updateSpeed(_ newSpeed: Double) {
        speed = newSpeed
        engine.setRate(Float(newSpeed))

        if bpmLocked, let bpm = sampleFile?.bpm {
            targetBPM = Double(bpm) * newSpeed
        }

        updateBeatOverlaySync()
    }

    func updatePitch(_ semitones: Double) {
        pitchSemitones = semitones
        engine.setPitch(Float(semitones))
    }

    func lockToBPM(_ bpm: Double) {
        guard let originalBPM = sampleFile?.bpm, originalBPM > 0 else { return }
        targetBPM = bpm
        bpmLocked = true
        let ratio = bpm / Double(originalBPM)
        speed = ratio
        engine.setRate(Float(ratio))
        updateBeatOverlaySync()
    }

    func toggleBPMLock() {
        bpmLocked.toggle()
        if bpmLocked {
            lockToBPM(targetBPM)
        }
    }

    // MARK: - Zoom

    /// The current view width, updated by WaveformView
    var lastKnownViewWidth: CGFloat = 800

    func zoomIn() {
        let oldZoom = waveformZoom
        waveformZoom = min(100, waveformZoom * 1.5)
        centerOnPlayhead(oldZoom: oldZoom)
    }

    func zoomOut() {
        let oldZoom = waveformZoom
        waveformZoom = max(1, waveformZoom / 1.5)
        centerOnPlayhead(oldZoom: oldZoom)
    }

    func zoomReset() {
        waveformZoom = 1.0
        waveformOffset = 0
    }

    /// After zoom change, adjust offset so playhead stays centered in the view
    func centerOnPlayhead(oldZoom: CGFloat? = nil) {
        guard let sf = sampleFile, sf.totalSamples > 0 else { return }
        let viewWidth = lastKnownViewWidth
        guard viewWidth > 0 else { return }

        let playheadFraction = CGFloat(currentPosition) / CGFloat(sf.totalSamples)
        let idealOffset = playheadFraction * viewWidth * waveformZoom - viewWidth * 0.5
        let maxOffset = max(0, viewWidth * waveformZoom - viewWidth)
        waveformOffset = max(0, min(maxOffset, idealOffset))
    }

    // MARK: - Tap Tempo & Grid

    func tapTempo() {
        let now = Date()
        // Remove taps older than 3 seconds
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 3.0 }
        tapTimes.append(now)

        if tapTimes.count >= 3 {
            var intervals: [Double] = []
            for i in 1..<tapTimes.count {
                intervals.append(tapTimes[i].timeIntervalSince(tapTimes[i - 1]))
            }
            let avgInterval = intervals.reduce(0, +) / Double(intervals.count)
            let tappedBPM = 60.0 / avgInterval
            manualBPM = round(tappedBPM * 10) / 10
            applyManualBPM()
        }
    }

    func applyManualBPM() {
        guard manualBPM > 20 && manualBPM < 300 else { return }
        sampleFile?.bpm = Int(manualBPM)
        targetBPM = manualBPM
        drumPattern.bpm = manualBPM
        updateBeatOverlaySync()
    }

    func nudgeGridLeft() {
        guard let sf = sampleFile, let bpm = sf.bpm, bpm > 0 else { return }
        let eBPM = Double(bpm) * speed
        let samplesPerBeat = sf.sampleRate * 60.0 / eBPM
        // Nudge by 1/128th of a beat for fine-grained control
        let nudge = max(1, Int(samplesPerBeat / 128.0))
        gridOffsetSamples = max(0, gridOffsetSamples - nudge)
        // Resync beat overlay to new grid position
        if engine.isBeatLoopPlaying { startBeatOverlaySynced() }
    }

    func nudgeGridRight() {
        guard let sf = sampleFile, let bpm = sf.bpm, bpm > 0 else { return }
        let eBPM = Double(bpm) * speed
        let samplesPerBeat = sf.sampleRate * 60.0 / eBPM
        let nudge = max(1, Int(samplesPerBeat / 128.0))
        gridOffsetSamples += nudge
        // Resync beat overlay to new grid position
        if engine.isBeatLoopPlaying { startBeatOverlaySynced() }
    }

    func resetGrid() {
        gridOffsetSamples = 0
        // Resync beat overlay to new grid position
        if engine.isBeatLoopPlaying { startBeatOverlaySynced() }
    }

    // MARK: - Metronome

    func toggleMetronome() {
        metronomeEnabled.toggle()
        if metronomeEnabled {
            startMetronome()
        } else {
            stopMetronome()
        }
    }

    private func startMetronome() {
        let bpm = manualBPM > 0 ? manualBPM : 120.0
        let interval = 60.0 / bpm  // beat interval in seconds
        let sr = sampleFile?.sampleRate ?? 44100

        // Synthesize metronome click in engine
        engine.setupMetronome(sampleRate: sr)

        var beatCount = 0
        metronomeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.metronomeEnabled else { return }
                let isDownbeat = (beatCount % 4) == 0
                self.engine.triggerMetronome(isDownbeat: isDownbeat, volume: Float(self.metronomeVolume))
                beatCount += 1
            }
        }
    }

    private func stopMetronome() {
        metronomeTimer?.invalidate()
        metronomeTimer = nil
    }

    // MARK: - Loop

    func setLoopRegion(start: Int, end: Int) {
        guard let samples = sampleFile?.samples else { return }
        let snapped = ZeroCrossingFinder.snapLoopRegion(in: samples, start: start, end: end)
        loopRegion = LoopRegion(startSample: snapped.start, endSample: snapped.end)
        loopEnabled = true
        engine.setLoop(loopRegion, enabled: loopEnabled)
    }

    func setLoopByBars(startSample: Int, bars: Double) {
        guard let sf = sampleFile, let bpm = sf.bpm, bpm > 0 else { return }
        let beatsPerBar = 4.0
        let secondsPerBeat = 60.0 / Double(bpm)
        let durationSamples = Int(bars * beatsPerBar * secondsPerBeat * sf.sampleRate)
        setLoopRegion(start: startSample, end: startSample + durationSamples)
    }

    func applyLoopMode() {
        switch loopMode {
        case .free:
            // Keep existing loop region as-is
            break
        case .bars(let bars):
            // Traktor/Rekordbox behavior:
            // Loop-in (start) stays FIXED. Only loop-out moves.
            guard let sf = sampleFile, let bpm = sf.bpm, bpm > 0 else { return }
            let loopStart = loopRegion?.startSample ?? currentPosition
            let beatsPerBar = 4.0
            let secondsPerBeat = 60.0 / Double(bpm)
            let newLength = Int(bars * beatsPerBar * secondsPerBeat * sf.sampleRate)
            let newEnd = min(loopStart + newLength, sf.totalSamples)

            loopRegion = LoopRegion(startSample: loopStart, endSample: newEnd)
            loopEnabled = true
            engine.setLoop(loopRegion, enabled: true)
        }

        guard loopEnabled, let region = loopRegion else { return }

        if isPlaying {
            // If playhead is past the new loop-out, wrap it (Traktor-style modulo)
            let loopLen = region.length
            if loopLen > 0 && currentPosition >= region.endSample {
                let wrapped = region.startSample + ((currentPosition - region.startSample) % loopLen)
                engine.seamlessLoopRestart(region: region, from: wrapped)
            } else if currentPosition < region.startSample {
                // Playhead before loop start — jump to start
                engine.seamlessLoopRestart(region: region, from: region.startSample)
            } else {
                // Playhead is within the new region — just update, let it finish naturally
                engine.updateLoopRegion(region)
            }
        }
    }

    func toggleLoop() {
        if loopEnabled {
            // Loop is ON → turn it off
            loopEnabled = false
            engine.setLoop(loopRegion, enabled: false)
            // If playing, continue playing without loop
            if isPlaying {
                engine.play(from: currentPosition)
            }
            return
        }

        // Loop is OFF → create new loop at current playhead position
        switch loopMode {
        case .free:
            guard let sf = sampleFile, let bpm = sf.bpm, bpm > 0 else {
                // No BPM - loop entire file
                loopRegion = LoopRegion(startSample: 0, endSample: sampleFile?.totalSamples ?? 0)
                loopEnabled = true
                engine.setLoop(loopRegion, enabled: true)
                if isPlaying, let region = loopRegion {
                    engine.playRegion(region, loop: true)
                }
                return
            }
            setLoopByBars(startSample: currentPosition, bars: 4)
        case .bars(let bars):
            setLoopByBars(startSample: currentPosition, bars: bars)
        }
        loopEnabled = true
        engine.setLoop(loopRegion, enabled: loopEnabled)

        if isPlaying, let region = loopRegion {
            engine.playRegion(region, loop: true)
        }
    }

    // MARK: - Chopping

    func autoChop() {
        guard let sf = sampleFile else { return }
        let positions = TransientDetector.detect(
            samples: sf.samples,
            sampleRate: sf.sampleRate,
            sensitivity: Float(chopSensitivity)
        )
        sliceMarkers = positions.map { pos in
            let snapped = ZeroCrossingFinder.findNearest(in: sf.samples, near: pos)
            return SliceMarker(samplePosition: snapped, type: .transient)
        }
        assignPads()
    }

    func gridChop(bars: Double) {
        guard let sf = sampleFile, let bpm = sf.bpm, bpm > 0 else { return }
        let beatsPerBar = 4.0
        let secondsPerBeat = 60.0 / Double(bpm)
        let samplesPerSlice = Int(bars * beatsPerBar * secondsPerBeat * sf.sampleRate)

        guard samplesPerSlice > 0 else { return }

        var markers: [SliceMarker] = []
        var pos = 0
        while pos < sf.totalSamples {
            let snapped = ZeroCrossingFinder.findNearest(in: sf.samples, near: pos)
            markers.append(SliceMarker(samplePosition: snapped, type: .grid))
            pos += samplesPerSlice
        }
        sliceMarkers = markers
        assignPads()
    }

    func addManualSlice(at position: Int) {
        guard let samples = sampleFile?.samples else { return }
        let snapped = ZeroCrossingFinder.findNearest(in: samples, near: position)
        let marker = SliceMarker(samplePosition: snapped, type: .manual)
        sliceMarkers.append(marker)
        sliceMarkers.sort { $0.samplePosition < $1.samplePosition }
        assignPads()
    }

    func clearSlices() {
        sliceMarkers = []
    }

    func removeSlice(id: UUID) {
        sliceMarkers.removeAll { $0.id == id }
        assignPads()
    }

    private func assignPads() {
        for i in 0..<min(sliceMarkers.count, 16) {
            sliceMarkers[i].padIndex = i
        }
    }

    // MARK: - Pad Triggering

    func triggerPad(_ index: Int) {
        guard let sf = sampleFile, index < sliceMarkers.count else { return }

        let start = sliceMarkers[index].samplePosition
        var end: Int
        if index + 1 < sliceMarkers.count {
            end = sliceMarkers[index + 1].samplePosition
        } else {
            end = sf.totalSamples
        }

        // Apply pad play length limit
        if let maxLen = padPlayLength.maxSamples(sampleRate: sf.sampleRate, bpm: sf.bpm) {
            end = min(end, start + maxLen)
        }

        engine.triggerPad(
            index: index,
            samples: sf.samples,
            sampleRate: sf.sampleRate,
            start: start,
            end: end,
            muteOthers: padMuteOthers
        )
    }

    // MARK: - Chromatic Keyboard

    /// The root note offset (0 = C3, sample plays at original pitch)
    @Published var keyboardRootNote: Int = 60  // MIDI note 60 = C3
    @Published var keyboardOctave: Int = 0     // Octave shift for display

    /// Play a chromatic key. semitoneOffset is relative to the root (0 = original pitch).
    /// Plays loop region if active, otherwise the full sample.
    func playKeyboardNote(keyIndex: Int, semitoneOffset: Int) {
        guard sampleFile != nil else { return }

        // Use loop region if active, otherwise full sample (start=0, end=nil means whole buffer)
        let start: Int
        let end: Int?
        if loopEnabled, let region = loopRegion {
            start = region.startSample
            end = region.endSample
        } else {
            start = 0
            end = nil  // nil = play entire sample
        }

        engine.playKey(keyIndex: keyIndex, semitones: Float(semitoneOffset), start: start, end: end)
    }

    func stopKeyboardNote(keyIndex: Int) {
        engine.stopKey(keyIndex: keyIndex)
    }

    func stopAllKeyboardNotes() {
        engine.stopAllKeys()
    }

    // MARK: - Export

    /// Build the effective BPM tag for exported filenames
    private func effectiveBPMTag() -> String {
        guard let bpm = sampleFile?.bpm, bpm > 0 else { return "" }
        let eBPM = Int(round(Double(bpm) * speed))
        return "\(eBPM)bpm"
    }

    func exportSlices(options: SampleExporter.ExportOptions, customFilename: String? = nil) {
        guard let sf = sampleFile, !sliceMarkers.isEmpty else { return }

        isExporting = true
        exportProgress = 0

        let baseName = customFilename ?? "\(sf.filename)_\(effectiveBPMTag())"

        Task {
            do {
                let positions = sliceMarkers.map(\.samplePosition)
                _ = try await exporter.exportSlices(
                    inputPath: sf.url,
                    outputDir: exportFolder,
                    baseName: baseName,
                    slicePositions: positions,
                    sampleRate: sf.sampleRate,
                    totalSamples: sf.totalSamples,
                    options: options
                ) { progress in
                    Task { @MainActor in
                        self.exportProgress = progress
                    }
                }
            } catch {
                self.loadError = error.localizedDescription
            }
            self.isExporting = false
        }
    }

    func exportLoopRegion(options: SampleExporter.ExportOptions, customFilename: String? = nil) {
        guard let sf = sampleFile, let region = loopRegion else { return }

        isExporting = true
        exportProgress = 0

        let bpmTag = effectiveBPMTag()
        let filename = customFilename ?? "\(sf.filename)_loop_\(bpmTag)"

        Task {
            do {
                let startSec = Double(region.startSample) / sf.sampleRate
                let durSec = Double(region.length) / sf.sampleRate

                _ = try await exporter.exportRegion(
                    inputPath: sf.url,
                    outputDir: exportFolder,
                    filename: filename,
                    startSeconds: startSec,
                    durationSeconds: durSec,
                    options: options
                )
                self.exportProgress = 1.0
            } catch {
                self.loadError = error.localizedDescription
            }
            self.isExporting = false
        }
    }

    func exportFull(options: SampleExporter.ExportOptions, customFilename: String? = nil) {
        guard let sf = sampleFile else { return }

        isExporting = true
        let bpmTag = effectiveBPMTag()
        let filename = customFilename ?? "\(sf.filename)_\(bpmTag)"

        Task {
            do {
                _ = try await exporter.exportFullFile(
                    inputPath: sf.url,
                    outputDir: exportFolder,
                    filename: filename,
                    options: options
                )
                self.exportProgress = 1.0
            } catch {
                self.loadError = error.localizedDescription
            }
            self.isExporting = false
        }
    }

    // MARK: - Focus Mode

    func enterFocusMode() {
        guard let sf = sampleFile, let region = loopRegion else { return }

        // Save current state
        preFocusState = PreFocusState(
            sampleFile: sf,
            waveformData: waveformData,
            frequencyColorData: frequencyColorData,
            sliceMarkers: sliceMarkers,
            loopRegion: loopRegion,
            loopEnabled: loopEnabled,
            currentPosition: currentPosition,
            waveformZoom: waveformZoom,
            waveformOffset: waveformOffset
        )

        // Extract sub-region
        let startIdx = max(0, region.startSample)
        let endIdx = min(sf.totalSamples, region.endSample)
        guard endIdx > startIdx else { return }
        let subSamples = Array(sf.samples[startIdx..<endIdx])

        var focusFile = SampleFile(
            url: sf.url,
            samples: subSamples,
            sampleRate: sf.sampleRate,
            channelCount: sf.channelCount,
            duration: Double(subSamples.count) / sf.sampleRate
        )
        focusFile.bpm = sf.bpm
        focusFile.key = sf.key
        focusFile.scale = sf.scale

        // Remember if we were playing
        let wasPlaying = isPlaying
        if isPlaying { stopPlayback() }

        // Load focused region
        sampleFile = focusFile
        waveformData = focusFile.waveformData(bucketCount: 4000)
        frequencyColorData = []
        engine.loadSample(focusFile)

        sliceMarkers = []
        currentPosition = 0
        waveformZoom = 1.0
        waveformOffset = 0
        isFocusMode = true

        // Loop the entire focused region and start playing
        let focusRegion = LoopRegion(startSample: 0, endSample: focusFile.totalSamples)
        loopRegion = focusRegion
        loopEnabled = true
        engine.setLoop(focusRegion, enabled: true)
        engine.playRegion(focusRegion, loop: true)
        isPlaying = true

        // Background: frequency colors
        Task {
            let colorData = await Task.detached(priority: .userInitiated) {
                focusFile.frequencyColorData(bucketCount: 4000)
            }.value
            self.frequencyColorData = colorData
        }
    }

    func exitFocusMode() {
        guard let state = preFocusState else { return }

        if isPlaying { stopPlayback() }

        sampleFile = state.sampleFile
        waveformData = state.waveformData
        frequencyColorData = state.frequencyColorData
        sliceMarkers = state.sliceMarkers
        loopRegion = state.loopRegion
        loopEnabled = state.loopEnabled
        currentPosition = state.currentPosition
        waveformZoom = state.waveformZoom
        waveformOffset = state.waveformOffset
        engine.loadSample(state.sampleFile)

        preFocusState = nil
        isFocusMode = false
    }

    // MARK: - Resampling / Bounce-in-Place

    func resample() {
        guard let sf = sampleFile else { return }
        isExporting = true
        exportProgress = 0

        Task {
            do {
                var options = SampleExporter.ExportOptions()
                options.format = .wav(sampleRate: Int(sf.sampleRate), bitDepth: 24)
                options.speedRatio = speed
                options.pitchSemitones = pitchSemitones
                options.pitchSpeedMode = pitchSpeedMode
                options.eqLow = eqLow
                options.eqMid = eqMid
                options.eqHigh = eqHigh
                options.normalize = false

                let suffix = "_resampled"
                let outputDir = sf.url.deletingLastPathComponent()

                if let region = loopRegion, loopEnabled {
                    let startSec = Double(region.startSample) / sf.sampleRate
                    let durSec = Double(region.length) / sf.sampleRate
                    _ = try await exporter.exportRegion(
                        inputPath: sf.url,
                        outputDir: outputDir,
                        filename: sf.filename + suffix,
                        startSeconds: startSec,
                        durationSeconds: durSec,
                        options: options
                    )
                } else {
                    _ = try await exporter.exportFullFile(
                        inputPath: sf.url,
                        outputDir: outputDir,
                        filename: sf.filename + suffix,
                        options: options
                    )
                }

                self.exportProgress = 1.0
                self.refreshFileList()
            } catch {
                self.loadError = error.localizedDescription
            }
            self.isExporting = false
        }
    }

    // MARK: - Lo-Fi Processing (Real-Time Preview)

    func applyLoFiPreset(_ preset: LoFiProcessor.LoFiPreset) {
        lofiBitDepth = preset.bitDepth
        lofiSampleRate = preset.targetSampleRate
        lofiDrive = preset.drive
        lofiCrackle = preset.crackle
        lofiWowFlutter = preset.wowFlutter
        if lofiEnabled {
            lofiUpdatePreview()
        }
    }

    /// Toggle real-time lo-fi preview on/off — preserves playback state
    func toggleLoFi() {
        lofiEnabled.toggle()
        if lofiEnabled {
            // Save original samples for re-processing
            if lofiOriginalSamples == nil {
                lofiOriginalSamples = sampleFile
            }
            lofiUpdatePreview()
        } else {
            // Restore original (clean) audio
            if let original = lofiOriginalSamples {
                let wasPlaying = isPlaying
                let pos = currentPosition
                let savedLoopRegion = loopRegion
                let savedLoopEnabled = loopEnabled

                sampleFile = original
                waveformData = original.waveformData(bucketCount: 4000)
                engine.loadSample(original)
                currentPosition = pos
                engine.currentPosition = pos

                // Resume playback
                if wasPlaying {
                    if savedLoopEnabled, let region = savedLoopRegion {
                        engine.setLoop(region, enabled: true)
                        engine.playRegion(region, loop: true)
                        loopRegion = savedLoopRegion
                        loopEnabled = savedLoopEnabled
                    } else {
                        engine.play(from: pos)
                    }
                    isPlaying = true
                }
            }
        }
    }

    /// Called when any lo-fi slider changes — debounced re-processing
    func lofiParameterChanged() {
        guard lofiEnabled else { return }
        lofiDebounceTask?.cancel()
        lofiDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms debounce
            guard !Task.isCancelled else { return }
            lofiUpdatePreview()
        }
    }

    /// Re-process original samples with current lo-fi settings and reload engine.
    /// Preserves playback state — if audio was playing, it resumes from the same position.
    private func lofiUpdatePreview() {
        guard let original = lofiOriginalSamples ?? sampleFile else { return }

        // Save original if not yet saved
        if lofiOriginalSamples == nil {
            lofiOriginalSamples = original
        }

        let preset = LoFiProcessor.LoFiPreset(
            name: "Preview",
            bitDepth: lofiBitDepth,
            targetSampleRate: lofiSampleRate,
            drive: lofiDrive,
            crackle: lofiCrackle,
            wowFlutter: lofiWowFlutter
        )

        let processed = LoFiProcessor.apply(
            preset: preset,
            to: original.samples,
            sampleRate: original.sampleRate
        )

        var newFile = SampleFile(
            url: original.url,
            samples: processed,
            sampleRate: original.sampleRate,
            channelCount: original.channelCount,
            duration: original.duration
        )
        newFile.bpm = original.bpm
        newFile.key = original.key
        newFile.scale = original.scale

        // Save playback state before reloading
        let wasPlaying = isPlaying
        let pos = currentPosition
        let savedLoopRegion = loopRegion
        let savedLoopEnabled = loopEnabled

        sampleFile = newFile
        waveformData = newFile.waveformData(bucketCount: 4000)
        engine.loadSample(newFile)
        currentPosition = pos
        engine.currentPosition = pos

        // Resume playback if it was playing
        if wasPlaying {
            if savedLoopEnabled, let region = savedLoopRegion {
                engine.setLoop(region, enabled: true)
                // Play from current position within the loop
                let clampedPos = max(region.startSample, min(pos, region.endSample - 1))
                engine.playRegion(LoopRegion(startSample: clampedPos, endSample: region.endSample), loop: false)
                // After this partial plays, it will loop the full region
                loopRegion = savedLoopRegion
                loopEnabled = savedLoopEnabled
                engine.setLoop(region, enabled: true)
                engine.playRegion(region, loop: true)
                currentPosition = clampedPos
            } else {
                engine.play(from: pos)
            }
            isPlaying = true
        }
    }

    /// Apply lo-fi destructively (bakes into the sample permanently)
    func applyLoFiDestructive() {
        guard let sf = sampleFile else { return }

        // Save for undo
        lofiUndoSamples = lofiOriginalSamples ?? sf

        let processed = LoFiProcessor.apply(
            preset: LoFiProcessor.LoFiPreset(
                name: "Custom",
                bitDepth: lofiBitDepth,
                targetSampleRate: lofiSampleRate,
                drive: lofiDrive,
                crackle: lofiCrackle,
                wowFlutter: lofiWowFlutter
            ),
            to: (lofiOriginalSamples ?? sf).samples,
            sampleRate: sf.sampleRate
        )

        var newFile = SampleFile(
            url: sf.url,
            samples: processed,
            sampleRate: sf.sampleRate,
            channelCount: sf.channelCount,
            duration: sf.duration
        )
        newFile.bpm = sf.bpm
        newFile.key = sf.key
        newFile.scale = sf.scale

        // Clear preview state — this is now the real sample
        lofiOriginalSamples = nil
        lofiEnabled = false

        sampleFile = newFile
        waveformData = newFile.waveformData(bucketCount: 4000)
        engine.loadSample(newFile)

        Task {
            let colorData = await Task.detached(priority: .userInitiated) {
                newFile.frequencyColorData(bucketCount: 4000)
            }.value
            self.frequencyColorData = colorData
        }
    }

    func undoLoFi() {
        guard let original = lofiUndoSamples else { return }
        sampleFile = original
        waveformData = original.waveformData(bucketCount: 4000)
        engine.loadSample(original)
        lofiUndoSamples = nil
        lofiOriginalSamples = nil
        lofiEnabled = false

        Task {
            let colorData = await Task.detached(priority: .userInitiated) {
                original.frequencyColorData(bucketCount: 4000)
            }.value
            self.frequencyColorData = colorData
        }
    }

    var canUndoLoFi: Bool {
        lofiUndoSamples != nil
    }

    // MARK: - Helpers

    func sampleToSeconds(_ sample: Int) -> Double {
        guard let sr = sampleFile?.sampleRate, sr > 0 else { return 0 }
        return Double(sample) / sr
    }

    func secondsToSample(_ seconds: Double) -> Int {
        guard let sr = sampleFile?.sampleRate else { return 0 }
        return Int(seconds * sr)
    }

    var currentTimeString: String {
        let seconds = sampleToSeconds(currentPosition)
        let mins = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%05.2f", mins, secs)
    }

    var durationString: String {
        sampleFile?.formattedDuration ?? "0:00"
    }

    /// Loop region expressed as bar range, e.g. "Bar 3.1 → Bar 5.1 (2 bars)"
    /// Uses the same grid-relative calculation as the waveform ruler
    var loopBarRangeString: String? {
        guard let region = loopRegion, let sf = sampleFile, let bpm = sf.bpm, bpm > 0 else { return nil }
        let samplesPerBeat = sf.sampleRate * 60.0 / Double(bpm)
        let gridStart = Double(gridOffsetSamples)

        // Calculate beat positions relative to grid (same math as ruler)
        let startBeatTotal = max(0, (Double(region.startSample) - gridStart)) / samplesPerBeat
        let endBeatTotal = max(0, (Double(region.endSample) - gridStart)) / samplesPerBeat
        let durationBars = (endBeatTotal - startBeatTotal) / 4.0

        // Bar.Beat format: bar starts at 1, beat within bar starts at 1
        let startBar = Int(floor(startBeatTotal / 4.0)) + 1
        let startBeatInBar = Int(floor(startBeatTotal.truncatingRemainder(dividingBy: 4.0))) + 1
        let endBar = Int(floor(endBeatTotal / 4.0)) + 1
        let endBeatInBar = Int(floor(endBeatTotal.truncatingRemainder(dividingBy: 4.0))) + 1

        return "Bar \(startBar).\(startBeatInBar) → \(endBar).\(endBeatInBar) (\(String(format: "%.1f", durationBars)) bars)"
    }
}
