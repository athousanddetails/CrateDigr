import Foundation
import SwiftUI

@MainActor
final class DownloadManager: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var outputFolder: URL = AppConstants.defaultOutputFolder
    @Published var binariesAvailable = true
    @Published var binaryError: String?

    @AppStorage(AppConstants.maxConcurrentKey)
    var maxConcurrent: Int = AppConstants.defaultMaxConcurrent

    private let ytdlpService = YTDLPService()
    private let ffmpegService = FFmpegService()
    private let audioAnalyzer = AudioAnalyzer()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var lastActivityTime: [UUID: Date] = [:]
    private static let stallTimeout: TimeInterval = 90

    init() {
        loadOutputFolder()
        validateBinaries()
    }

    var hasQueuedItems: Bool {
        items.contains { $0.status == .queued }
    }

    // MARK: - Public API

    /// Add and immediately start downloading
    func addDownload(url: String, format: AudioFormat, settings: AudioSettings) {
        let item = DownloadItem(url: url, format: format, settings: settings)
        items.insert(item, at: 0)
        processQueue()
    }

    /// Add and immediately start downloading multiple URLs
    func addDownloads(urls: [String], format: AudioFormat, settings: AudioSettings) {
        for url in urls {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, URLValidator.isValidYouTubeURL(trimmed) else { continue }
            let item = DownloadItem(url: trimmed, format: format, settings: settings)
            items.insert(item, at: 0)
        }
        processQueue()
    }

    /// Add to queue without starting (queued state)
    func addToQueue(url: String, format: AudioFormat, settings: AudioSettings) {
        var item = DownloadItem(url: url, format: format, settings: settings)
        item.status = .queued
        items.insert(item, at: 0)
    }

    /// Add multiple URLs to queue without starting
    func addMultipleToQueue(urls: [String], format: AudioFormat, settings: AudioSettings) {
        for url in urls {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, URLValidator.isValidYouTubeURL(trimmed) else { continue }
            var item = DownloadItem(url: trimmed, format: format, settings: settings)
            item.status = .queued
            items.insert(item, at: 0)
        }
    }

    /// Start all queued items
    func downloadAll() {
        for index in items.indices {
            if items[index].status == .queued {
                items[index].status = .waiting
            }
        }
        processQueue()
    }

    func cancelDownload(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].status = .error(message: "Cancelled")
            items[index].progress = 0
        }
        processQueue()
    }

    func retryDownload(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .waiting
        items[index].progress = 0
        items[index].errorMessage = nil
        processQueue()
    }

    func removeItem(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        items.removeAll { $0.id == id }
    }

    func clearCompleted() {
        items.removeAll { $0.status == .done }
    }

    func setOutputFolder(_ url: URL) {
        outputFolder = url
        saveOutputFolder(url)
    }

    // MARK: - Queue Management

    private func processQueue() {
        let activeCount = activeTasks.count
        guard activeCount < maxConcurrent else { return }

        let slotsAvailable = maxConcurrent - activeCount
        let waitingItems = items.filter { $0.status == .waiting }

        for item in waitingItems.prefix(slotsAvailable) {
            let itemID = item.id
            let task = Task {
                await self.executeDownload(itemID: itemID)
            }
            activeTasks[item.id] = task
        }
    }

    private func executeDownload(itemID: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }

        let url = items[index].url
        let format = items[index].format
        let settings = items[index].settings

        // Create temp directory for this download
        let tempDir = AppConstants.tempBaseDirectory.appendingPathComponent(itemID.uuidString)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Ensure output folder exists
            try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)

            // Step 1: Fetch metadata (no timeout — can take a while)
            updateStatus(id: itemID, status: .fetchingMetadata)
            appendLog(id: itemID, line: "[yt-dlp] Fetching metadata...")

            let metadata = try await ytdlpService.fetchMetadata(url: url)

            guard !Task.isCancelled else { return }

            updateTitle(id: itemID, title: metadata.title)
            appendLog(id: itemID, line: "[yt-dlp] Title: \(metadata.title)")

            // Step 2: Download audio (with stall watchdog)
            updateStatus(id: itemID, status: .downloading)
            lastActivityTime[itemID] = Date()
            let rawOutputPath = tempDir.appendingPathComponent("audio.%(ext)s")

            let watchdog = Task {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled else { return }
                    if let lastTime = await self.lastActivityTime[itemID],
                       Date().timeIntervalSince(lastTime) > Self.stallTimeout {
                        await self.handleStall(id: itemID)
                        return
                    }
                }
            }

            try await ytdlpService.downloadAudio(
                url: url,
                outputPath: rawOutputPath,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.lastActivityTime[itemID] = Date()
                        self?.updateProgress(id: itemID, progress: progress)
                    }
                },
                onLog: { [weak self] line in
                    Task { @MainActor [weak self] in
                        self?.lastActivityTime[itemID] = Date()
                        self?.appendLog(id: itemID, line: line)
                    }
                }
            )

            watchdog.cancel()

            guard !Task.isCancelled else { return }

            // Find the downloaded file (extension determined by yt-dlp)
            let downloadedFiles = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let downloadedFile = downloadedFiles.first(where: { $0.lastPathComponent.hasPrefix("audio.") }) else {
                throw YTDLPError.downloadFailed("Downloaded file not found in temp directory")
            }

            // Step 3: Convert
            updateStatus(id: itemID, status: .converting)
            updateProgress(id: itemID, progress: 0)
            lastActivityTime[itemID] = Date()

            let sanitizedTitle = URLValidator.sanitizeFilename(metadata.title)
            let convertedPath = tempDir.appendingPathComponent(sanitizedTitle)
                .appendingPathExtension(format.fileExtension)

            try await ffmpegService.convert(
                inputPath: downloadedFile,
                outputPath: convertedPath,
                format: format,
                settings: settings
            )

            guard !Task.isCancelled else { return }

            // Step 4: Analyze BPM & Key
            updateStatus(id: itemID, status: .analyzing)
            lastActivityTime[itemID] = Date()
            var finalFilename = sanitizedTitle

            do {
                let analysis = try await audioAnalyzer.analyze(fileURL: convertedPath)
                finalFilename = "\(sanitizedTitle) [\(analysis.filenameTag)]"
                updateTitle(id: itemID, title: "\(metadata.title) [\(analysis.filenameTag)]")
            } catch {
                // Analysis failure is non-fatal — just use the original title
                print("Audio analysis failed: \(error.localizedDescription)")
            }

            guard !Task.isCancelled else { return }

            // Step 5: Move to output folder
            let finalPath = URLValidator.uniqueFilePath(
                directory: outputFolder,
                filename: finalFilename,
                ext: format.fileExtension
            )

            try fm.moveItem(at: convertedPath, to: finalPath)

            // Done
            updateStatus(id: itemID, status: .done)
            updateProgress(id: itemID, progress: 1.0)
            updateOutputURL(id: itemID, url: finalPath)

        } catch {
            if !Task.isCancelled {
                let message = error.localizedDescription
                updateStatus(id: itemID, status: .error(message: message))
                updateErrorMessage(id: itemID, message: message)
            }
        }

        // Cleanup
        try? fm.removeItem(at: tempDir)
        activeTasks[itemID] = nil
        lastActivityTime[itemID] = nil
        processQueue()
    }

    // MARK: - State Updates

    private func updateStatus(id: UUID, status: DownloadStatus) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].status = status
        }
    }

    private func updateProgress(id: UUID, progress: Double) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].progress = progress
        }
    }

    private func updateTitle(id: UUID, title: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].title = title
        }
    }

    private func updateOutputURL(id: UUID, url: URL) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].outputURL = url
        }
    }

    private func updateErrorMessage(id: UUID, message: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].errorMessage = message
        }
    }

    private func appendLog(id: UUID, line: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].logLines.append(line)
        }
    }

    private func handleStall(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        lastActivityTime[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            // Grab the last meaningful log lines for context
            let recentLogs = items[index].logLines
                .suffix(5)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let detail = recentLogs.isEmpty
                ? "No output received from yt-dlp"
                : "Last output:\n\(recentLogs)"
            let msg = "Download stalled after \(Int(Self.stallTimeout))s of no activity. \(detail)"
            items[index].status = .error(message: msg)
            items[index].errorMessage = msg
            items[index].logLines.append("[timeout] Download stalled — no output for \(Int(Self.stallTimeout))s")
        }
        processQueue()
    }

    // MARK: - Binary Validation

    private func validateBinaries() {
        do {
            try BundledBinaryManager.validateBinaries()
            binariesAvailable = true
            binaryError = nil
        } catch {
            binariesAvailable = false
            binaryError = error.localizedDescription
        }
    }

    // MARK: - Output Folder Persistence

    private func saveOutputFolder(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: AppConstants.outputFolderBookmarkKey)
        } catch {
            // Fallback: just save the path string
            UserDefaults.standard.set(url.path, forKey: AppConstants.outputFolderBookmarkKey + ".path")
        }
    }

    private func loadOutputFolder() {
        if let bookmarkData = UserDefaults.standard.data(forKey: AppConstants.outputFolderBookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                outputFolder = url
                return
            }
        }

        if let pathStr = UserDefaults.standard.string(forKey: AppConstants.outputFolderBookmarkKey + ".path") {
            outputFolder = URL(fileURLWithPath: pathStr)
            return
        }

        outputFolder = AppConstants.defaultOutputFolder
    }

    // MARK: - Temp Cleanup

    func cleanupOrphanedTempFiles() {
        let fm = FileManager.default
        let tempBase = AppConstants.tempBaseDirectory
        guard let contents = try? fm.contentsOfDirectory(at: tempBase, includingPropertiesForKeys: nil) else { return }
        for dir in contents {
            try? fm.removeItem(at: dir)
        }
    }
}
