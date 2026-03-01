import Foundation

struct StemSeparationJob: Identifiable {
    let id = UUID()
    let inputURL: URL
    let inputFilename: String
    let model: DemucsModel
    var status: StemSeparationStatus
    var progress: Double
    var stems: [StemTrack]
    var errorMessage: String?
    let startedAt: Date

    init(inputURL: URL, model: DemucsModel) {
        self.inputURL = inputURL
        self.inputFilename = inputURL.deletingPathExtension().lastPathComponent
        self.model = model
        self.status = .preparing
        self.progress = 0
        self.stems = []
        self.startedAt = Date()
    }
}

enum StemSeparationStatus: Equatable {
    case preparing
    case separating
    case loadingStems
    case complete
    case error(message: String)
    case cancelled

    var displayName: String {
        switch self {
        case .preparing: return "Preparing"
        case .separating: return "Separating"
        case .loadingStems: return "Loading Stems"
        case .complete: return "Complete"
        case .error: return "Error"
        case .cancelled: return "Cancelled"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .separating, .loadingStems: return true
        default: return false
        }
    }
}
