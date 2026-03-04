import Foundation
import AVFoundation
import CoreAudio

@MainActor
final class SampleEngine: ObservableObject {
    @Published var isPlaying = false
    @Published var currentPosition: Int = 0   // Current playback position in samples
    @Published var playbackRate: Float = 1.0
    @Published var pitchShift: Float = 0.0     // Semitones (independent mode only)

    var mode: PitchSpeedMode = .turntable

    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitchNode = AVAudioUnitTimePitch()
    private var varispeedNode = AVAudioUnitVarispeed()  // True vinyl repitch
    private var eqNode = AVAudioUnitEQ(numberOfBands: 3)
    private var audioBuffer: AVAudioPCMBuffer?
    private var audioFormat: AVAudioFormat?

    private var loopRegion: LoopRegion?
    private var isLooping = false
    private var positionTimer: Timer?
    private var playbackStartSample: Int = 0
    private var scheduleGeneration: Int = 0  // Incremented on each new schedule to ignore stale completions

    // Pad players for MPC-style triggering
    private var padPlayers: [AVAudioPlayerNode] = []
    private let padCount = 16

    // Scrub player (audition without moving playhead)
    private var scrubPlayer = AVAudioPlayerNode()

    // Metronome
    private var metronomePlayer = AVAudioPlayerNode()
    private var metronomeClickHigh: AVAudioPCMBuffer?
    private var metronomeClickLow: AVAudioPCMBuffer?

    // Chromatic keyboard players (each key has its own player + timePitch for independent pitch)
    private var keyPlayers: [(player: AVAudioPlayerNode, timePitch: AVAudioUnitTimePitch)] = []
    private let keyCount = 25  // 2 octaves + 1 (C2 to C4)

    // Beat Overlay (drum loop player)
    private var beatLoopPlayer = AVAudioPlayerNode()
    private var beatLoopTimePitch = AVAudioUnitTimePitch()
    private var beatLoopBuffer: AVAudioPCMBuffer?
    private var beatLoopFormat: AVAudioFormat?
    private var beatLoopGeneration: Int = 0
    private(set) var isBeatLoopPlaying = false

    private var deviceChangeObserver: NSObjectProtocol?

    init() {
        setupEngine()
        applyStoredOutputDevice()
        listenForDeviceChanges()
    }

    // MARK: - Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(timePitchNode)
        engine.attach(varispeedNode)
        engine.attach(eqNode)
        setupEQBands()

        // Create pad players
        for _ in 0..<padCount {
            let padPlayer = AVAudioPlayerNode()
            engine.attach(padPlayer)
            padPlayers.append(padPlayer)
        }

        // Scrub player (cue audition)
        engine.attach(scrubPlayer)

        // Chromatic keyboard players
        for _ in 0..<keyCount {
            let player = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            engine.attach(player)
            engine.attach(timePitch)
            keyPlayers.append((player: player, timePitch: timePitch))
        }

        // Metronome player
        engine.attach(metronomePlayer)

        // Beat overlay player + timePitch for tempo sync
        engine.attach(beatLoopPlayer)
        engine.attach(beatLoopTimePitch)
    }

    // MARK: - Output Device

    /// Apply the stored output device preference from UserDefaults
    private func applyStoredOutputDevice() {
        let uid = UserDefaults.standard.string(forKey: AppConstants.audioOutputDeviceKey) ?? ""
        if !uid.isEmpty, uid != "system_default" {
            setOutputDevice(uid: uid)
        }
    }

    /// Listen for device changes from SettingsView
    private func listenForDeviceChanges() {
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: AudioDeviceManager.deviceChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.applyStoredOutputDevice()
            }
        }
    }

    /// Set the audio output device by UID. Empty or "system_default" resets to system default.
    func setOutputDevice(uid: String) {
        guard let audioUnit = engine.outputNode.audioUnit else { return }

        if uid.isEmpty || uid == "system_default" {
            // Reset to system default
            let defaultID = AudioDeviceManager.getDefaultOutputDeviceID()
            _ = AudioDeviceManager.setOutputDevice(defaultID, on: audioUnit)
        } else {
            // Find device by UID
            let devices = AudioDeviceManager.getOutputDevices()
            if let device = devices.first(where: { $0.uid == uid }) {
                let wasPlaying = isPlaying
                if wasPlaying { engine.pause() }
                _ = AudioDeviceManager.setOutputDevice(device.id, on: audioUnit)
                if wasPlaying {
                    do { try engine.start() } catch {
                        print("Failed to restart engine after device change: \(error)")
                    }
                }
            }
        }
    }

    func loadSample(_ sampleFile: SampleFile) {
        stop()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleFile.sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleFile.totalSamples)) else { return }

        buffer.frameLength = AVAudioFrameCount(sampleFile.totalSamples)

        if let channelData = buffer.floatChannelData {
            sampleFile.samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: sampleFile.totalSamples)
            }
        }

        self.audioBuffer = buffer
        self.audioFormat = format

        // Connect nodes based on current mode
        reconnectMainChain(format: format)

        // Connect pad players
        for padPlayer in padPlayers {
            engine.disconnectNodeOutput(padPlayer)
            engine.connect(padPlayer, to: engine.mainMixerNode, format: format)
        }

        // Connect scrub player
        engine.disconnectNodeOutput(scrubPlayer)
        engine.connect(scrubPlayer, to: engine.mainMixerNode, format: format)

        // Connect chromatic key players: player → timePitch → mixer
        for kp in keyPlayers {
            engine.disconnectNodeOutput(kp.player)
            engine.disconnectNodeOutput(kp.timePitch)
            engine.connect(kp.player, to: kp.timePitch, format: format)
            engine.connect(kp.timePitch, to: engine.mainMixerNode, format: format)
        }

        // Connect beat overlay: beatLoopPlayer → beatLoopTimePitch → mixer
        engine.disconnectNodeOutput(beatLoopPlayer)
        engine.disconnectNodeOutput(beatLoopTimePitch)
        if let beatFmt = beatLoopFormat ?? audioFormat {
            engine.connect(beatLoopPlayer, to: beatLoopTimePitch, format: beatFmt)
            engine.connect(beatLoopTimePitch, to: engine.mainMixerNode, format: beatFmt)
        }

        do {
            try engine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
        }

        currentPosition = 0
    }

    // MARK: - Playback

    func play(from position: Int? = nil) {
        guard let buffer = audioBuffer else { return }

        if let pos = position {
            currentPosition = pos
        }

        scheduleGeneration += 1
        let myGeneration = scheduleGeneration

        playerNode.stop()
        updatePitchSpeedNodes()

        let startFrame = AVAudioFramePosition(currentPosition)
        let remainingFrames = AVAudioFrameCount(max(0, Int(buffer.frameLength) - currentPosition))

        guard remainingFrames > 0 else { return }

        playbackStartSample = currentPosition

        guard let segmentBuffer = createSubBuffer(from: buffer, startFrame: Int(startFrame), frameCount: Int(remainingFrames)) else { return }

        playerNode.scheduleBuffer(segmentBuffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Ignore stale completions from previous schedules
                guard self.scheduleGeneration == myGeneration else { return }
                if self.isLooping, let region = self.loopRegion {
                    self.playRegion(region, loop: true)
                } else {
                    self.stop()
                }
            }
        }

        playerNode.play()
        isPlaying = true
        startPositionTracking()
    }

    func playRegion(_ region: LoopRegion, loop: Bool = false) {
        guard let buffer = audioBuffer else { return }

        self.loopRegion = region
        self.isLooping = loop

        scheduleGeneration += 1

        playerNode.stop()
        updatePitchSpeedNodes()

        let startFrame = region.startSample
        let frameCount = region.length

        guard frameCount > 0 else { return }

        playbackStartSample = startFrame

        guard let segmentBuffer = createSubBuffer(from: buffer, startFrame: startFrame, frameCount: frameCount) else { return }

        if loop {
            // Gapless looping — AVFoundation handles seamless repeats internally
            playerNode.scheduleBuffer(segmentBuffer, at: nil, options: .loops, completionHandler: nil)
        } else {
            let myGeneration = scheduleGeneration
            playerNode.scheduleBuffer(segmentBuffer) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.scheduleGeneration == myGeneration else { return }
                    self.stop()
                }
            }
        }

        playerNode.play()
        isPlaying = true
        currentPosition = region.startSample
        startPositionTracking()
    }

    func stop() {
        playerNode.stop()
        isPlaying = false
        isLooping = false
        stopPositionTracking()
    }

    func seek(to position: Int) {
        currentPosition = max(0, position)
        if isPlaying {
            if isLooping, let region = loopRegion {
                // Seeking while looping: clamp to loop region
                let clampedPos = max(region.startSample, min(position, region.endSample - 1))

                scheduleGeneration += 1

                playerNode.stop()
                updatePitchSpeedNodes()
                playbackStartSample = clampedPos
                currentPosition = clampedPos

                guard let buffer = audioBuffer else { return }

                // Schedule remainder (seekPos → end of region) without .loops
                let remainderCount = region.endSample - clampedPos
                guard remainderCount > 0 else { return }
                guard let remainderBuffer = createSubBuffer(from: buffer, startFrame: clampedPos, frameCount: remainderCount) else { return }
                playerNode.scheduleBuffer(remainderBuffer, at: nil, options: [], completionHandler: nil)

                // Then schedule full loop buffer with .loops — plays after remainder finishes
                guard let loopBuffer = createSubBuffer(from: buffer, startFrame: region.startSample, frameCount: region.length) else { return }
                playerNode.scheduleBuffer(loopBuffer, at: nil, options: .loops, completionHandler: nil)

                playerNode.play()
            } else {
                play(from: currentPosition)
            }
        }
    }

    func setLoop(_ region: LoopRegion?, enabled: Bool) {
        self.loopRegion = region
        self.isLooping = enabled
    }

    /// Update loop region while playing — doesn't interrupt current playback,
    /// the new region takes effect on the next loop iteration
    func updateLoopRegion(_ region: LoopRegion) {
        self.loopRegion = region
    }

    /// Seamlessly restart loop playback when loop region changes.
    /// Used when loop size changes and playhead needs to wrap (Traktor/Rekordbox behavior).
    func seamlessLoopRestart(region: LoopRegion, from position: Int) {
        // Delegate to playRegion which uses .loops for gapless repeats.
        // The one-time stop/restart is acceptable for user-initiated loop-resize actions.
        playRegion(region, loop: true)
    }

    // MARK: - Pitch/Speed

    func setRate(_ rate: Float) {
        playbackRate = rate
        updatePitchSpeedNodes()
    }

    func setPitch(_ semitones: Float) {
        pitchShift = semitones
        updatePitchSpeedNodes()
    }

    func setMode(_ newMode: PitchSpeedMode) {
        let oldMode = mode
        mode = newMode
        // Reconnect audio chain if switching to/from turntable
        let wasTurntable = oldMode == .turntable
        let isTurntable = newMode == .turntable
        if wasTurntable != isTurntable, let format = audioFormat {
            reconnectMainChain(format: format)
        }
        updatePitchSpeedNodes()
    }

    /// Reconnects the main playback chain based on mode.
    /// Turntable: player → varispeed → EQ → mixer (true vinyl repitch)
    /// Other modes: player → timePitch → EQ → mixer (phase vocoder)
    private func reconnectMainChain(format: AVAudioFormat) {
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitchNode)
        engine.disconnectNodeOutput(varispeedNode)
        engine.disconnectNodeOutput(eqNode)

        if mode == .turntable {
            engine.connect(playerNode, to: varispeedNode, format: format)
            engine.connect(varispeedNode, to: eqNode, format: format)
        } else {
            engine.connect(playerNode, to: timePitchNode, format: format)
            engine.connect(timePitchNode, to: eqNode, format: format)
        }
        engine.connect(eqNode, to: engine.mainMixerNode, format: format)
        updatePitchSpeedNodes()
    }

    private func updatePitchSpeedNodes() {
        switch mode {
        case .turntable:
            // True vinyl: varispeed changes speed and pitch together like a turntable
            varispeedNode.rate = playbackRate
            // Reset timePitch to neutral (not in the chain, but just in case)
            timePitchNode.rate = 1.0
            timePitchNode.pitch = 0
        case .independent:
            // General purpose: speed and pitch adjustable independently
            timePitchNode.rate = playbackRate
            timePitchNode.pitch = pitchShift * 100
            timePitchNode.overlap = 8
        case .beats:
            // Drums/rhythmic: low overlap preserves transient attacks
            timePitchNode.rate = playbackRate
            timePitchNode.pitch = pitchShift * 100
            timePitchNode.overlap = 4
        case .complex:
            // Full mixes: high overlap = smoother, preserves harmonics
            timePitchNode.rate = playbackRate
            timePitchNode.pitch = pitchShift * 100
            timePitchNode.overlap = 16
        case .texture:
            // Pads/ambient: max overlap for smooth granular stretching
            timePitchNode.rate = playbackRate
            timePitchNode.pitch = pitchShift * 100
            timePitchNode.overlap = 32
        }
    }

    // MARK: - Pad Triggering

    func triggerPad(index: Int, samples: [Float], sampleRate: Double, start: Int, end: Int, muteOthers: Bool = false) {
        guard index < padPlayers.count else { return }

        // Mute other pads if option is enabled
        if muteOthers {
            for (i, player) in padPlayers.enumerated() where i != index {
                player.stop()
            }
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let length = end - start
        guard length > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)) else { return }
        buffer.frameLength = AVAudioFrameCount(length)

        if let channelData = buffer.floatChannelData {
            for i in 0..<length {
                let srcIdx = start + i
                if srcIdx < samples.count {
                    channelData[0][i] = samples[srcIdx]
                }
            }
        }

        let player = padPlayers[index]
        player.stop()
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    // MARK: - Preview Volume

    func setPreviewVolume(_ vol: Float) {
        playerNode.volume = vol
    }

    // MARK: - Scrub / Audition

    /// Play a short snippet from a position without affecting main playhead.
    /// Used for Option+click audition on the waveform.
    func scrubPlay(from position: Int, duration: Double = 0.3) {
        guard let buffer = audioBuffer, let format = audioFormat else { return }
        let endSample = min(Int(buffer.frameLength), position + Int(duration * format.sampleRate))
        let length = endSample - position
        guard length > 0 else { return }
        guard let sub = createSubBuffer(from: buffer, startFrame: position, frameCount: length) else { return }
        scrubPlayer.stop()
        scrubPlayer.scheduleBuffer(sub, at: nil)
        scrubPlayer.play()
    }

    // MARK: - Chromatic Keyboard Playback

    /// Play the loaded sample pitched to a specific semitone offset.
    /// keyIndex: 0-24 (maps to key players), semitones: pitch shift from original.
    /// Optionally plays only a sub-region (start/end sample positions).
    func playKey(keyIndex: Int, semitones: Float, start: Int = 0, end: Int? = nil) {
        guard keyIndex < keyPlayers.count, let buffer = audioBuffer, let format = audioFormat else { return }

        let kp = keyPlayers[keyIndex]

        // Set pitch (chromatic: 100 cents per semitone)
        kp.timePitch.rate = 1.0
        kp.timePitch.pitch = semitones * 100.0

        let startFrame = max(0, start)
        let endFrame = min(Int(buffer.frameLength), end ?? Int(buffer.frameLength))
        let length = endFrame - startFrame
        guard length > 0 else { return }

        guard let sub = createSubBuffer(from: buffer, startFrame: startFrame, frameCount: length) else { return }

        kp.player.stop()
        kp.player.scheduleBuffer(sub, at: nil)
        kp.player.play()
    }

    /// Stop a specific key
    func stopKey(keyIndex: Int) {
        guard keyIndex < keyPlayers.count else { return }
        keyPlayers[keyIndex].player.stop()
    }

    /// Stop all keys
    func stopAllKeys() {
        for kp in keyPlayers {
            kp.player.stop()
        }
    }

    // MARK: - 3-Band EQ (Pioneer DJM-900 style)

    private func setupEQBands() {
        // Band 0: Low shelf — 200Hz (DJM-900 Low knob)
        let low = eqNode.bands[0]
        low.filterType = .lowShelf
        low.frequency = 200
        low.bandwidth = 1.0
        low.gain = 0  // dB, range -26 to +6
        low.bypass = false

        // Band 1: Parametric mid — 1kHz (DJM-900 Mid knob)
        let mid = eqNode.bands[1]
        mid.filterType = .parametric
        mid.frequency = 1000
        mid.bandwidth = 1.5
        mid.gain = 0
        mid.bypass = false

        // Band 2: High shelf — 5kHz (DJM-900 High knob)
        let high = eqNode.bands[2]
        high.filterType = .highShelf
        high.frequency = 5000
        high.bandwidth = 1.0
        high.gain = 0
        high.bypass = false
    }

    /// Set EQ band gain in dB. bandIndex: 0=low, 1=mid, 2=high. Range: -26 to +6
    func setEQBand(_ bandIndex: Int, gain: Float) {
        guard bandIndex >= 0 && bandIndex < 3 else { return }
        eqNode.bands[bandIndex].gain = max(-26, min(6, gain))
    }

    /// Reset all EQ bands to flat (0 dB)
    func resetEQ() {
        for i in 0..<3 {
            eqNode.bands[i].gain = 0
        }
    }

    /// Set stereo pan position (-1.0 = full left, 0 = center, +1.0 = full right)
    func setPan(_ value: Float) {
        playerNode.pan = max(-1, min(1, value))
    }

    // MARK: - Metronome

    func setupMetronome(sampleRate: Double) {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        metronomeClickHigh = synthesizeMetronomeClick(sampleRate: sampleRate, format: format, frequency: 1500, isHigh: true)
        metronomeClickLow = synthesizeMetronomeClick(sampleRate: sampleRate, format: format, frequency: 1000, isHigh: false)

        engine.disconnectNodeOutput(metronomePlayer)
        engine.connect(metronomePlayer, to: engine.mainMixerNode, format: format)
    }

    func triggerMetronome(isDownbeat: Bool, volume: Float = 0.8) {
        guard let buffer = isDownbeat ? metronomeClickHigh : metronomeClickLow else { return }
        metronomePlayer.stop()
        metronomePlayer.volume = volume
        metronomePlayer.scheduleBuffer(buffer, at: nil)
        metronomePlayer.play()
    }

    private func synthesizeMetronomeClick(sampleRate: Double, format: AVAudioFormat, frequency: Double, isHigh: Bool) -> AVAudioPCMBuffer? {
        let duration = 0.03 // Very short click
        let length = Int(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(length)

        guard let data = buffer.floatChannelData else { return nil }
        for i in 0..<length {
            let t = Double(i) / sampleRate
            let osc = sin(2.0 * .pi * frequency * t)
            let env = exp(-t * 200.0) // Very fast decay
            let volume: Double = isHigh ? 0.8 : 0.5
            data[0][i] = Float(osc * env * volume)
        }
        return buffer
    }

    // MARK: - Buffer Helpers

    private func createSubBuffer(from source: AVAudioPCMBuffer, startFrame: Int, frameCount: Int) -> AVAudioPCMBuffer? {
        guard let format = audioFormat else { return nil }
        let count = min(frameCount, Int(source.frameLength) - startFrame)
        guard count > 0 else { return nil }

        guard let sub = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        sub.frameLength = AVAudioFrameCount(count)

        if let srcData = source.floatChannelData, let dstData = sub.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                dstData[ch].update(from: srcData[ch].advanced(by: startFrame), count: count)
            }
        }
        return sub
    }

    // MARK: - Position Tracking

    private func startPositionTracking() {
        stopPositionTracking()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePosition()
            }
        }
    }

    private func stopPositionTracking() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func updatePosition() {
        guard isPlaying, let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }

        let sampleTime = Int(playerTime.sampleTime)

        if isLooping, let region = loopRegion, region.length > 0 {
            // With .loops, sampleTime continuously increments past buffer length.
            // Account for seek offset within the loop (playbackStartSample may differ from region.startSample).
            let offsetInLoop = max(0, playbackStartSample - region.startSample)
            let posInLoop = (offsetInLoop + sampleTime) % region.length
            let newPosition = region.startSample + posInLoop
            if newPosition != currentPosition {
                currentPosition = newPosition
            }
        } else {
            let newPosition = playbackStartSample + sampleTime
            if newPosition != currentPosition {
                currentPosition = max(0, newPosition)
            }
        }
    }

    // MARK: - Beat Overlay (Drum Loop)

    /// The raw samples of the loaded beat loop (for creating offset sub-buffers)
    private var beatLoopSamples: [Float] = []
    private var beatLoopSampleRate: Double = 44100

    /// Load a drum loop into the beat overlay player.
    /// Accepts pre-loaded mono float samples and sample rate.
    func loadBeatLoop(samples: [Float], sampleRate: Double) {
        stopBeatLoop()

        self.beatLoopSamples = samples
        self.beatLoopSampleRate = sampleRate

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        self.beatLoopBuffer = buffer
        self.beatLoopFormat = format

        // Reconnect with correct format
        engine.disconnectNodeOutput(beatLoopPlayer)
        engine.disconnectNodeOutput(beatLoopTimePitch)
        engine.connect(beatLoopPlayer, to: beatLoopTimePitch, format: format)
        engine.connect(beatLoopTimePitch, to: engine.mainMixerNode, format: format)
    }

    /// Start playing the beat loop with phase-aligned sync and turntable-style tempo.
    ///
    /// - rate: targetBPM / loopOriginalBPM (turntable-style: pitch changes with speed like vinyl)
    /// - offsetSeconds: how far into the loop to start (for beat-grid phase alignment).
    ///   The ViewModel calculates this from the current playhead position and beat grid.
    ///   Pass 0 to start from the beginning.
    func playBeatLoop(rate: Float, offsetSeconds: Double = 0) {
        guard !beatLoopSamples.isEmpty else { return }

        beatLoopGeneration += 1
        let myGeneration = beatLoopGeneration

        beatLoopPlayer.stop()

        // Turntable mode: pitch follows speed, like vinyl — zero quality degradation
        beatLoopTimePitch.rate = rate
        beatLoopTimePitch.pitch = rate > 0 ? Float(1200.0 * log2(Double(rate))) : 0

        // Convert offset seconds to sample position within the loop
        let loopTotalSamples = beatLoopSamples.count
        var startOffset = Int(offsetSeconds * beatLoopSampleRate)
        // Wrap to loop length (modulo)
        if loopTotalSamples > 0 && startOffset > 0 {
            startOffset = startOffset % loopTotalSamples
        }
        if startOffset < 0 || startOffset >= loopTotalSamples { startOffset = 0 }

        // If starting from an offset, schedule a partial buffer first, then full loops
        if startOffset > 0 {
            let remaining = loopTotalSamples - startOffset
            if remaining > 0, let format = beatLoopFormat {
                guard let partialBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining)) else { return }
                partialBuffer.frameLength = AVAudioFrameCount(remaining)
                if let channelData = partialBuffer.floatChannelData {
                    beatLoopSamples.withUnsafeBufferPointer { src in
                        channelData[0].update(from: src.baseAddress! + startOffset, count: remaining)
                    }
                }
                beatLoopPlayer.scheduleBuffer(partialBuffer) { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.beatLoopGeneration == myGeneration else { return }
                        guard self.isBeatLoopPlaying, let fullBuffer = self.beatLoopBuffer else { return }
                        self.scheduleBeatLoopBuffer(fullBuffer, generation: myGeneration)
                    }
                }
            }
        } else {
            guard let buffer = beatLoopBuffer else { return }
            scheduleBeatLoopBuffer(buffer, generation: myGeneration)
        }

        beatLoopPlayer.play()
        isBeatLoopPlaying = true
    }

    /// Update the beat loop playback rate in realtime (turntable style).
    /// Called when BPM or speed changes.
    func updateBeatLoopRate(_ rate: Float) {
        beatLoopTimePitch.rate = rate
        beatLoopTimePitch.pitch = rate > 0 ? Float(1200.0 * log2(Double(rate))) : 0
    }

    /// Stop the beat loop
    func stopBeatLoop() {
        beatLoopGeneration += 1  // Invalidate any pending completions
        beatLoopPlayer.stop()
        isBeatLoopPlaying = false
    }

    /// Set beat loop volume (0.0 to 1.0)
    func setBeatLoopVolume(_ vol: Float) {
        beatLoopPlayer.volume = max(0, min(1, vol))
    }

    private func scheduleBeatLoopBuffer(_ buffer: AVAudioPCMBuffer, generation: Int) {
        beatLoopPlayer.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.beatLoopGeneration == generation else { return }
                guard self.isBeatLoopPlaying else { return }
                // Seamlessly schedule the next loop iteration
                self.scheduleBeatLoopBuffer(buffer, generation: generation)
            }
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        stop()
        scrubPlayer.stop()
        stopBeatLoop()
        engine.stop()
    }
}
