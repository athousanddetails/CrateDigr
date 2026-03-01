import Foundation

struct VideoMetadata {
    let title: String
    let duration: TimeInterval?
}

enum YTDLPError: LocalizedError {
    case metadataFetchFailed(String)
    case downloadFailed(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .metadataFetchFailed(let msg): return "Failed to fetch metadata: \(msg)"
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .invalidJSON: return "Failed to parse video metadata"
        }
    }
}

final class YTDLPService {
    private let binaryURL: URL
    private let denoURL: URL

    init(binaryURL: URL = BundledBinaryManager.ytdlpURL,
         denoURL: URL = BundledBinaryManager.denoURL) {
        self.binaryURL = binaryURL
        self.denoURL = denoURL
    }

    /// Common yt-dlp arguments to enable the bundled deno JS runtime
    private var jsRuntimeArgs: [String] {
        ["--js-runtimes", "deno:\(denoURL.path)"]
    }

    /// Fetch video metadata without downloading
    func fetchMetadata(url: String) async throws -> VideoMetadata {
        let output = try await ProcessRunner.run(
            executableURL: binaryURL,
            arguments: jsRuntimeArgs + [
                "-j",
                "--no-download",
                "--no-playlist",
                url
            ]
        )

        guard output.exitCode == 0 else {
            throw YTDLPError.metadataFetchFailed(output.stderr)
        }

        guard let data = output.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTDLPError.invalidJSON
        }

        let title = json["title"] as? String ?? "Unknown"
        let duration = json["duration"] as? TimeInterval

        return VideoMetadata(title: title, duration: duration)
    }

    /// Download best audio stream, reporting progress and raw output via callbacks
    func downloadAudio(
        url: String,
        outputPath: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        let exitCode = try await ProcessRunner.runStreaming(
            executableURL: binaryURL,
            arguments: jsRuntimeArgs + [
                "-f", "bestaudio",
                "--no-playlist",
                "--newline",
                "-o", outputPath.path,
                url
            ],
            onOutput: { line in
                onLog(line)

                // Parse progress from yt-dlp output lines like:
                // [download]  45.2% of 3.45MiB at 1.23MiB/s ETA 00:02
                if line.contains("[download]"), line.contains("%") {
                    let components = line.components(separatedBy: CharacterSet.whitespaces)
                    for component in components {
                        if component.hasSuffix("%") {
                            let percentStr = component.replacingOccurrences(of: "%", with: "")
                            if let percent = Double(percentStr) {
                                onProgress(min(percent / 100.0, 1.0))
                            }
                            break
                        }
                    }
                }
            }
        )

        guard exitCode == 0 else {
            throw YTDLPError.downloadFailed("yt-dlp exited with code \(exitCode)")
        }
    }
}
