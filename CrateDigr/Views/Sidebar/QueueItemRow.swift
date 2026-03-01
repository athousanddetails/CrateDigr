import SwiftUI

struct QueueItemRow: View {
    let item: DownloadItem
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title
            Text(item.displayTitle)
                .font(.system(.body, design: .default))
                .fontWeight(.medium)
                .lineLimit(2)
                .truncationMode(.middle)

            // Progress bar (shown during active states)
            if item.status.isActive {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(progressColor)
            }

            // Status + actions
            HStack {
                StatusBadge(status: item.status)

                Spacer()

                // Format badge
                Text(item.format.displayName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())

                // Action buttons
                if item.status.isActive {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }

                if case .error = item.status {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Retry")
                }

                if item.status == .done {
                    Button(action: onReveal) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if case .error = item.status {
                Button("Retry") { onRetry() }
            }
            if item.status == .done, item.outputURL != nil {
                Button("Show in Finder") { onReveal() }
            }
            if item.status.isActive {
                Button("Cancel") { onCancel() }
            }
            Divider()
            Button("Remove", role: .destructive) { onRemove() }
        }
    }

    private var progressColor: Color {
        switch item.status {
        case .converting: return .orange
        default: return .blue
        }
    }
}
