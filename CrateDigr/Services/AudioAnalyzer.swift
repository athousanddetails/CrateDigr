import Foundation
import AVFoundation
import Accelerate
import CLibAubio

struct AudioAnalysisResult {
    let bpm: Int
    let key: String       // e.g. "C", "F#", "Bb"
    let scale: String     // "Major" or "Minor"
    let gridOffsetSamples: Int  // Optimal phase offset for beat 1 (sample position)

    var keyString: String {
        "\(key) \(scale)"
    }

    var filenameTag: String {
        "\(bpm)BPM \(key)\(scale == "Minor" ? "m" : "")"
    }
}

final class AudioAnalyzer {

    enum AnalyzerError: LocalizedError {
        case cannotReadFile(String)
        case noAudioData
        case analysisError(String)

        var errorDescription: String? {
            switch self {
            case .cannotReadFile(let path): return "Cannot read audio file: \(path)"
            case .noAudioData: return "No audio data found"
            case .analysisError(let msg): return "Analysis error: \(msg)"
            }
        }
    }

    // MARK: - Cached FFT Setups (created once, reused across all frames)
    private var fftSetup1024: OpaquePointer?   // for BPM detection (windowSize=1024)
    private var fftSetup4096: OpaquePointer?   // for Key detection (windowSize=4096)

    init() {
        fftSetup1024 = vDSP_create_fftsetup(vDSP_Length(log2(Float(1024))), FFTRadix(FFT_RADIX2))
        fftSetup4096 = vDSP_create_fftsetup(vDSP_Length(log2(Float(4096))), FFTRadix(FFT_RADIX2))
    }

    deinit {
        if let setup = fftSetup1024 { vDSP_destroy_fftsetup(setup) }
        if let setup = fftSetup4096 { vDSP_destroy_fftsetup(setup) }
    }

    /// Analyze pre-loaded samples (no file I/O — uses samples already in memory)
    func analyze(samples: [Float], sampleRate: Double) -> AudioAnalysisResult {
        let (bpm, gridOffset) = detectBPM(samples: samples, sampleRate: sampleRate)
        let (key, scale) = detectKey(samples: samples, sampleRate: sampleRate)
        return AudioAnalysisResult(bpm: bpm, key: key, scale: scale, gridOffsetSamples: gridOffset)
    }

    /// Legacy: Analyze from file URL (reads the file)
    func analyze(fileURL: URL) async throws -> AudioAnalysisResult {
        let audioData = try await loadAudioSamples(from: fileURL)
        return analyze(samples: audioData.samples, sampleRate: audioData.sampleRate)
    }

    // MARK: - Audio Loading (legacy, only used by file URL overload)

    private struct AudioData {
        let samples: [Float]
        let sampleRate: Double
    }

    private func loadAudioSamples(from url: URL) async throws -> AudioData {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw AnalyzerError.cannotReadFile(url.path)
        }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard frameCount > 0 else { throw AnalyzerError.noAudioData }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AnalyzerError.analysisError("Cannot create audio buffer")
        }

        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw AnalyzerError.noAudioData
        }

        // Mix to mono if stereo
        let channelCount = Int(format.channelCount)
        var monoSamples = [Float](repeating: 0, count: Int(frameCount))

        if channelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(frameCount)))
        } else {
            for ch in 0..<channelCount {
                let channelPtr = channelData[ch]
                for i in 0..<Int(frameCount) {
                    monoSamples[i] += channelPtr[i]
                }
            }
            let scale = 1.0 / Float(channelCount)
            vDSP_vsmul(monoSamples, 1, [scale], &monoSamples, 1, vDSP_Length(frameCount))
        }

        return AudioData(samples: monoSamples, sampleRate: sampleRate)
    }

    // MARK: - BPM Detection via aubio (tempo detection + beat tracking)

    /// Returns (bpm, gridOffsetSamples) — the detected tempo and optimal phase for beat 1.
    /// Uses aubio's battle-tested tempo detection: adaptive onset detection, autocorrelation
    /// with comb filtering, and causal beat tracking.
    private func detectBPM(samples: [Float], sampleRate: Double) -> (Int, Int) {
        let totalFrames = samples.count
        let hopSize: UInt32 = 512
        let bufSize: UInt32 = 1024
        let sr = UInt32(sampleRate)

        guard totalFrames > Int(bufSize) * 2 else { return (120, 0) }

        // Create aubio tempo detector
        guard let tempo = new_aubio_tempo("default", bufSize, hopSize, sr) else {
            return (120, 0)
        }
        defer { del_aubio_tempo(tempo) }

        // Create input/output buffers
        guard let input = new_fvec(hopSize),
              let output = new_fvec(2) else {
            return (120, 0)
        }
        defer {
            del_fvec(input)
            del_fvec(output)
        }

        // Feed audio through aubio in hop-sized chunks, collect beat positions
        var beatPositions: [Int] = []
        var offset = 0

        while offset + Int(hopSize) <= totalFrames {
            // Copy samples into aubio input buffer
            for i in 0..<Int(hopSize) {
                fvec_set_sample(input, samples[offset + i], UInt32(i))
            }

            // Run tempo detection on this chunk
            aubio_tempo_do(tempo, input, output)

            // Check if a beat was detected (output[0] != 0)
            if fvec_get_sample(output, 0) != 0 {
                let beatSample = Int(aubio_tempo_get_last(tempo))
                beatPositions.append(beatSample)
            }

            offset += Int(hopSize)
        }

        // Get BPM from aubio
        var detectedBPM = Float(aubio_tempo_get_bpm(tempo))

        // If aubio couldn't determine BPM, fall back
        if detectedBPM <= 0 || detectedBPM.isNaN {
            detectedBPM = 120
        }

        // Grid starts at 0 — user can nudge if needed
        let bpmResult = Int(round(detectedBPM))
        return (bpmResult, 0)
    }

    // MARK: - Key Detection via chroma analysis

    private func detectKey(samples: [Float], sampleRate: Double) -> (key: String, scale: String) {
        let windowSize = 4096
        let hopSize = 2048
        let totalFrames = samples.count

        guard totalFrames > windowSize else { return ("C", "Major") }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized, count: windowSize, isHalfWindow: false)

        // Accumulate chroma vector
        var chromaSum = [Float](repeating: 0, count: 12)
        var frameCount = 0

        var frameStart = 0
        while frameStart + windowSize <= totalFrames {
            var frame = Array(samples[frameStart..<frameStart + windowSize])
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(windowSize))

            let magnitudes = computeFFTMagnitudes(frame)
            let chroma = computeChroma(magnitudes: magnitudes, sampleRate: sampleRate, fftSize: windowSize)

            for i in 0..<12 {
                chromaSum[i] += chroma[i]
            }
            frameCount += 1
            frameStart += hopSize
        }

        guard frameCount > 0 else { return ("C", "Major") }

        // Normalize
        for i in 0..<12 {
            chromaSum[i] /= Float(frameCount)
        }

        // Match against key profiles (Krumhansl-Kessler profiles)
        let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

        let noteNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

        var bestCorrelation: Float = -Float.infinity
        var bestKey = 0
        var bestScale = "Major"

        for shift in 0..<12 {
            // Rotate chroma to test each key
            var rotatedChroma = [Float](repeating: 0, count: 12)
            for i in 0..<12 {
                rotatedChroma[i] = chromaSum[(i + shift) % 12]
            }

            // Correlation with major profile
            let majorCorr = pearsonCorrelation(rotatedChroma, majorProfile)
            if majorCorr > bestCorrelation {
                bestCorrelation = majorCorr
                bestKey = shift
                bestScale = "Major"
            }

            // Correlation with minor profile
            let minorCorr = pearsonCorrelation(rotatedChroma, minorProfile)
            if minorCorr > bestCorrelation {
                bestCorrelation = minorCorr
                bestKey = shift
                bestScale = "Minor"
            }
        }

        return (noteNames[bestKey], bestScale)
    }

    // MARK: - DSP Helpers

    private func computeFFTMagnitudes(_ frame: [Float]) -> [Float] {
        let n = frame.count
        let log2n = vDSP_Length(log2(Float(n)))

        // Use cached setup if available, otherwise create a temporary one
        let cachedSetup: OpaquePointer? = (n == 1024) ? fftSetup1024 : (n == 4096) ? fftSetup4096 : nil
        let fftSetup: OpaquePointer
        if let cached = cachedSetup {
            fftSetup = cached
        } else {
            guard let tempSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
                return [Float](repeating: 0, count: n / 2)
            }
            fftSetup = tempSetup
        }

        var realPart = [Float](repeating: 0, count: n / 2)
        var imagPart = [Float](repeating: 0, count: n / 2)

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                frame.withUnsafeBufferPointer { framePtr in
                    framePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                        var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }
        }

        var magnitudes = [Float](repeating: 0, count: n / 2)
        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // Square root for magnitude (not squared magnitude)
        var sqrtMagnitudes = [Float](repeating: 0, count: n / 2)
        var count = Int32(n / 2)
        vvsqrtf(&sqrtMagnitudes, magnitudes, &count)

        // Clean up only if we created a temporary setup
        if cachedSetup == nil {
            vDSP_destroy_fftsetup(fftSetup)
        }

        return sqrtMagnitudes
    }

    private func computeChroma(magnitudes: [Float], sampleRate: Double, fftSize: Int) -> [Float] {
        var chroma = [Float](repeating: 0, count: 12)
        let binFrequencyResolution = sampleRate / Double(fftSize)

        // Map each FFT bin to a chroma bin
        for bin in 1..<magnitudes.count {
            let frequency = Double(bin) * binFrequencyResolution
            guard frequency > 27.5 && frequency < 4186 else { continue } // A0 to C8

            // Convert frequency to pitch class (0-11)
            let midiNote = 12.0 * log2(frequency / 440.0) + 69.0
            let pitchClass = Int(round(midiNote)) % 12
            let normalizedPitchClass = pitchClass < 0 ? pitchClass + 12 : pitchClass

            chroma[normalizedPitchClass] += magnitudes[bin]
        }

        return chroma
    }

    private func pearsonCorrelation(_ x: [Float], _ y: [Float]) -> Float {
        let n = Float(x.count)
        var sumX: Float = 0, sumY: Float = 0
        var sumXY: Float = 0, sumX2: Float = 0, sumY2: Float = 0

        for i in 0..<x.count {
            sumX += x[i]
            sumY += y[i]
            sumXY += x[i] * y[i]
            sumX2 += x[i] * x[i]
            sumY2 += y[i] * y[i]
        }

        let numerator = n * sumXY - sumX * sumY
        let denominator = sqrt((n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY))

        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }
}
