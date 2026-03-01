import Foundation

struct DownloadItem: Identifiable {
    let id: UUID
    let url: String
    var title: String?
    var status: DownloadStatus
    var progress: Double
    var format: AudioFormat
    var settings: AudioSettings
    var outputURL: URL?
    var errorMessage: String?
    var logLines: [String] = []
    let createdAt: Date

    init(
        url: String,
        format: AudioFormat = .wav,
        settings: AudioSettings = AudioSettings()
    ) {
        self.id = UUID()
        self.url = url
        self.title = nil
        self.status = .waiting
        self.progress = 0.0
        self.format = format
        self.settings = settings
        self.outputURL = nil
        self.errorMessage = nil
        self.createdAt = Date()
    }

    var displayTitle: String {
        title ?? url
    }
}
