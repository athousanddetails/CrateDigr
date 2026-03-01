import Foundation
import AVFoundation

/// Multi-track audio engine that plays all stems simultaneously with per-stem volume/mute
final class StemPlaybackEngine {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var mixers: [AVAudioMixerNode] = []
    private var buffers: [AVAudioPCMBuffer] = []
    private var stemFormats: [AVAudioFormat] = []
    private(set) var isPlaying = false
    private(set) var totalFrames: AVAudioFrameCount = 0
    private var positionTimer: Timer?
    var onPositionUpdate: ((Double) -> Void)?

    var stemCount: Int { players.count }

    func loadStems(_ stems: [StemTrack]) {
        stop()
        engine.stop()

        // Detach previous nodes
        for node in players { engine.detach(node) }
        for node in mixers { engine.detach(node) }
        players.removeAll()
        mixers.removeAll()
        buffers.removeAll()
        stemFormats.removeAll()
        totalFrames = 0

        let mainMixer = engine.mainMixerNode

        for stem in stems {
            let player = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()

            engine.attach(player)
            engine.attach(mixer)

            if let (buffer, format) = loadBuffer(from: stem.fileURL) {
                buffers.append(buffer)
                stemFormats.append(format)
                engine.connect(player, to: mixer, format: format)
                engine.connect(mixer, to: mainMixer, format: format)
                totalFrames = max(totalFrames, buffer.frameLength)
            } else {
                // Create empty buffer as placeholder
                let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
                let emptyBuffer = AVAudioPCMBuffer(pcmFormat: defaultFormat, frameCapacity: 1024)!
                emptyBuffer.frameLength = 1024
                buffers.append(emptyBuffer)
                stemFormats.append(defaultFormat)
                engine.connect(player, to: mixer, format: defaultFormat)
                engine.connect(mixer, to: mainMixer, format: defaultFormat)
            }

            // Apply initial stem settings
            mixer.volume = stem.isMuted ? 0 : stem.volume

            players.append(player)
            mixers.append(mixer)
        }

        do {
            try engine.start()
        } catch {
            print("StemPlaybackEngine: Failed to start engine: \(error)")
        }
    }

    func play(from position: AVAudioFramePosition = 0) {
        guard !players.isEmpty else { return }

        for (i, player) in players.enumerated() {
            guard i < buffers.count else { continue }
            let buffer = buffers[i]

            player.stop()

            if position > 0 && position < AVAudioFramePosition(buffer.frameLength) {
                // Create sub-buffer from position
                let remaining = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - position)
                if let sub = createSubBuffer(from: buffer, startFrame: Int(position), frameCount: Int(remaining)) {
                    player.scheduleBuffer(sub, at: nil)
                }
            } else {
                player.scheduleBuffer(buffer, at: nil)
            }

            player.play()
        }

        isPlaying = true
        startPositionTimer()
    }

    func stop() {
        for player in players {
            player.stop()
        }
        isPlaying = false
        stopPositionTimer()
    }

    func togglePlayback() {
        if isPlaying {
            stop()
        } else {
            play()
        }
    }

    func seek(to position: AVAudioFramePosition) {
        let wasPlaying = isPlaying
        stop()
        if wasPlaying {
            play(from: position)
        }
    }

    func setVolume(stemIndex: Int, volume: Float) {
        guard stemIndex < mixers.count else { return }
        mixers[stemIndex].volume = volume
    }

    func setMuted(stemIndex: Int, muted: Bool) {
        guard stemIndex < mixers.count else { return }
        // Store current volume when muting, restore when unmuting
        mixers[stemIndex].volume = muted ? 0 : 1.0
    }

    func setMutedWithVolume(stemIndex: Int, muted: Bool, volume: Float) {
        guard stemIndex < mixers.count else { return }
        mixers[stemIndex].volume = muted ? 0 : volume
    }

    /// Get current playback position as a fraction (0.0 to 1.0)
    var currentProgress: Double {
        guard let firstPlayer = players.first,
              let nodeTime = firstPlayer.lastRenderTime,
              let playerTime = firstPlayer.playerTime(forNodeTime: nodeTime),
              totalFrames > 0 else { return 0 }
        return Double(playerTime.sampleTime) / Double(totalFrames)
    }

    /// Get sample rate of loaded stems
    var sampleRate: Double {
        stemFormats.first?.sampleRate ?? 44100
    }

    // MARK: - Private

    private func loadBuffer(from url: URL) -> (AVAudioPCMBuffer, AVAudioFormat)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        do {
            try file.read(into: buffer)
            return (buffer, format)
        } catch {
            return nil
        }
    }

    private func createSubBuffer(from source: AVAudioPCMBuffer, startFrame: Int, frameCount: Int) -> AVAudioPCMBuffer? {
        guard frameCount > 0 else { return nil }
        guard let sub = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        sub.frameLength = AVAudioFrameCount(frameCount)

        let channels = Int(source.format.channelCount)
        if let srcFloat = source.floatChannelData, let dstFloat = sub.floatChannelData {
            for ch in 0..<channels {
                memcpy(dstFloat[ch], srcFloat[ch].advanced(by: startFrame), frameCount * MemoryLayout<Float>.size)
            }
        }

        return sub
    }

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.onPositionUpdate?(self.currentProgress)
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    deinit {
        stopPositionTimer()
        engine.stop()
    }
}
