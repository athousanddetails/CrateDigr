import Foundation

enum BinaryError: LocalizedError {
    case notFound(name: String)
    case notExecutable(name: String)
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "\(name) binary not found in app bundle"
        case .notExecutable(let name):
            return "\(name) binary is not executable"
        case .updateFailed(let msg):
            return "Update failed: \(msg)"
        }
    }
}

struct BundledBinaryManager {

    private static var resourceBundle: Bundle {
        // SPM generates Bundle.module for resource bundles
        // For Xcode projects, Bundle.main is used
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    // MARK: - Local binary directory (updatable)

    private static var localBinariesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CrateDigr")
            .appendingPathComponent("Binaries")
    }

    private static var localYtdlpURL: URL {
        localBinariesDir.appendingPathComponent("yt-dlp")
    }

    private static var localDenoURL: URL {
        localBinariesDir.appendingPathComponent("deno")
    }

    // MARK: - Bundled binary paths (read-only fallback)

    private static var bundledYtdlpURL: URL {
        resourceBundle.resourceURL!
            .appendingPathComponent("Binaries")
            .appendingPathComponent("yt-dlp")
    }

    private static var bundledDenoURL: URL {
        resourceBundle.resourceURL!
            .appendingPathComponent("Binaries")
            .appendingPathComponent("deno")
    }

    /// Prefer local (updated) yt-dlp over bundled one
    static var ytdlpURL: URL {
        let local = localYtdlpURL
        if FileManager.default.isExecutableFile(atPath: local.path) {
            return local
        }
        return bundledYtdlpURL
    }

    /// Prefer local (updated) deno over bundled one
    static var denoURL: URL {
        let local = localDenoURL
        if FileManager.default.isExecutableFile(atPath: local.path) {
            return local
        }
        return bundledDenoURL
    }

    static var ffmpegURL: URL {
        resourceBundle.resourceURL!
            .appendingPathComponent("Binaries")
            .appendingPathComponent("ffmpeg")
    }

    static var demucsURL: URL {
        resourceBundle.resourceURL!
            .appendingPathComponent("Binaries")
            .appendingPathComponent("demucs_mt")
    }

    static var demucsModelURL: URL {
        resourceBundle.resourceURL!
            .appendingPathComponent("Binaries")
            .appendingPathComponent("ggml-model-htdemucs-4s-f16.bin")
    }

    /// Validate that both binaries exist and are executable.
    /// Call at app launch.
    static func validateBinaries() throws {
        try validate(url: ytdlpURL, name: "yt-dlp")
        try validate(url: ffmpegURL, name: "ffmpeg")
    }

    private static func validate(url: URL, name: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw BinaryError.notFound(name: name)
        }
        guard fm.isExecutableFile(atPath: url.path) else {
            throw BinaryError.notExecutable(name: name)
        }
    }

    // MARK: - Version info

    /// Get yt-dlp version string
    static func ytdlpVersion() async -> String {
        do {
            let output = try await ProcessRunner.run(
                executableURL: ytdlpURL,
                arguments: ["--version"]
            )
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Unknown"
        }
    }

    /// Get deno version string
    static func denoVersion() async -> String {
        do {
            let output = try await ProcessRunner.run(
                executableURL: denoURL,
                arguments: ["--version"]
            )
            // deno --version outputs multiple lines, first line is "deno X.Y.Z"
            let firstLine = output.stdout.components(separatedBy: "\n").first ?? ""
            let version = firstLine.replacingOccurrences(of: "deno ", with: "")
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Unknown"
        }
    }

    /// Get ffmpeg version string
    static func ffmpegVersion() async -> String {
        do {
            let output = try await ProcessRunner.run(
                executableURL: ffmpegURL,
                arguments: ["-version"]
            )
            let firstLine = output.stdout.components(separatedBy: "\n").first ?? ""
            return firstLine
        } catch {
            return "Unknown"
        }
    }

    // MARK: - yt-dlp Update

    /// Fetch the latest yt-dlp release info from GitHub
    static func latestYtdlpRelease() async throws -> (version: String, downloadURL: URL) {
        let apiURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BinaryError.updateFailed("GitHub API returned an error")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw BinaryError.updateFailed("Failed to parse GitHub response")
        }

        // Look for the macOS binary asset
        guard let macAsset = assets.first(where: { ($0["name"] as? String) == "yt-dlp_macos" }),
              let downloadURLStr = macAsset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLStr) else {
            throw BinaryError.updateFailed("macOS binary not found in release assets")
        }

        return (version: tagName, downloadURL: downloadURL)
    }

    /// Check if an update is available
    static func isYtdlpUpdateAvailable() async -> (available: Bool, currentVersion: String, latestVersion: String) {
        let current = await ytdlpVersion()
        do {
            let release = try await latestYtdlpRelease()
            let latest = release.version
            return (available: current != latest, currentVersion: current, latestVersion: latest)
        } catch {
            return (available: false, currentVersion: current, latestVersion: "Unknown")
        }
    }

    /// Download and install the latest yt-dlp binary
    static func updateYtdlp(onStatus: @escaping (String) -> Void) async throws {
        onStatus("Fetching release info...")
        let release = try await latestYtdlpRelease()

        onStatus("Downloading yt-dlp \(release.version)...")
        let (tempURL, response) = try await URLSession.shared.download(from: release.downloadURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BinaryError.updateFailed("Download failed")
        }

        // Ensure local binaries directory exists
        let fm = FileManager.default
        try fm.createDirectory(at: localBinariesDir, withIntermediateDirectories: true)

        // Replace existing local binary
        let destination = localYtdlpURL
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)

        // Make executable
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        // Validate the new binary works
        onStatus("Validating...")
        let output = try await ProcessRunner.run(
            executableURL: destination,
            arguments: ["--version"]
        )
        let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, output.exitCode == 0 else {
            // Rollback — remove broken binary so we fall back to bundled
            try? fm.removeItem(at: destination)
            throw BinaryError.updateFailed("Downloaded binary failed validation")
        }

        onStatus("Updated to \(version)")
    }

    // MARK: - Deno Update

    /// Fetch the latest deno release info from GitHub
    static func latestDenoRelease() async throws -> (version: String, downloadURL: URL) {
        let apiURL = URL(string: "https://api.github.com/repos/denoland/deno/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BinaryError.updateFailed("GitHub API returned an error")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw BinaryError.updateFailed("Failed to parse GitHub response")
        }

        // Look for macOS ARM64 binary
        guard let macAsset = assets.first(where: { ($0["name"] as? String) == "deno-aarch64-apple-darwin.zip" }),
              let downloadURLStr = macAsset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLStr) else {
            throw BinaryError.updateFailed("macOS ARM64 deno binary not found in release assets")
        }

        // Strip "v" prefix from tag if present
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        return (version: version, downloadURL: downloadURL)
    }

    /// Check if a deno update is available
    static func isDenoUpdateAvailable() async -> (available: Bool, currentVersion: String, latestVersion: String) {
        let current = await denoVersion()
        do {
            let release = try await latestDenoRelease()
            let latest = release.version
            return (available: current != latest, currentVersion: current, latestVersion: latest)
        } catch {
            return (available: false, currentVersion: current, latestVersion: "Unknown")
        }
    }

    /// Download and install the latest deno binary
    static func updateDeno(onStatus: @escaping (String) -> Void) async throws {
        onStatus("Fetching release info...")
        let release = try await latestDenoRelease()

        onStatus("Downloading deno \(release.version)...")
        let (tempZipURL, response) = try await URLSession.shared.download(from: release.downloadURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BinaryError.updateFailed("Download failed")
        }

        // Ensure local binaries directory exists
        let fm = FileManager.default
        try fm.createDirectory(at: localBinariesDir, withIntermediateDirectories: true)

        // Unzip the downloaded archive (deno is distributed as a zip)
        let tempExtractDir = fm.temporaryDirectory.appendingPathComponent("deno_extract_\(UUID().uuidString)")
        try fm.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempExtractDir) }

        onStatus("Extracting...")
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-o", tempZipURL.path, "deno", "-d", tempExtractDir.path]
        unzipProcess.standardOutput = FileHandle.nullDevice
        unzipProcess.standardError = FileHandle.nullDevice
        try unzipProcess.run()
        unzipProcess.waitUntilExit()

        // Clean up the zip
        try? fm.removeItem(at: tempZipURL)

        let extractedBinary = tempExtractDir.appendingPathComponent("deno")
        guard fm.fileExists(atPath: extractedBinary.path) else {
            throw BinaryError.updateFailed("Failed to extract deno binary from zip")
        }

        // Replace existing local binary
        let destination = localDenoURL
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: extractedBinary, to: destination)

        // Make executable
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        // Validate the new binary works
        onStatus("Validating...")
        let output = try await ProcessRunner.run(
            executableURL: destination,
            arguments: ["--version"]
        )
        guard output.exitCode == 0 else {
            // Rollback — remove broken binary so we fall back to bundled
            try? fm.removeItem(at: destination)
            throw BinaryError.updateFailed("Downloaded deno binary failed validation")
        }

        onStatus("Updated to \(release.version)")
    }
}
