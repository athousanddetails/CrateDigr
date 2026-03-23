import Foundation
import SwiftUI
import AVFoundation

extension Notification.Name {
    static let sendStemToSampler = Notification.Name("sendStemToSampler")
}

@MainActor
final class StemsViewModel: ObservableObject {
    // MARK: - File Browser
    @Published var browserFolder: URL = AppConstants.defaultOutputFolder
    @Published var audioFiles: [URL] = []
    @Published var selectedBrowserFile: URL?

    // MARK: - Source File
    @Published var sourceFileURL: URL?
    @Published var sourceFilename: String = ""

    // MARK: - Separation State
    @Published var currentJob: StemSeparationJob?
    @Published var isSeparating = false
    @Published var separationProgress: Double = 0
    @Published var statusMessage: String = ""

    // MARK: - Stem Tracks
    @Published var stems: [StemTrack] = []
    @Published var selectedStemIDs: Set<UUID> = []

    // MARK: - Playback
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0

    // MARK: - Services
    private let demucsService = DemucsService()
    let stemEngine = StemPlaybackEngine()
    private var separationTask: Task<Void, Never>?
    private var mixTask: Task<Void, Never>?

    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "aiff", "aif", "flac", "m4a", "ogg", "webm", "opus", "wma"
    ]

    // Keep backward compat — single selected stem ID for legacy callers
    var selectedStemID: UUID? {
        get { selectedStemIDs.first }
        set {
            if let id = newValue {
                selectedStemIDs = [id]
            } else {
                selectedStemIDs = []
            }
        }
    }

    init() {
        stemEngine.onPositionUpdate = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.playbackProgress = progress
            }
        }
        refreshFileList()
    }

    // MARK: - File Browser

    func setBrowserFolder(_ url: URL) {
        browserFolder = url
        refreshFileList()
    }

    func refreshFileList() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: browserFolder,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            audioFiles = []
            return
        }
        audioFiles = contents
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - File Selection

    func selectFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Audio File"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audio,
            .wav,
            .mp3,
            .aiff
        ]

        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url)
        }
    }

    func loadFile(_ url: URL) {
        sourceFileURL = url
        sourceFilename = url.deletingPathExtension().lastPathComponent
        stems = []
        currentJob = nil
        selectedStemIDs = []
        stemEngine.stop()
        isPlaying = false
        playbackProgress = 0
    }

    // MARK: - Multi-Stem Selection

    func toggleStemSelection(_ id: UUID) {
        if selectedStemIDs.contains(id) {
            // Don't deselect if it's the only one
            if selectedStemIDs.count > 1 {
                selectedStemIDs.remove(id)
            }
        } else {
            selectedStemIDs.insert(id)
        }
    }

    /// Mix selected stems into a single temp WAV and load into the sampler
    func loadSelectedStemsIntoSampler(samplerVM: SamplerViewModel) {
        let selected = stems.filter { selectedStemIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        // Single stem — just load directly, no mixing needed
        if selected.count == 1 {
            samplerVM.loadFile(selected[0].fileURL)
            return
        }

        // Multiple stems — mix their audio into a temp file
        mixTask?.cancel()
        mixTask = Task {
            do {
                let mixedURL = try await mixStemsToTempFile(selected)
                guard !Task.isCancelled else { return }
                samplerVM.loadFile(mixedURL)
            } catch {
                NSLog("[StemsVM] Failed to mix stems: \(error)")
            }
        }
    }

    /// Sum multiple stem WAV files into a single temp WAV
    private func mixStemsToTempFile(_ stems: [StemTrack]) async throws -> URL {
        // Read all stem sample data
        var allSamples: [[Float]] = []
        var maxLength = 0
        var sampleRate: Double = 44100
        var channels = 1

        for stem in stems {
            let sf = stem.sampleFile
            // Use left/right channels for stereo preservation
            if sf.channelCount >= 2 {
                channels = 2
            }
            sampleRate = sf.sampleRate
            allSamples.append(sf.samples)  // mono mixdown
            maxLength = max(maxLength, sf.samples.count)
        }

        // Sum all stems (simple additive mix)
        var mixed = [Float](repeating: 0, count: maxLength)
        for samples in allSamples {
            for i in 0..<samples.count {
                mixed[i] += samples[i]
            }
        }

        // Normalize to prevent clipping — find peak and scale if > 1.0
        let peak = mixed.map { abs($0) }.max() ?? 1.0
        if peak > 1.0 {
            let scale = 0.95 / peak
            for i in 0..<mixed.count {
                mixed[i] *= scale
            }
        }

        // Write to temp WAV file
        let tempDir = AppConstants.tempBaseDirectory.appendingPathComponent("stem_mix")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let stemNames = stems.map { $0.stemType.rawValue }.joined(separator: "+")
        let outputURL = tempDir.appendingPathComponent("mix_\(stemNames).wav")

        // Remove old file if exists
        try? FileManager.default.removeItem(at: outputURL)

        // Create AVAudioFile and write
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let audioFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mixed.count))!
        buffer.frameLength = AVAudioFrameCount(mixed.count)

        // Copy mixed samples into buffer
        let channelData = buffer.floatChannelData![0]
        for i in 0..<mixed.count {
            channelData[i] = mixed[i]
        }

        try audioFile.write(from: buffer)

        return outputURL
    }

    // MARK: - Separation

    func startSeparation() {
        guard let inputURL = sourceFileURL else { return }
        guard !isSeparating else { return }

        let job = StemSeparationJob(inputURL: inputURL, model: .htdemucs_4s)
        currentJob = job
        isSeparating = true
        separationProgress = 0
        statusMessage = "Preparing..."

        let tempDir = AppConstants.tempBaseDirectory
            .appendingPathComponent("stems_\(job.id.uuidString)")

        separationTask = Task {
            do {
                NSLog("[Stems] Starting separation for: \(inputURL.path)")
                NSLog("[Stems] Output dir: \(tempDir.path)")

                // First ensure input is WAV — demucs.cpp requires WAV input
                let wavInput = try await ensureWAV(inputURL, tempDir: tempDir)
                NSLog("[Stems] WAV input ready: \(wavInput.path)")

                self.currentJob?.status = .separating
                self.statusMessage = "Separating stems (this may take 30-60 seconds)..."

                let stemURLs = try await demucsService.separate(
                    inputURL: wavInput,
                    outputDir: tempDir,
                    onProgress: { [weak self] progress, desc in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.separationProgress = progress
                            self.statusMessage = desc
                        }
                    }
                )
                NSLog("[Stems] Separation complete, got \(stemURLs.count) stem files")

                guard !Task.isCancelled else { return }

                // Load stem files
                self.currentJob?.status = .loadingStems
                self.statusMessage = "Loading stems..."

                var loadedStems: [StemTrack] = []
                for stemURL in stemURLs {
                    let filename = stemURL.lastPathComponent
                    let stemType = StemType.from(demucsFilename: filename) ?? .other

                    do {
                        let sampleFile = try SampleFile.load(from: stemURL)
                        let waveform = sampleFile.waveformData(bucketCount: 2000)

                        loadedStems.append(StemTrack(
                            stemType: stemType,
                            fileURL: stemURL,
                            sampleFile: sampleFile,
                            waveformData: waveform
                        ))
                    } catch {
                        print("Failed to load stem \(filename): \(error)")
                    }
                }

                // Sort by canonical order
                loadedStems.sort { $0.stemType.sortOrder < $1.stemType.sortOrder }

                self.stems = loadedStems
                self.currentJob?.status = .complete
                self.currentJob?.stems = loadedStems
                self.statusMessage = "Separation complete"
                self.separationProgress = 1.0

                // Load into playback engine
                self.stemEngine.loadStems(loadedStems)

            } catch {
                if !Task.isCancelled {
                    NSLog("[Stems] ERROR: \(error)")
                    self.currentJob?.status = .error(message: error.localizedDescription)
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }

            self.isSeparating = false
        }
    }

    func cancelSeparation() {
        separationTask?.cancel()
        separationTask = nil
        isSeparating = false
        currentJob?.status = .cancelled
        statusMessage = "Cancelled"
    }

    /// Always convert to 44100 Hz stereo 16-bit WAV (demucs.cpp requires exactly 44100 Hz)
    private func ensureWAV(_ url: URL, tempDir: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let wavURL = tempDir.appendingPathComponent("input.wav")

        let output = try await ProcessRunner.run(
            executableURL: BundledBinaryManager.ffmpegURL,
            arguments: [
                "-y", "-i", url.path,
                "-ar", "44100",
                "-ac", "2",
                "-c:a", "pcm_s16le",
                wavURL.path
            ]
        )

        guard output.exitCode == 0 else {
            throw DemucsError.separationFailed("Failed to convert to WAV: \(output.stderr)")
        }

        return wavURL
    }

    // MARK: - Stem Mixer Controls

    func toggleMute(stemID: UUID) {
        guard let idx = stems.firstIndex(where: { $0.id == stemID }) else { return }
        stems[idx].isMuted.toggle()
        updateStemPlayback()
    }

    func toggleSolo(stemID: UUID) {
        guard let idx = stems.firstIndex(where: { $0.id == stemID }) else { return }
        stems[idx].isSoloed.toggle()
        updateStemPlayback()
    }

    func setVolume(stemID: UUID, volume: Float) {
        guard let idx = stems.firstIndex(where: { $0.id == stemID }) else { return }
        stems[idx].volume = volume
        updateStemPlayback()
    }

    private func updateStemPlayback() {
        let anySoloed = stems.contains { $0.isSoloed }
        for (i, stem) in stems.enumerated() {
            let effectiveMute: Bool
            if anySoloed {
                effectiveMute = !stem.isSoloed
            } else {
                effectiveMute = stem.isMuted
            }
            stemEngine.setMutedWithVolume(stemIndex: i, muted: effectiveMute, volume: stem.volume)
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            stemEngine.stop()
            isPlaying = false
        } else {
            stemEngine.play()
            isPlaying = true
        }
    }

    func seekTo(fraction: Double) {
        let frame = AVAudioFramePosition(fraction * Double(stemEngine.totalFrames))
        playbackProgress = fraction
        stemEngine.seek(to: frame)
        if !isPlaying {
            stemEngine.play(from: frame)
            isPlaying = true
        }
    }

    // MARK: - Export

    func exportStem(_ stem: StemTrack) {
        let panel = NSSavePanel()
        panel.title = "Export Stem"
        panel.nameFieldStringValue = "\(sourceFilename)_\(stem.stemType.rawValue).wav"
        panel.allowedContentTypes = [.wav]

        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.copyItem(at: stem.fileURL, to: url)
        }
    }

    func exportAllStems() {
        let panel = NSOpenPanel()
        panel.title = "Export All Stems"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let folder = panel.url {
            for stem in stems {
                let destURL = folder
                    .appendingPathComponent("\(sourceFilename)_\(stem.stemType.rawValue)")
                    .appendingPathExtension("wav")
                try? FileManager.default.copyItem(at: stem.fileURL, to: destURL)
            }
        }
    }

    func sendToSampler(_ stem: StemTrack) {
        NotificationCenter.default.post(
            name: .sendStemToSampler,
            object: nil,
            userInfo: ["url": stem.fileURL]
        )
    }

    // MARK: - New Separation

    func newSeparation() {
        stemEngine.stop()
        isPlaying = false
        playbackProgress = 0
        stems = []
        currentJob = nil
        sourceFileURL = nil
        sourceFilename = ""
        selectedStemIDs = []
        separationProgress = 0
        statusMessage = ""
    }
}
