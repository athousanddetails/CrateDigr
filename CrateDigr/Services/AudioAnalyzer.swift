import Foundation
import AVFoundation
import Accelerate
import CLibAubio
import CLibKeyFinder

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

    // MARK: - Cached FFT Setup (for BPM detection only — key detection uses libKeyFinder)
    private var fftSetup1024: OpaquePointer?

    init() {
        fftSetup1024 = vDSP_create_fftsetup(vDSP_Length(log2(Float(1024))), FFTRadix(FFT_RADIX2))
    }

    deinit {
        if let setup = fftSetup1024 { vDSP_destroy_fftsetup(setup) }
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

    // MARK: - Key Detection via libKeyFinder (same library Mixxx uses)

    /// libKeyFinder key_t enum mapping: 0=A_MAJOR, 1=A_MINOR, 2=Bb_MAJOR, ...
    private static let keyFinderMap: [(key: String, scale: String)] = [
        ("A", "Major"),   // 0  A_MAJOR
        ("A", "Minor"),   // 1  A_MINOR
        ("Bb", "Major"),  // 2  B_FLAT_MAJOR
        ("Bb", "Minor"),  // 3  B_FLAT_MINOR
        ("B", "Major"),   // 4  B_MAJOR
        ("B", "Minor"),   // 5  B_MINOR
        ("C", "Major"),   // 6  C_MAJOR
        ("C", "Minor"),   // 7  C_MINOR
        ("Db", "Major"),  // 8  D_FLAT_MAJOR
        ("Db", "Minor"),  // 9  D_FLAT_MINOR
        ("D", "Major"),   // 10 D_MAJOR
        ("D", "Minor"),   // 11 D_MINOR
        ("Eb", "Major"),  // 12 E_FLAT_MAJOR
        ("Eb", "Minor"),  // 13 E_FLAT_MINOR
        ("E", "Major"),   // 14 E_MAJOR
        ("E", "Minor"),   // 15 E_MINOR
        ("F", "Major"),   // 16 F_MAJOR
        ("F", "Minor"),   // 17 F_MINOR
        ("Gb", "Major"),  // 18 G_FLAT_MAJOR
        ("Gb", "Minor"),  // 19 G_FLAT_MINOR
        ("G", "Major"),   // 20 G_MAJOR
        ("G", "Minor"),   // 21 G_MINOR
        ("Ab", "Major"),  // 22 A_FLAT_MAJOR
        ("Ab", "Minor"),  // 23 A_FLAT_MINOR
    ]

    private func detectKey(samples: [Float], sampleRate: Double) -> (key: String, scale: String) {
        guard samples.count > 4096 else { return ("C", "Major") }

        let result = samples.withUnsafeBufferPointer { ptr -> Int32 in
            keyfinder_detect_key(ptr.baseAddress, Int32(samples.count), Int32(sampleRate))
        }

        let idx = Int(result)
        if idx >= 0 && idx < Self.keyFinderMap.count {
            return Self.keyFinderMap[idx]
        }
        return ("C", "Major") // SILENCE or error fallback
    }
}
