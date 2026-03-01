import SwiftUI

struct StemMixerView: View {
    @EnvironmentObject var vm: StemsViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            // Stem tracks
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(vm.stems) { stem in
                        StemTrackRow(
                            stem: stem,
                            isSelected: vm.selectedStemID == stem.id
                        )
                        .environmentObject(vm)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            // Transport + actions
            bottomBar
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.sourceFilename)
                    .font(.headline)
                Text("\(vm.stems.count) stems separated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { vm.newSeparation() }) {
                Label("New", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Transport controls
            Button(action: { vm.togglePlayback() }) {
                Image(systemName: vm.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            // Clickable progress/seek bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                    Rectangle()
                        .fill(Color.blue.opacity(0.4))
                        .frame(width: geo.size.width * vm.playbackProgress)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            vm.seekTo(fraction: fraction)
                        }
                )
            }
            .frame(height: 8)

            Spacer()

            // Export buttons
            if let selectedID = vm.selectedStemID,
               let stem = vm.stems.first(where: { $0.id == selectedID }) {
                Button(action: { vm.sendToSampler(stem) }) {
                    Label("To Sampler", systemImage: "arrow.right.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button(action: { vm.exportAllStems() }) {
                Label("Export All", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
