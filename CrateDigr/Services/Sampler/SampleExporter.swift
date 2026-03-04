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
        var pan: Float = 0          // -1.0 (L) to +1.0 (R), 0 = center
        var midGain: Float = 0     // dB, -26 to +6
        var sideGain: Float = 0    // dB, -26 to +6
        var msCrossover: Float = 0 // Hz, 0 = disabled (full range M/S)
        var lofi: LoFiOptions? = nil  // Optional lo-fi processing for export

        var hasEQ: Bool {
            eqLow != 0 || eqMid != 0 || eqHigh != 0
        }

        var hasPan: Bool {
            abs(pan) > 0.01
        }

        var hasMidSide: Bool {
            midGain != 0 || sideGain != 0
        }

        /// FFmpeg equalizer filter string matching the app's 3-band EQ
        var eqFilterString: String? {
            guard hasEQ else { return nil }
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

        /// FFmpeg pan filter string for stereo balance
        /// Uses equal-power panning: L_gain = cos(theta), R_gain = sin(theta)
        var panFilterString: String? {
            guard hasPan else { return nil }
            let theta = Double(pan + 1) / 2.0 * .pi / 2.0
            let leftGain = cos(theta)
            let rightGain = sin(theta)
            return "pan=stereo|c0=\(String(format: "%.4f", leftGain))*c0|c1=\(String(format: "%.4f", rightGain))*c1"
        }

        /// FFmpeg Mid/Side processing filter string
        /// Uses stereotools for M/S level control
        var midSideFilterString: String? {
            guard hasMidSide else { return nil }
            // Convert dB to linear
            let midLinear = pow(10.0, Double(midGain) / 20.0)
            let sideLinear = pow(10.0, Double(sideGain) / 20.0)

            if msCrossover > 0 {
                // With crossover: apply M/S only above the crossover frequency
                // This requires a complex filter graph — handled separately
                return nil
            }

            return "stereotools=mlev=\(String(format: "%.4f", midLinear)):slev=\(String(format: "%.4f", sideLinear))"
        }

        /// FFmpeg complex filter graph for M/S with crossover
        /// Returns nil if no crossover or no M/S processing needed
        var midSideComplexFilter: String? {
            guard hasMidSide, msCrossover > 0 else { return nil }
            let midLinear = pow(10.0, Double(midGain) / 20.0)
            let sideLinear = pow(10.0, Double(sideGain) / 20.0)
            let freq = Int(msCrossover)
            // Split into low (untouched) and high (M/S processed), then remix
            return "[0:a]asplit[low][high];[low]lowpass=f=\(freq)[lowout];[high]highpass=f=\(freq),stereotools=mlev=\(String(format: "%.4f", midLinear)):slev=\(String(format: "%.4f", sideLinear))[highout];[lowout][highout]amix=inputs=2:normalize=0"
        }
    }

    // MARK: - Export Full File

    func exportFullFile(
        inputPath: URL,
        outputURL: URL,
        options: ExportOptions
    ) async throws -> URL {
        return try await exportFullFile(inputPath: inputPath, outputPath: outputURL, options: options)
    }

    func exportFullFile(
        inputPath: URL,
        outputDir: URL,
        filename: String,
        options: ExportOptions
    ) async throws -> URL {
        let outputPath = outputDir.appendingPathComponent(filename)
            .appendingPathExtension(options.format.fileExtension)
        return try await exportFullFile(inputPath: inputPath, outputPath: outputPath, options: options)
    }

    private func exportFullFile(
        inputPath: URL,
        outputPath: URL,
        options: ExportOptions
    ) async throws -> URL {
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

    /// Build combined ffmpeg audio filter string from EQ + M/S + Pan + normalize
    /// Order: EQ → Mid/Side → Pan → Normalize
    private func buildFilterChain(baseFilters: [String] = [], options: ExportOptions) -> String? {
        var filters = baseFilters

        // 1. EQ
        if let eqFilter = options.eqFilterString {
            filters.append(eqFilter)
        }

        // 2. Mid/Side (simple, no crossover — crossover uses complex filter graph)
        if let msFilter = options.midSideFilterString {
            filters.append(msFilter)
        }

        // 3. Pan
        if let panFilter = options.panFilterString {
            filters.append(panFilter)
        }

        // 4. Normalize
        if options.normalize {
            // Peak normalization to -0.1dBTP
            filters.append("loudnorm=I=-14:TP=-0.1:LRA=11")
        }

        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    /// Build a complete filter_complex string when M/S crossover is needed.
    /// This incorporates EQ, M/S crossover, pan, and normalize into one graph.
    /// Returns the ffmpeg args: ["-filter_complex", "...", "-map", "[out]"]
    private func buildComplexFilterArgs(options: ExportOptions) -> [String]? {
        guard options.hasMidSide, options.msCrossover > 0 else { return nil }

        let midLinear = pow(10.0, Double(options.midGain) / 20.0)
        let sideLinear = pow(10.0, Double(options.sideGain) / 20.0)
        let freq = Int(options.msCrossover)

        // Build the complex graph: split → lowpass (untouched) + highpass (M/S) → amix → post-filters
        var graph = "[0:a]asplit[mslow][mshigh];"
        graph += "[mslow]lowpass=f=\(freq)[mslowout];"
        graph += "[mshigh]highpass=f=\(freq),stereotools=mlev=\(String(format: "%.4f", midLinear)):slev=\(String(format: "%.4f", sideLinear))[mshighout];"
        graph += "[mslowout][mshighout]amix=inputs=2:normalize=0"

        // Chain additional simple filters after amix
        var postFilters: [String] = []
        if let eqFilter = options.eqFilterString {
            postFilters.append(eqFilter)
        }
        if let panFilter = options.panFilterString {
            postFilters.append(panFilter)
        }
        if options.normalize {
            postFilters.append("loudnorm=I=-14:TP=-0.1:LRA=11")
        }

        if !postFilters.isEmpty {
            graph += "," + postFilters.joined(separator: ",")
        }

        // Tag the final output
        graph += "[msout]"

        return ["-filter_complex", graph, "-map", "[msout]"]
    }

    // MARK: - Export Region

    func exportRegion(
        inputPath: URL,
        outputURL: URL,
        startSeconds: Double,
        durationSeconds: Double,
        options: ExportOptions
    ) async throws -> URL {
        return try await exportRegion(inputPath: inputPath, outputPath: outputURL, startSeconds: startSeconds, durationSeconds: durationSeconds, options: options)
    }

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
        return try await exportRegion(inputPath: inputPath, outputPath: outputPath, startSeconds: startSeconds, durationSeconds: durationSeconds, options: options)
    }

    private func exportRegion(
        inputPath: URL,
        outputPath: URL,
        startSeconds: Double,
        durationSeconds: Double,
        options: ExportOptions
    ) async throws -> URL {
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

            // Use complex filter graph for M/S with crossover, otherwise simple -af chain
            if let complexArgs = buildComplexFilterArgs(options: options) {
                arguments += complexArgs
            } else if let filterChain = buildFilterChain(options: options) {
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

        // Use complex filter graph for M/S with crossover, otherwise simple -af chain
        if let complexArgs = buildComplexFilterArgs(options: options) {
            arguments += complexArgs
        } else if let filterChain = buildFilterChain(options: options) {
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

    /// Build a combined post-processing filter string (EQ + M/S + Pan + Normalize)
    /// for use inside pitch/speed export paths where filters are appended to the chain.
    /// Note: M/S with crossover is NOT supported in this path — it's applied as a post-pass instead.
    private func buildPostFilters(options: ExportOptions) -> String? {
        var parts: [String] = []
        if let eq = options.eqFilterString { parts.append(eq) }
        if let ms = options.midSideFilterString { parts.append(ms) }
        if let pan = options.panFilterString { parts.append(pan) }
        if options.normalize {
            parts.append("loudnorm=I=-14:TP=-0.1:LRA=11")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    private func exportWithPitchSpeed(inputPath: URL, outputPath: URL, options: ExportOptions) async throws {
        let postFilters = buildPostFilters(options: options)

        switch options.pitchSpeedMode {
        case .turntable:
            try await timeStretch.turntableExport(
                inputPath: inputPath,
                outputPath: outputPath,
                speedRatio: options.speedRatio,
                sampleRate: options.format.sampleRate,
                eqFilter: postFilters
            )
        case .independent, .beats, .complex, .texture:
            try await timeStretch.independentExport(
                inputPath: inputPath,
                outputPath: outputPath,
                speedRatio: options.speedRatio,
                pitchSemitones: options.pitchSemitones,
                sampleRate: options.format.sampleRate,
                eqFilter: postFilters,
                mode: options.pitchSpeedMode
            )
        }

        // If M/S with crossover is active, apply it as a post-pass since the complex
        // filter graph can't be combined with pitch/speed filters easily
        if options.hasMidSide && options.msCrossover > 0 {
            try await applyMidSideCrossoverPostPass(to: outputPath, options: options)
        }
    }

    /// Apply M/S crossover processing as a separate post-pass on an already-exported file
    private func applyMidSideCrossoverPostPass(to filePath: URL, options: ExportOptions) async throws {
        guard let complexFilter = options.midSideComplexFilter else { return }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytw_ms_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempPath = tempDir.appendingPathComponent("ms_temp.\(options.format.fileExtension)")

        // Apply the complex M/S crossover filter
        var arguments = [
            "-i", filePath.path,
            "-filter_complex", complexFilter + "[msout]",
            "-map", "[msout]",
            "-vn", "-y",
            "-loglevel", "error"
        ]
        arguments += options.format.ffmpegArgs
        arguments.append(tempPath.path)

        let output = try await ProcessRunner.run(executableURL: ffmpegURL, arguments: arguments)
        guard output.exitCode == 0 else {
            throw ExportError.failed("M/S crossover: \(output.stderr)")
        }

        // Replace original with processed
        try FileManager.default.removeItem(at: filePath)
        try FileManager.default.moveItem(at: tempPath, to: filePath)
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
