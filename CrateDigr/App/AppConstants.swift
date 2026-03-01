import Foundation

enum AppConstants {
    static let defaultFormatKey = "defaultFormat"
    static let defaultSampleRateKey = "defaultSampleRate"
    static let defaultBitDepthKey = "defaultBitDepth"
    static let defaultMP3BitrateKey = "defaultMP3Bitrate"
    static let outputFolderBookmarkKey = "outputFolderBookmark"
    static let maxConcurrentKey = "maxConcurrentDownloads"
    static let audioOutputDeviceKey = "audioOutputDeviceUID"

    static let defaultMaxConcurrent = 2
    static let tempDirectoryName = "CrateDigr"

    static var defaultOutputFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music")
            .appendingPathComponent("CrateDigr")
    }

    static var tempBaseDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(tempDirectoryName)
    }

}
