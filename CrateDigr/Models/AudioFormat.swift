import Foundation

enum AudioFormat: String, CaseIterable, Codable, Identifiable {
    case wav
    case mp3
    case aiff
    case flac

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }

    var supportsBitDepth: Bool {
        switch self {
        case .wav, .aiff, .flac: return true
        case .mp3: return false
        }
    }

    var supportsBitrate: Bool {
        self == .mp3
    }
}

struct AudioSettings: Codable, Equatable {
    var sampleRate: SampleRate = .rate44100
    var bitDepth: BitDepth = .bit16
    var mp3Bitrate: MP3Bitrate = .kbps320

    enum SampleRate: Int, CaseIterable, Codable, Identifiable {
        case rate44100 = 44100
        case rate48000 = 48000

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .rate44100: return "44.1 kHz"
            case .rate48000: return "48 kHz"
            }
        }
    }

    enum BitDepth: Int, CaseIterable, Codable, Identifiable {
        case bit16 = 16
        case bit24 = 24

        var id: Int { rawValue }

        var displayName: String {
            "\(rawValue)-bit"
        }
    }

    enum MP3Bitrate: Int, CaseIterable, Codable, Identifiable {
        case kbps128 = 128
        case kbps192 = 192
        case kbps256 = 256
        case kbps320 = 320

        var id: Int { rawValue }

        var displayName: String {
            "\(rawValue) kbps"
        }
    }
}
