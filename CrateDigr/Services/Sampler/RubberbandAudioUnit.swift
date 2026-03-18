import Foundation
import AVFoundation
import CLibRubberband

/// Offline Rubberband processor for high-quality pitch/time stretching.
/// Used for export and when applying pitch/speed changes to the audio buffer.
///
/// For real-time playback, AVAudioUnitTimePitch still handles rate/pitch changes
/// (good enough for monitoring). For export/render, Rubberband provides
/// significantly better quality — same approach as Mixxx, Rekordbox, and other
/// pro DJ software (they use Rubberband for offline rendering, not real-time).
final class RubberbandProcessor {

    /// Process an audio buffer through Rubberband offline.
    /// Returns a new buffer with time-stretched and/or pitch-shifted audio.
    ///
    /// - Parameters:
    ///   - buffer: Source audio buffer (stereo or mono)
    ///   - rate: Playback rate (1.0 = normal, 0.5 = half speed, 2.0 = double speed)
    ///   - pitchCents: Pitch shift in cents (100 = 1 semitone)
    ///   - mode: Processing mode (affects transient/formant handling)
    /// - Returns: Processed buffer, or nil on failure/no-op
    func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        rate: Float,
        pitchCents: Float,
        mode: PitchSpeedMode
    ) -> AVAudioPCMBuffer? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let format = buffer.format
        let frameCount = buffer.frameLength
        let channelCount = format.channelCount
        let sr = UInt32(format.sampleRate)

        // Skip if no changes needed
        if abs(rate - 1.0) < 0.001 && abs(pitchCents) < 1.0 { return nil }

        // Turntable mode = coupled speed+pitch (vinyl), doesn't use rubberband
        if mode == .turntable { return nil }

        // Build Rubberband options
        // Option values from rubberband-c.h (as Int32 for RubberBandOptions)
        let rbOffline:       RubberBandOptions = 0x00000000
        let rbThreadAuto:    RubberBandOptions = 0x00000000
        let rbPitchHQ:       RubberBandOptions = 0x02000000
        let rbTransCrisp:    RubberBandOptions = 0x00000000
        let rbTransMixed:    RubberBandOptions = 0x00000100
        let rbTransSmooth:   RubberBandOptions = 0x00000200
        let rbDetPercussive: RubberBandOptions = 0x00000400
        let rbFormPreserved: RubberBandOptions = 0x01000000
        let rbPhaseIndep:    RubberBandOptions = 0x00002000

        var options: RubberBandOptions = rbOffline | rbThreadAuto | rbPitchHQ

        switch mode {
        case .turntable:
            return nil
        case .independent:
            options |= rbTransCrisp
        case .beats:
            options |= rbTransCrisp | rbDetPercussive
        case .complex:
            options |= rbTransMixed | rbFormPreserved
        case .texture:
            options |= rbTransSmooth | rbPhaseIndep
        }

        let timeRatio = Double(1.0 / rate)
        let pitchScale = pow(2.0, Double(pitchCents) / 1200.0)

        guard let state = rubberband_new(sr, channelCount, options, timeRatio, pitchScale) else {
            return nil
        }
        defer { rubberband_delete(state) }

        rubberband_set_expected_input_duration(state, UInt32(frameCount))

        let blockSize = 1024

        // Study phase (required for offline — analyzes the full audio for best results)
        var offset: UInt32 = 0
        while offset < frameCount {
            let count = min(UInt32(blockSize), frameCount - offset)
            var channelPtrs = (0..<Int(channelCount)).map { ch -> UnsafePointer<Float>? in
                UnsafePointer(channelData[ch].advanced(by: Int(offset)))
            }
            channelPtrs.withUnsafeMutableBufferPointer { buf in
                rubberband_study(state, buf.baseAddress!, count, offset + count >= frameCount ? 1 : 0)
            }
            offset += count
        }

        // Process phase
        let estimatedOutput = UInt32(Double(frameCount) * max(timeRatio, 1.0) * 1.2) + 4096
        var outputChannels = (0..<Int(channelCount)).map { _ in
            [Float](repeating: 0, count: Int(estimatedOutput))
        }
        var totalOut: UInt32 = 0

        offset = 0
        while offset < frameCount {
            let count = min(UInt32(blockSize), frameCount - offset)
            let isFinal: Int32 = (offset + count >= frameCount) ? 1 : 0

            var channelPtrs = (0..<Int(channelCount)).map { ch -> UnsafePointer<Float>? in
                UnsafePointer(channelData[ch].advanced(by: Int(offset)))
            }
            channelPtrs.withUnsafeMutableBufferPointer { buf in
                rubberband_process(state, buf.baseAddress!, count, isFinal)
            }

            // Retrieve all available output
            var available = rubberband_available(state)
            while available > 0 {
                let toGet = UInt32(available)

                // Grow output arrays if needed
                let needed = Int(totalOut) + Int(toGet)
                for ch in 0..<Int(channelCount) {
                    if outputChannels[ch].count < needed {
                        outputChannels[ch].append(contentsOf: [Float](repeating: 0, count: needed - outputChannels[ch].count + 4096))
                    }
                }

                var outPtrs = (0..<Int(channelCount)).map { ch -> UnsafeMutablePointer<Float>? in
                    outputChannels[ch].withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: Int(totalOut)) }
                }
                outPtrs.withUnsafeMutableBufferPointer { buf in
                    rubberband_retrieve(state, buf.baseAddress!, toGet)
                }
                totalOut += toGet
                available = rubberband_available(state)
            }

            offset += count
        }

        guard totalOut > 0 else { return nil }

        // Create output buffer
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalOut) else {
            return nil
        }
        outBuffer.frameLength = totalOut

        guard let outChannelData = outBuffer.floatChannelData else { return nil }
        for ch in 0..<Int(channelCount) {
            outputChannels[ch].withUnsafeBufferPointer { src in
                outChannelData[ch].update(from: src.baseAddress!, count: Int(totalOut))
            }
        }

        return outBuffer
    }
}
