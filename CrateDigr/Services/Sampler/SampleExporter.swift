import Foundation

final class SampleExporter {
    private let ffmpegURL: URL
    private let timeStretch: TimeStretchService

    init(ffmpegURL: URL = BundledBinaryManager.ffmpegURL) {
        self.ffmpegURL = ffmpegURL
        self.timeStretch = TimeStretchService(ffmpegURL: ffmpegURL)
    }

    enum ExportFormat {
        case wav(sampleRate: Int, bitDepth: Int)
        case aiff(sampleRate: Int, bitDepth: Int)
        case flac(sampleRate: Int, bitDepth: Int)

        // Digitakt II preset
        static let digitaktII = ExportFormat.wav(sampleRate: 48000, bitDepth: 16)

        var fileExtension: String {
            switch self {
            case .wav: return "wav"
            case .aiff: return "aiff"
            case .flac: return "flac"
            }
        }

        var sampleRate: Int {
            switch self {
            case .wav(let sr, _), .aiff(let sr, _), .flac(let sr, _): return sr
            }
        }

        var ffmpegArgs: [String] {
            switch self {
            case .wav(let sr, let bits):
                let codec = bits == 24 ? "pcm_s24le" : "pcm_s16le"
                return ["-c:a", codec, "-ar", String(sr)]
            case .aiff(let sr, let bits):
                let codec = bits == 24 ? "pcm_s24be" : "pcm_s16be"
                return ["-c:a", codec, "-ar", String(sr)]
            case .flac(let sr, let bits):
                let fmt = bits == 24 ? "s32" : "s16"
                return ["-c:a", "flac", "-sample_fmt", fmt, "-ar", String(sr)]
            }
        }
    }

    struct LoFiOptions {
        var bitDepth: Int = 12
        var targetSampleRate: Double = 26040
        var drive: Float = 0.2
        var crackle: Float = 0.0
        var wowFlutter: Float = 0.0
    }

    struct ExportOptions {
        var format: ExportFormat = .digitaktII
        var zeroCrossing: Bool = true
        var speedRatio: Double = 1.0
        var pitchSemitones: Double = 0.0
        var pitchSpeedMode: PitchSpeedMode = .independent
        var maxDuration: TimeInterval? = nil  // e.g., 66.0 for Digitakt II
        var mono: Bool = false
        var normalize: Bool = false  // Peak normalize to 0dB
        var eqLow: Float = 0    // dB gain for low shelf (200Hz)
        var eqMid: Float = 0    // dB gain for parametric mid (1kHz)
        var eqHigh: Float = 0   // dB gain for high shelf (5kHz)
        var lofi: LoFiOptions? = nil  // Optional lo-fi processing for export

        var hasEQ: Bool {
            eqLow != 0 || eqMid != 0 || eqHigh != 0
        }

        /// FFmpeg equalizer filter string matching the app's 3-band EQ
        var eqFilterString: String? {
            guard hasEQ else { return nil }
            // ffmpeg superequalizer or use multiple equalizer filters
            // Band 0: Low shelf at 200Hz
            // Band 1: Parametric at 1kHz, width 1.5
            // Band 2: High shelf at 5kHz
            var filters: [String] = []
            if eqLow != 0 {
                filters.append("lowshelf=frequency=200:gain=\(String(format: "%.1f", eqLow))")
            }
            if eqMid != 0 {
                filters.append("equalizer=frequency=1000:width_type=o:width=1.5:gain=\(String(format: "%.1f", eqMid))")
            }
            if eqHigh != 0 {
                filters.append("highshelf=frequency=5000:gain=\(String(format: "%.1f", eqHigh))")
            }
            return filters.joined(separator: ",")
        }
    }

    // MARK: - Export Full File

    func exportFullFile(
        inputPath: URL,
        outputDir: URL,
        filename: String,
        options: ExportOptions
    ) async throws -> URL {
        let outputPath = outputDir.appendingPathComponent(filename)
            .appendingPathExtension(options.format.fileExtension)

        if options.speedRatio != 1.0 || options.pitchSemitones != 0 {
            try await exportWithPitchSpeed(inputPath: inputPath, outputPath: outputPath, options: options)
        } else {
            try await simpleExport(inputPath: inputPath, outputPath: outputPath, options: options)
        }

        // Apply Lo-Fi FX as post-process if enabled
        if let lofi = options.lofi {
            try await applyLoFi(to: outputPath, lofi: lofi, format: options.format)
        }

        return outputPath
    }

    /// Build combined ffmpeg audio filter string from EQ + normalize + any extra filters
    private func buildFilterChain(baseFilters: [String] = [], options: ExportOptions) -> String? {
        var filters = baseFilters
        if let eqFilter = options.eqFilterString {
            filters.append(eqFilter)
        }
        if options.normalize {
            // Peak normalization to -0.1dBTP
            filters.append("loudnorm=I=-14:TP=-0.1:LRA=11")
        }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    // MARK: - Export Region

    func exportRegion(
        inputPath: URL,
        outputDir: URL,
        filename: String,
        startSeconds: Double,
        durationSeconds: Double,
        options: ExportOptions
    ) async throws -> URL {
        let outputPath = outputDir.appendingPathComponent(filename)
            .appendingPathExtension(options.format.fileExtension)

        let needsPitchSpeed = options.speedRatio != 1.0 || options.pitchSemitones != 0

        if needsPitchSpeed {
            // Two-pass: first extract the region to a temp WAV, then apply pitch/speed
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ytw_export_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempPath = tempDir.appendingPathComponent("region.wav")

            defer { try? FileManager.default.removeItem(at: tempDir) }

            // Pass 1: Extract region as lossless WAV
            var cutArgs = [
                "-i", inputPath.path,
                "-ss", String(format: "%.6f", startSeconds),
                "-t", String(format: "%.6f", durationSeconds),
                "-c:a", "pcm_s24le",
                "-vn", "-y",
                "-loglevel", "error",
                tempPath.path
            ]
            if options.mono {
                cutArgs.insert(contentsOf: ["-ac", "1"], at: cutArgs.count - 1)
            }

            let cutOutput = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: cutArgs)
            guard cutOutput.exitCode == 0 else {
                throw ExportError.failed(cutOutput.stderr)
            }

            // Pass 2: Apply pitch/speed to the extracted region
            try await exportWithPitchSpeed(inputPath: tempPath, outputPath: outputPath, options: options)
        } else {
            // Simple single-pass export (no pitch/speed changes)
            var arguments = [
                "-i", inputPath.path,
                "-ss", String(format: "%.6f", startSeconds),
                "-t", String(format: "%.6f", durationSeconds),
                "-vn", "-y",
                "-loglevel", "error"
            ]

            arguments += options.format.ffmpegArgs

            if let filterChain = buildFilterChain(options: options) {
                arguments += ["-af", filterChain]
            }

            if options.mono {
                arguments += ["-ac", "1"]
            }

            arguments.append(outputPath.path)

            let output = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
            guard output.exitCode == 0 else {
                throw ExportError.failed(output.stderr)
            }
        }

        // Apply Lo-Fi FX as post-process if enabled
        if let lofi = options.lofi {
            try await applyLoFi(to: outputPath, lofi: lofi, format: options.format)
        }

        return outputPath
    }

    // MARK: - Export Slices

    func exportSlices(
        inputPath: URL,
        outputDir: URL,
        baseName: String,
        slicePositions: [Int],   // Sample positions
        sampleRate: Double,
        totalSamples: Int,
        options: ExportOptions,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var exportedFiles: [URL] = []

        for i in 0..<slicePositions.count {
            let start = slicePositions[i]
            let end = (i + 1 < slicePositions.count) ? slicePositions[i + 1] : totalSamples

            let startSeconds = Double(start) / sampleRate
            let durationSeconds = Double(end - start) / sampleRate

            // Enforce max duration if set
            let finalDuration: Double
            if let maxDur = options.maxDuration {
                finalDuration = min(durationSeconds, maxDur)
            } else {
                finalDuration = durationSeconds
            }

            let sliceName = "\(baseName)_slice\(String(format: "%02d", i + 1))"
            let url = try await exportRegion(
                inputPath: inputPath,
                outputDir: outputDir,
                filename: sliceName,
                startSeconds: startSeconds,
                durationSeconds: finalDuration,
                options: options
            )
            exportedFiles.append(url)
            onProgress(Double(i + 1) / Double(slicePositions.count))
        }

        return exportedFiles
    }

    // MARK: - Private

    private func simpleExport(inputPath: URL, outputPath: URL, options: ExportOptions) async throws {
        var arguments = [
            "-i", inputPath.path,
            "-vn", "-y",
            "-loglevel", "error"
        ]

        arguments += options.format.ffmpegArgs

        if let filterChain = buildFilterChain(options: options) {
            arguments += ["-af", filterChain]
        }

        if options.mono {
            arguments += ["-ac", "1"]
        }

        if let maxDur = options.maxDuration {
            arguments += ["-t", String(format: "%.6f", maxDur)]
        }

        arguments.append(outputPath.path)

        let output = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
        guard output.exitCode == 0 else {
            throw ExportError.failed(output.stderr)
        }
    }

    private func exportWithPitchSpeed(inputPath: URL, outputPath: URL, options: ExportOptions) async throws {
        switch options.pitchSpeedMode {
        case .turntable:
            try await timeStretch.turntableExport(
                inputPath: inputPath,
                outputPath: outputPath,
                speedRatio: options.speedRatio,
                sampleRate: options.format.sampleRate,
                eqFilter: options.eqFilterString
            )
        case .independent, .beats, .complex, .texture:
            try await timeStretch.independentExport(
                inputPath: inputPath,
                outputPath: outputPath,
                speedRatio: options.speedRatio,
                pitchSemitones: options.pitchSemitones,
                sampleRate: options.format.sampleRate,
                eqFilter: options.eqFilterString,
                mode: options.pitchSpeedMode
            )
        }
    }

    /// Apply Lo-Fi DSP effects to an already-exported audio file (in-place).
    /// Reads the file, applies bit crush / sample rate reduce / saturation / vinyl sim,
    /// then re-encodes back to the same path and format.
    private func applyLoFi(to filePath: URL, lofi: LoFiOptions, format: ExportFormat) async throws {
        // Step 1: Decode to raw float samples via ffmpeg
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytw_lofi_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rawPath = tempDir.appendingPathComponent("raw.f32le")

        // Decode to raw 32-bit float mono/stereo
        let decodeArgs = [
            "-i", filePath.path,
            "-f", "f32le", "-acodec", "pcm_f32le",
            "-ac", "1",    // Process as mono for Lo-Fi DSP
            "-ar", String(format.sampleRate),
            "-y", "-loglevel", "error",
            rawPath.path
        ]
        let decodeOut = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: decodeArgs)
        guard decodeOut.exitCode == 0 else {
            throw ExportError.failed("Lo-Fi decode: \(decodeOut.stderr)")
        }

        // Step 2: Read raw samples
        let rawData = try Data(contentsOf: rawPath)
        var samples = rawData.withUnsafeBytes { ptr -> [Float] in
            let floatPtr = ptr.bindMemory(to: Float.self)
            return Array(floatPtr)
        }

        // Step 3: Apply Lo-Fi DSP
        let preset = LoFiProcessor.LoFiPreset(
            name: "Export",
            bitDepth: lofi.bitDepth,
            targetSampleRate: lofi.targetSampleRate,
            drive: lofi.drive,
            crackle: lofi.crackle,
            wowFlutter: lofi.wowFlutter
        )
        samples = LoFiProcessor.apply(preset: preset, to: samples, sampleRate: Double(format.sampleRate))

        // Step 4: Write processed samples back to raw file
        let processedPath = tempDir.appendingPathComponent("processed.f32le")
        let processedData = samples.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
        try processedData.write(to: processedPath)

        // Step 5: Re-encode to original format (overwrite)
        var encodeArgs = [
            "-f", "f32le", "-ar", String(format.sampleRate), "-ac", "1",
            "-i", processedPath.path,
            "-vn", "-y", "-loglevel", "error"
        ]
        encodeArgs += format.ffmpegArgs
        encodeArgs.append(filePath.path)

        let encodeOut = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: encodeArgs)
        guard encodeOut.exitCode == 0 else {
            throw ExportError.failed("Lo-Fi encode: \(encodeOut.stderr)")
        }
    }

    enum ExportError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let msg): return "Export failed: \(msg)"
            }
        }
    }
}
