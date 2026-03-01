import Foundation

enum FFmpegError: LocalizedError {
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .conversionFailed(let msg): return "Conversion failed: \(msg)"
        }
    }
}

final class FFmpegService {
    private let binaryURL: URL

    init(binaryURL: URL = BundledBinaryManager.ffmpegURL) {
        self.binaryURL = binaryURL
    }

    /// Convert audio file to target format with given settings
    func convert(
        inputPath: URL,
        outputPath: URL,
        format: AudioFormat,
        settings: AudioSettings
    ) async throws {
        var arguments = [
            "-i", inputPath.path,
            "-vn",                  // No video
            "-y",                   // Overwrite output
            "-loglevel", "error"    // Only show errors
        ]

        arguments += buildFormatArguments(format: format, settings: settings)
        arguments.append(outputPath.path)

        let output = try await ProcessRunner.run(
            executableURL: binaryURL,
            arguments: arguments
        )

        guard output.exitCode == 0 else {
            throw FFmpegError.conversionFailed(output.stderr)
        }
    }

    private func buildFormatArguments(format: AudioFormat, settings: AudioSettings) -> [String] {
        let sampleRate = String(settings.sampleRate.rawValue)

        switch format {
        case .wav:
            let codec = settings.bitDepth == .bit16 ? "pcm_s16le" : "pcm_s24le"
            return ["-c:a", codec, "-ar", sampleRate]

        case .mp3:
            return [
                "-c:a", "libmp3lame",
                "-b:a", "\(settings.mp3Bitrate.rawValue)k",
                "-ar", sampleRate
            ]

        case .aiff:
            let codec = settings.bitDepth == .bit16 ? "pcm_s16be" : "pcm_s24be"
            return ["-c:a", codec, "-ar", sampleRate]

        case .flac:
            let sampleFmt = settings.bitDepth == .bit16 ? "s16" : "s32"
            return [
                "-c:a", "flac",
                "-sample_fmt", sampleFmt,
                "-ar", sampleRate
            ]
        }
    }
}
