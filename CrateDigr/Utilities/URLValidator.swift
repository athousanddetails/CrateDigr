import Foundation

struct URLValidator {
    private static let youtubePattern = #"^(https?://)?(www\.)?(youtube\.com/(watch\?v=|shorts/)|youtu\.be/|music\.youtube\.com/watch\?v=)"#

    static func isValidYouTubeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: youtubePattern, options: .regularExpression) != nil
    }

    /// Sanitize a video title for use as a filename
    static func sanitizeFilename(_ title: String) -> String {
        // Remove characters illegal in macOS filenames
        let illegal = CharacterSet(charactersIn: "/:\\")
        var sanitized = title.components(separatedBy: illegal).joined(separator: "-")

        // Remove leading/trailing whitespace and dots
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        // Truncate to reasonable length
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }

        // Fallback if empty
        if sanitized.isEmpty {
            sanitized = "untitled"
        }

        return sanitized
    }

    /// Generate a unique filename by appending (1), (2), etc. if needed
    static func uniqueFilePath(directory: URL, filename: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(filename).appendingPathExtension(ext)

        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }

        var counter = 1
        repeat {
            candidate = directory
                .appendingPathComponent("\(filename) (\(counter))")
                .appendingPathExtension(ext)
            counter += 1
        } while fm.fileExists(atPath: candidate.path)

        return candidate
    }
}
