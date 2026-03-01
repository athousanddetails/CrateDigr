import Foundation

enum DrumLoopGenre: String, CaseIterable, Identifiable, Codable {
    case boombap = "Boom-bap"
    case techno = "Techno"
    case house = "House"
    case simpleKick = "Kick"
    case user = "User"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .boombap: return "headphones"
        case .techno: return "bolt.fill"
        case .house: return "music.note.house"
        case .simpleKick: return "circle.fill"
        case .user: return "folder"
        }
    }
}

struct DrumLoop: Identifiable, Equatable {
    let id: String
    let name: String
    let genre: DrumLoopGenre
    let originalBPM: Double
    let url: URL
    let attribution: String  // empty for CC0 or user loops

    static func == (lhs: DrumLoop, rhs: DrumLoop) -> Bool {
        lhs.id == rhs.id
    }

    /// Load bundled drum loops from the loops.json manifest in the app bundle
    static func loadBundled() -> [DrumLoop] {
        guard let loopsDir = bundledLoopsDirectory() else {
            print("DrumLoops directory not found in bundle")
            return []
        }

        let manifestURL = loopsDir.appendingPathComponent("loops.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            print("loops.json not found at \(manifestURL.path)")
            return []
        }

        guard let entries = try? JSONDecoder().decode([LoopManifestEntry].self, from: data) else {
            print("Failed to decode loops.json")
            return []
        }

        return entries.compactMap { entry in
            let fileURL = loopsDir.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("Loop file not found: \(entry.file)")
                return nil
            }
            let genre = DrumLoopGenre(rawValue: entry.genre) ?? .user
            return DrumLoop(
                id: entry.id,
                name: entry.name,
                genre: genre,
                originalBPM: entry.bpm,
                url: fileURL,
                attribution: entry.attribution
            )
        }
    }

    /// Get the bundled DrumLoops directory URL
    private static func bundledLoopsDirectory() -> URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif

        return bundle.resourceURL?
            .appendingPathComponent("Binaries")
            .appendingPathComponent("DrumLoops")
    }
}

// MARK: - JSON Manifest Entry

private struct LoopManifestEntry: Codable {
    let id: String
    let name: String
    let genre: String
    let bpm: Double
    let file: String
    let attribution: String
}
