import Foundation

enum DownloadStatus: Equatable {
    case queued          // Added to queue, won't start until user triggers "Download All"
    case waiting         // Ready to start, will auto-start when a slot is available
    case fetchingMetadata
    case downloading
    case converting
    case analyzing       // Detecting BPM and Key
    case done
    case error(message: String)

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .waiting: return "Waiting"
        case .fetchingMetadata: return "Fetching Info"
        case .downloading: return "Downloading"
        case .converting: return "Converting"
        case .analyzing: return "Analyzing"
        case .done: return "Done"
        case .error: return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "list.bullet"
        case .waiting: return "clock"
        case .fetchingMetadata: return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .converting: return "waveform"
        case .analyzing: return "tuningfork"
        case .done: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var isActive: Bool {
        switch self {
        case .fetchingMetadata, .downloading, .converting, .analyzing: return true
        default: return false
        }
    }

    var isFinished: Bool {
        switch self {
        case .done, .error: return true
        default: return false
        }
    }
}
