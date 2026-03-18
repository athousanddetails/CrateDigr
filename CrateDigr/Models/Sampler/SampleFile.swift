import Foundation
import AVFoundation
import Accelerate

struct SampleFile: Identifiable {
    let id = UUID()
    let url: URL
    let samples: [Float]           // Mono float samples (mixdown)
    let leftSamples: [Float]       // Left channel (or mono if source is mono)
    let rightSamples: [Float]      // Right channel (or mono if source is mono)
    let sampleRate: Double
    let channelCount: Int
    let duration: TimeInterval
    var bpm: Int?
    var key: String?
    var scale: String?

    var filename: String {
        url.deletingPathExtension().lastPathComponent
    }

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var totalSamples: Int {
        samples.count
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var sampleRateDisplay: String {
        if sampleRate == 44100 { return "44.1kHz" }
        if sampleRate == 48000 { return "48kHz" }
        return "\(Int(sampleRate))Hz"
    }

    var keyDisplay: String? {
        guard let key, let scale else { return nil }
        return "\(key) \(scale)"
    }

    /// Compute downsampled waveform data for display (min/max pairs per bucket)
    /// Uses vDSP for SIMD-accelerated min/max — much faster than scalar loop
    func waveformData(bucketCount: Int) -> [(min: Float, max: Float)] {
        guard !samples.isEmpty, bucketCount > 0 else { return [] }
        let samplesPerBucket = max(1, samples.count / bucketCount)
        var result: [(min: Float, max: Float)] = []
        result.reserveCapacity(bucketCount)

        samples.withUnsafeBufferPointer { ptr in
            let base = ptr.baseAddress!
            for i in 0..<bucketCount {
                let start = i * samplesPerBucket
                let end = min(start + samplesPerBucket, samples.count)
                let count = end - start
                guard count > 0 else {
                    result.append((0, 0))
                    continue
                }
                var minVal: Float = 0
                var maxVal: Float = 0
                vDSP_minv(base + start, 1, &minVal, vDSP_Length(count))
                vDSP_maxv(base + start, 1, &maxVal, vDSP_Length(count))
                result.append((minVal, maxVal))
            }
        }
        return result
    }

    /// Compute per-channel waveform data for stereo display
    func waveformDataStereo(bucketCount: Int) -> [(leftMin: Float, leftMax: Float, rightMin: Float, rightMax: Float)] {
        guard !leftSamples.isEmpty, bucketCount > 0 else { return [] }
        let samplesPerBucket = max(1, leftSamples.count / bucketCount)
        var result: [(leftMin: Float, leftMax: Float, rightMin: Float, rightMax: Float)] = []
        result.reserveCapacity(bucketCount)

        leftSamples.withUnsafeBufferPointer { lPtr in
            rightSamples.withUnsafeBufferPointer { rPtr in
                let lBase = lPtr.baseAddress!
                let rBase = rPtr.baseAddress!
                for i in 0..<bucketCount {
                    let start = i * samplesPerBucket
                    let end = min(start + samplesPerBucket, leftSamples.count)
                    let count = end - start
                    guard count > 0 else { result.append((0, 0, 0, 0)); continue }
                    var lMin: Float = 0, lMax: Float = 0, rMin: Float = 0, rMax: Float = 0
                    vDSP_minv(lBase + start, 1, &lMin, vDSP_Length(count))
                    vDSP_maxv(lBase + start, 1, &lMax, vDSP_Length(count))
                    vDSP_minv(rBase + start, 1, &rMin, vDSP_Length(count))
                    vDSP_maxv(rBase + start, 1, &rMax, vDSP_Length(count))
                    result.append((lMin, lMax, rMin, rMax))
                }
            }
        }
        return result
    }

    /// Rekordbox 3-Band frequency data: returns (low, mid, high) amplitude per bucket
    /// Uses proper IIR filtering with Rekordbox cutoffs:
    ///   Low: 20-200Hz (Blue) — kicks, bass
    ///   Mid: 200-5000Hz (Orange/Amber) — vocals, synths, snares
    ///   High: 5000-20000Hz (White) — hats, cymbals, air
    func frequencyColorData(bucketCount: Int) -> [(low: Float, mid: Float, high: Float)] {
        guard !samples.isEmpty, bucketCount > 0 else { return [] }

        let sr = Float(sampleRate)
        let n = samples.count

        // 4th-order Butterworth (cascade two 2nd-order) = 24dB/oct
        // Sharp separation so mids don't leak into bass band
        let lpCoeffs = biquadLowPass(cutoff: 300.0, sampleRate: sr)   // Bass: 0-300Hz (kick fundamental + body)
        let hpCoeffs = biquadHighPass(cutoff: 4000.0, sampleRate: sr)  // Highs: 4kHz+ (hihats, cymbals)
        let bpLowCoeffs = biquadLowPass(cutoff: 4000.0, sampleRate: sr)
        let bpHighCoeffs = biquadHighPass(cutoff: 300.0, sampleRate: sr)

        // Filter into 3 bands — apply each filter TWICE for 4th-order (24dB/oct)
        var lowBand = [Float](repeating: 0, count: n)
        var lowTemp = [Float](repeating: 0, count: n)
        applyBiquad(input: samples, output: &lowTemp, coeffs: lpCoeffs)
        applyBiquad(input: lowTemp, output: &lowBand, coeffs: lpCoeffs)  // 2nd pass = 24dB/oct

        var midBand = [Float](repeating: 0, count: n)
        var midTemp1 = [Float](repeating: 0, count: n)
        var midTemp2 = [Float](repeating: 0, count: n)
        applyBiquad(input: samples, output: &midTemp1, coeffs: bpHighCoeffs)
        applyBiquad(input: midTemp1, output: &midTemp2, coeffs: bpHighCoeffs)  // 2nd pass HP
        var midTemp3 = [Float](repeating: 0, count: n)
        applyBiquad(input: midTemp2, output: &midTemp3, coeffs: bpLowCoeffs)
        applyBiquad(input: midTemp3, output: &midBand, coeffs: bpLowCoeffs)    // 2nd pass LP

        var highBand = [Float](repeating: 0, count: n)
        var highTemp = [Float](repeating: 0, count: n)
        applyBiquad(input: samples, output: &highTemp, coeffs: hpCoeffs)
        applyBiquad(input: highTemp, output: &highBand, coeffs: hpCoeffs)  // 2nd pass = 24dB/oct

        // Downsample into buckets (peak amplitude per bucket)
        let samplesPerBucket = max(1, n / bucketCount)
        var result: [(low: Float, mid: Float, high: Float)] = []
        result.reserveCapacity(bucketCount)

        // Track per-band global peaks for independent normalization
        var globalLowPeak: Float = 0
        var globalMidPeak: Float = 0
        var globalHighPeak: Float = 0

        var rawBuckets: [(low: Float, mid: Float, high: Float)] = []
        rawBuckets.reserveCapacity(bucketCount)

        lowBand.withUnsafeBufferPointer { lowPtr in
            midBand.withUnsafeBufferPointer { midPtr in
                highBand.withUnsafeBufferPointer { highPtr in
                    let lowBase = lowPtr.baseAddress!
                    let midBase = midPtr.baseAddress!
                    let highBase = highPtr.baseAddress!

                    for i in 0..<bucketCount {
                        let start = i * samplesPerBucket
                        let end = min(start + samplesPerBucket, n)
                        let count = end - start
                        guard count > 0 else {
                            rawBuckets.append((0, 0, 0))
                            continue
                        }
                        var lp: Float = 0, mp: Float = 0, hp: Float = 0
                        vDSP_maxmgv(lowBase + start, 1, &lp, vDSP_Length(count))
                        vDSP_maxmgv(midBase + start, 1, &mp, vDSP_Length(count))
                        vDSP_maxmgv(highBase + start, 1, &hp, vDSP_Length(count))
                        rawBuckets.append((low: lp, mid: mp, high: hp))
                        globalLowPeak = max(globalLowPeak, lp)
                        globalMidPeak = max(globalMidPeak, mp)
                        globalHighPeak = max(globalHighPeak, hp)
                    }
                }
            }
        }

        // Normalize each band independently — kicks always show at full height
        // regardless of how quiet the bass is relative to the mix
        let lowNorm = globalLowPeak > 0.001 ? 1.0 / globalLowPeak : 1.0
        let midNorm = globalMidPeak > 0.001 ? 1.0 / globalMidPeak : 1.0
        let highNorm = globalHighPeak > 0.001 ? 1.0 / globalHighPeak : 1.0

        for b in rawBuckets {
            result.append((low: b.low * lowNorm, mid: b.mid * midNorm, high: b.high * highNorm))
        }

        return result
    }

    // MARK: - Biquad Filter Helpers (2nd-order Butterworth)

    private struct BiquadCoeffs {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    }

    private func biquadLowPass(cutoff: Float, sampleRate: Float) -> BiquadCoeffs {
        let w0 = 2.0 * Float.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * sqrt(2.0)) // Q = sqrt(2)/2 for Butterworth

        let a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0: ((1.0 - cosW0) / 2.0) / a0,
            b1: (1.0 - cosW0) / a0,
            b2: ((1.0 - cosW0) / 2.0) / a0,
            a1: (-2.0 * cosW0) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    private func biquadHighPass(cutoff: Float, sampleRate: Float) -> BiquadCoeffs {
        let w0 = 2.0 * Float.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * sqrt(2.0))

        let a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0: ((1.0 + cosW0) / 2.0) / a0,
            b1: -(1.0 + cosW0) / a0,
            b2: ((1.0 + cosW0) / 2.0) / a0,
            a1: (-2.0 * cosW0) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    private func applyBiquad(input: [Float], output: inout [Float], coeffs: BiquadCoeffs) {
        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0

        for i in 0..<input.count {
            let x0 = input[i]
            let y0 = coeffs.b0 * x0 + coeffs.b1 * x1 + coeffs.b2 * x2
                    - coeffs.a1 * y1 - coeffs.a2 * y2
            output[i] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
    }

    /// Load a SampleFile from a URL
    static func load(from url: URL) throws -> SampleFile {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard frameCount > 0 else {
            throw SampleFileError.empty
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SampleFileError.cannotCreateBuffer
        }

        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw SampleFileError.noData
        }

        let channelCount = Int(format.channelCount)
        let count = Int(frameCount)

        // Store per-channel data
        let leftSamples: [Float]
        let rightSamples: [Float]

        if channelCount == 1 {
            leftSamples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
            rightSamples = leftSamples
        } else {
            leftSamples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
            rightSamples = Array(UnsafeBufferPointer(start: channelData[1], count: count))
        }

        // Mono mixdown
        let monoSamples: [Float]
        if channelCount == 1 {
            monoSamples = leftSamples
        } else {
            var mono = [Float](repeating: 0, count: count)
            for i in 0..<count {
                mono[i] = (leftSamples[i] + rightSamples[i]) * 0.5
            }
            monoSamples = mono
        }

        let duration = Double(frameCount) / format.sampleRate

        return SampleFile(
            url: url,
            samples: monoSamples,
            leftSamples: leftSamples,
            rightSamples: rightSamples,
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            duration: duration
        )
    }

    enum SampleFileError: LocalizedError {
        case empty, cannotCreateBuffer, noData

        var errorDescription: String? {
            switch self {
            case .empty: return "Audio file is empty"
            case .cannotCreateBuffer: return "Cannot create audio buffer"
            case .noData: return "No audio data found"
            }
        }
    }
}
