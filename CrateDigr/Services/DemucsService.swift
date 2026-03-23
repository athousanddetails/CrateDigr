import Foundation

enum DemucsError: LocalizedError {
    case binaryNotFound
    case modelNotFound(String)
    case separationFailed(String)
    case outputNotFound(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Demucs binary not found"
        case .modelNotFound(let path):
            return "Model file not found: \(path)"
        case .separationFailed(let msg):
            return "Stem separation failed: \(msg)"
        case .outputNotFound(let path):
            return "Expected output not found: \(path)"
        case .cancelled:
            return "Separation cancelled"
        }
    }
}

/// Runs demucs.cpp multi-threaded CLI binary for stem separation
final class DemucsService {
    private let binaryURL: URL
    private let modelURL: URL
    private let numThreads: Int

    init(
        binaryURL: URL = BundledBinaryManager.demucsURL,
        modelURL: URL = BundledBinaryManager.demucsModelURL
    ) {
        self.binaryURL = binaryURL
        self.modelURL = modelURL
        // Use performance cores count for optimal speed
        self.numThreads = ProcessInfo.processInfo.activeProcessorCount
    }

    /// Separate an audio file into stems
    /// - Parameters:
    ///   - inputURL: Path to input audio file (WAV)
    ///   - outputDir: Directory to write output stems
    ///   - onProgress: Progress callback (0.0 to 1.0)
    /// - Returns: Array of URLs to separated stem WAV files
    func separate(
        inputURL: URL,
        outputDir: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        let fm = FileManager.default

        NSLog("[DemucsService] Binary: \(binaryURL.path)")
        NSLog("[DemucsService] Model: \(modelURL.path)")
        NSLog("[DemucsService] Input: \(inputURL.path)")
        NSLog("[DemucsService] Output: \(outputDir.path)")

        guard fm.isExecutableFile(atPath: binaryURL.path) else {
            NSLog("[DemucsService] ERROR: Binary not executable at \(binaryURL.path)")
            throw DemucsError.binaryNotFound
        }

        guard fm.fileExists(atPath: modelURL.path) else {
            NSLog("[DemucsService] ERROR: Model not found at \(modelURL.path)")
            throw DemucsError.modelNotFound(modelURL.path)
        }

        // Ensure output directory exists
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // demucs_mt CLI: ./demucs_mt <model_path> <input.wav> <output_dir/> <num_threads>
        let arguments = [
            modelURL.path,
            inputURL.path,
            outputDir.path,
            String(numThreads)
        ]

        NSLog("[DemucsService] Running: \(binaryURL.lastPathComponent) with \(numThreads) threads")

        let outputLock = NSLock()
        var allOutput: [String] = []

        let exitCode = try await ProcessRunner.runStreamingBoth(
            executableURL: binaryURL,
            arguments: arguments,
            onStdoutLine: { line in
                outputLock.lock()
                allOutput.append(line)
                outputLock.unlock()
                NSLog("[DemucsService stdout] %@", line)
                if let progress = self.parseProgress(line) {
                    onProgress(progress, "Separating stems...")
                }
            },
            onStderrLine: { line in
                outputLock.lock()
                allOutput.append(line)
                outputLock.unlock()
                NSLog("[DemucsService stderr] %@", line)
                if let progress = self.parseProgress(line) {
                    onProgress(progress, "Separating stems...")
                }
            }
        )

        NSLog("[DemucsService] Exit code: \(exitCode)")

        guard exitCode == 0 else {
            outputLock.lock()
            let errorOutput = allOutput.suffix(20).joined(separator: "\n")
            outputLock.unlock()
            throw DemucsError.separationFailed(errorOutput)
        }

        // Find output WAV files in the output directory (exclude input.wav if present)
        let outputFiles = try fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" && $0.lastPathComponent != "input.wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        NSLog("[DemucsService] Found \(outputFiles.count) stem files: \(outputFiles.map { $0.lastPathComponent })")

        guard !outputFiles.isEmpty else {
            // demucs.cpp might put files in a subdirectory — check recursively
            let enumerator = fm.enumerator(at: outputDir, includingPropertiesForKeys: nil)
            var wavFiles: [URL] = []
            while let fileURL = enumerator?.nextObject() as? URL {
                if fileURL.pathExtension.lowercased() == "wav" {
                    wavFiles.append(fileURL)
                }
            }

            guard !wavFiles.isEmpty else {
                throw DemucsError.outputNotFound(outputDir.path)
            }

            return wavFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        return outputFiles
    }

    /// Parse progress from demucs.cpp output
    /// demucs.cpp outputs lines like "(50.000%) Time encoder 1"
    private func parseProgress(_ line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Match demucs.cpp format: "(50.000%)" or "(3.846%)"
        if let range = trimmed.range(of: #"\((\d+\.?\d*)%\)"#, options: .regularExpression) {
            let match = String(trimmed[range])
            // Extract number between ( and %)
            let numStr = match.dropFirst().dropLast(2) // remove "(" and "%)"
            if let percent = Double(numStr) {
                return min(percent / 100.0, 1.0)
            }
        }

        // Fallback: match plain percentage "50%" or " 50%|"
        if let percentRange = trimmed.range(of: #"\d+\.?\d*%"#, options: .regularExpression) {
            let percentStr = String(trimmed[percentRange].dropLast())
            if let percent = Double(percentStr) {
                return min(percent / 100.0, 1.0)
            }
        }

        return nil
    }
}
