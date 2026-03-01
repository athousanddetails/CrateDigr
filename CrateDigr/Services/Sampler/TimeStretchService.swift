import Foundation

final class TimeStretchService {
    private let ffmpegURL: URL

    init(ffmpegURL: URL = BundledBinaryManager.ffmpegURL) {
        self.ffmpegURL = ffmpegURL
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
    /// The `mode` parameter controls the stretch algorithm quality.
    func independentExport(
        inputPath: URL,
        outputPath: URL,
        speedRatio: Double,
        pitchSemitones: Double = 0,
        sampleRate: Int = 48000,
        eqFilter: String? = nil,
        mode: PitchSpeedMode = .independent
    ) async throws {
        var filters: [String] = []

        // Use rubberband for high-quality modes if available, fallback to atempo
        if speedRatio != 1.0 {
            switch mode {
            case .beats:
                // rubberband with transient-preserving settings
                // --transients=crisp --detector=compound --window-short
                let rbFilter = "rubberband=tempo=\(String(format: "%.6f", 1.0/speedRatio)):transients=crisp:detector=compound:window=short"
                filters.append(rbFilter)
            case .complex:
                // rubberband with high-quality settings
                // --window-long for better frequency resolution
                let rbFilter = "rubberband=tempo=\(String(format: "%.6f", 1.0/speedRatio)):transients=mixed:detector=compound:window=long"
                filters.append(rbFilter)
            case .texture:
                // rubberband with smooth/texture settings
                // --transients=smooth for pad-like material
                let rbFilter = "rubberband=tempo=\(String(format: "%.6f", 1.0/speedRatio)):transients=smooth:detector=soft:window=long"
                filters.append(rbFilter)
            default:
                // Standard atempo for independent/turntable modes
                var remaining = speedRatio
                while remaining > 2.0 {
                    filters.append("atempo=2.0")
                    remaining /= 2.0
                }
                while remaining < 0.5 {
                    filters.append("atempo=0.5")
                    remaining /= 0.5
                }
                filters.append("atempo=\(String(format: "%.6f", remaining))")
            }
        }

        // Pitch shift via asetrate + aresample
        if pitchSemitones != 0 {
            switch mode {
            case .beats, .complex, .texture:
                // Use rubberband for pitch shifting too
                let rbPitch = "rubberband=pitch=\(String(format: "%.6f", pow(2.0, pitchSemitones / 12.0)))"
                // If we already have a rubberband filter for tempo, combine; otherwise add
                if !filters.isEmpty && filters.last?.hasPrefix("rubberband=") == true {
                    // Append pitch to existing rubberband filter
                    filters[filters.count - 1] += ":pitch=\(String(format: "%.6f", pow(2.0, pitchSemitones / 12.0)))"
                } else {
                    filters.append(rbPitch)
                }
            default:
                let pitchRatio = pow(2.0, pitchSemitones / 12.0)
                let newRate = Int(Double(sampleRate) * pitchRatio)
                filters.append("asetrate=\(newRate)")
                filters.append("aresample=\(sampleRate)")
            }
        }

        // EQ filters
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

        // If rubberband filter failed (not compiled in), fallback to atempo
        if output.exitCode != 0 {
            let stderr = output.stderr.lowercased()
            if stderr.contains("rubberband") || stderr.contains("no such filter") {
                // Fallback: re-export with standard atempo
                try await independentExportFallback(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    speedRatio: speedRatio,
                    pitchSemitones: pitchSemitones,
                    sampleRate: sampleRate,
                    eqFilter: eqFilter
                )
            } else {
                throw TimeStretchError.failed(output.stderr)
            }
        }
    }

    /// Fallback export using standard atempo when rubberband is not available
    private func independentExportFallback(
        inputPath: URL,
        outputPath: URL,
        speedRatio: Double,
        pitchSemitones: Double,
        sampleRate: Int,
        eqFilter: String?
    ) async throws {
        var filters: [String] = []

        if speedRatio != 1.0 {
            var remaining = speedRatio
            while remaining > 2.0 {
                filters.append("atempo=2.0")
                remaining /= 2.0
            }
            while remaining < 0.5 {
                filters.append("atempo=0.5")
                remaining /= 0.5
            }
            filters.append("atempo=\(String(format: "%.6f", remaining))")
        }

        if pitchSemitones != 0 {
            let pitchRatio = pow(2.0, pitchSemitones / 12.0)
            let newRate = Int(Double(sampleRate) * pitchRatio)
            filters.append("asetrate=\(newRate)")
            filters.append("aresample=\(sampleRate)")
        }

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
