import Foundation

enum DemucsModel: String, CaseIterable, Identifiable {
    case htdemucs_4s
    case htdemucs_6s

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .htdemucs_4s: return "4-Stem (Vocals, Drums, Bass, Other)"
        case .htdemucs_6s: return "6-Stem (+ Guitar, Piano)"
        }
    }

    var shortName: String {
        switch self {
        case .htdemucs_4s: return "4-Stem"
        case .htdemucs_6s: return "6-Stem"
        }
    }

    var modelFilename: String {
        switch self {
        case .htdemucs_4s: return "ggml-model-htdemucs-4s-f16.bin"
        case .htdemucs_6s: return "ggml-model-htdemucs-6s-f16.bin"
        }
    }

    var modelDownloadURL: String {
        "https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/\(modelFilename)"
    }

    /// Expected model file size in bytes (approximate, for progress display)
    var expectedModelSize: Int64 {
        switch self {
        case .htdemucs_4s: return 88_080_384   // ~84 MB
        case .htdemucs_6s: return 57_564_160   // ~55 MB
        }
    }

    var stemTypes: [StemType] {
        switch self {
        case .htdemucs_4s:
            return [.drums, .bass, .other, .vocals]
        case .htdemucs_6s:
            return [.drums, .bass, .other, .vocals, .guitar, .piano]
        }
    }
}
