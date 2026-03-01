import SwiftUI

struct StatusBadge: View {
    let status: DownloadStatus

    var body: some View {
        Label(status.displayName, systemImage: status.systemImage)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .queued: return .purple
        case .waiting: return .secondary
        case .fetchingMetadata: return .blue
        case .downloading: return .blue
        case .converting: return .orange
        case .analyzing: return .cyan
        case .done: return .green
        case .error: return .red
        }
    }
}
