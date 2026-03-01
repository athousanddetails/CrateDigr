import Foundation
import SwiftUI
import AVFoundation

extension Notification.Name {
    static let sendStemToSampler = Notification.Name("sendStemToSampler")
}

@MainActor
final class StemsViewModel: ObservableObject {
    // MARK: - File Browser
    @Published var browserFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music")
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
    @Published var selectedStemID: UUID?

    // MARK: - Playback
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0

    // MARK: - Services
    private let demucsService = DemucsService()
    let stemEngine = StemPlaybackEngine()
    private var separationTask: Task<Void, Never>?

    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "aiff", "aif", "flac", "m4a", "ogg", "webm", "opus", "wma"
    ]

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
        selectedStemID = nil
        stemEngine.stop()
        isPlaying = false
        playbackProgress = 0
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
        selectedStemID = nil
        separationProgress = 0
        statusMessage = ""
    }
}
