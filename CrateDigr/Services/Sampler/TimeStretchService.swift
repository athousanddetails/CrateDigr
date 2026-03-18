import Foundation
import AVFoundation

final class TimeStretchService {
    private let ffmpegURL: URL
    private let rubberbandProcessor = RubberbandProcessor()

    init(ffmpegURL: URL = BundledBinaryManager.ffmpegURL) {
        self.ffmpegURL = ffmpegURL
    }

    /// Native Rubberband stretch+pitch for non-turntable modes.
    /// Processes the audio in-memory using our linked Rubberband library.
    /// Falls back to ffmpeg if Rubberband fails.
    func nativeRubberbandExport(
        inputPath: URL,
        outputPath: URL,
        speedRatio: Double,
        pitchSemitones: Double = 0,
        sampleRate: Int = 48000,
        mode: PitchSpeedMode = .independent,
        eqFilter: String? = nil
    ) async throws {
        // Read input file
        let audioFile = try AVAudioFile(forReading: inputPath)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TimeStretchError.failed("Cannot create buffer")
        }
        try audioFile.read(into: buffer)

        // Process through Rubberband
        let pitchCents = Float(pitchSemitones * 100.0)
        if let processed = rubberbandProcessor.processBuffer(buffer, rate: Float(speedRatio), pitchCents: pitchCents, mode: mode) {
            // Write intermediate temp file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("rb_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let outFile = try AVAudioFile(forWriting: tempURL, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true
            ])
            try outFile.write(from: processed)

            // Use ffmpeg for final format conversion + optional EQ
            var arguments = [
                "-i", tempURL.path,
                "-vn", "-y",
                "-loglevel", "error",
                "-ar", String(sampleRate)
            ]
            if let eq = eqFilter {
                arguments += ["-af", eq]
            }
            arguments.append(outputPath.path)

            let output = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
            guard output.exitCode == 0 else {
                throw TimeStretchError.failed(output.stderr)
            }
        } else {
            // Rubberband returned nil (no processing needed or turntable mode) — just convert
            var arguments = [
                "-i", inputPath.path,
                "-vn", "-y",
                "-loglevel", "error",
                "-ar", String(sampleRate)
            ]
            if let eq = eqFilter {
                arguments += ["-af", eq]
            }
            arguments.append(outputPath.path)

            let output = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
            guard output.exitCode == 0 else {
                throw TimeStretchError.failed(output.stderr)
            }
        }
    }

    /// Apply turntable-style speed change (coupled pitch+speed) and export
    func turntableExport(
        inputPath: URL,
        outputPath: URL,
        speedRatio: Double,
        sampleRate: Int = 48000,
        eqFilter: String? = nil
    ) async throws {
        // asetrate trick: declares a new sample rate without resampling, then aresample
        // converts back. Speed factor = declaredRate / actualInputRate.
        //
        // Problem: input file may be at ANY sample rate (44100, 48000, etc).
        // Fix: first aresample to target rate so the input is normalized,
        // then asetrate with (targetRate * speedRatio), then aresample back.
        //
        // speedRatio=0.94 → newRate=45120 → speed = 45120/48000 = 0.94 (slower+lower) ✓
        // speedRatio=1.06 → newRate=50880 → speed = 50880/48000 = 1.06 (faster+higher) ✓
        let newRate = Int(Double(sampleRate) * speedRatio)
        var filter = "aresample=\(sampleRate),asetrate=\(newRate),aresample=\(sampleRate)"
        if let eq = eqFilter {
            filter += ",\(eq)"
        }

        let arguments = [
            "-i", inputPath.path,
            "-af", filter,
            "-ar", String(sampleRate),
            "-vn", "-y",
            "-loglevel", "error",
            outputPath.path
        ]

        let output = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
        guard output.exitCode == 0 else {
            throw TimeStretchError.failed(output.stderr)
        }
    }

    /// Apply independent speed change (pitch preserved) and export.
    /// Uses native Rubberband library for ALL non-turntable modes (beats, complex, texture, independent).
    /// This gives pro-quality results matching Mixxx/Rekordbox.
    func independentExport(
        inputPath: URL,
        outputPath: URL,
        speedRatio: Double,
        pitchSemitones: Double = 0,
        sampleRate: Int = 48000,
        eqFilter: String? = nil,
        mode: PitchSpeedMode = .independent
    ) async throws {
        // Use native Rubberband for all non-turntable modes
        if speedRatio != 1.0 || pitchSemitones != 0 {
            do {
                try await nativeRubberbandExport(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    speedRatio: speedRatio,
                    pitchSemitones: pitchSemitones,
                    sampleRate: sampleRate,
                    mode: mode,
                    eqFilter: eqFilter
                )
                return
            } catch {
                // Fallback to ffmpeg if native Rubberband fails
                print("Native Rubberband failed, falling back to ffmpeg: \(error)")
            }
        }

        // Fallback / no changes needed: just convert format + optional EQ
        var filters: [String] = []
        if let eq = eqFilter {
            filters.append(eq)
        }

        var arguments = [
            "-i", inputPath.path,
            "-vn", "-y",
            "-loglevel", "error",
            "-ar", String(sampleRate)
        ]

        if !filters.isEmpty {
            arguments += ["-af", filters.joined(separator: ",")]
        }

        arguments.append(outputPath.path)

        let output = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
        guard output.exitCode == 0 else {
            throw TimeStretchError.failed(output.stderr)
        }
    }

    enum TimeStretchError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let msg): return "Time stretch failed: \(msg)"
            }
        }
    }
}
