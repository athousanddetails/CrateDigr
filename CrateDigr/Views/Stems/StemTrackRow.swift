import SwiftUI

struct StemTrackRow: View {
    let stem: StemTrack
    let isSelected: Bool
    @EnvironmentObject var vm: StemsViewModel

    var body: some View {
        HStack(spacing: 8) {
            // Stem type indicator
            VStack(spacing: 2) {
                Image(systemName: stem.stemType.icon)
                    .font(.system(size: 14))
                Text(stem.stemType.displayName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(stem.stemType.color)
            .frame(width: 54)

            // Solo / Mute buttons
            VStack(spacing: 4) {
                Button(action: { vm.toggleSolo(stemID: stem.id) }) {
                    Text("S")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(width: 24, height: 20)
                        .background(stem.isSoloed ? Color.yellow : Color.gray.opacity(0.15))
                        .foregroundStyle(stem.isSoloed ? .black : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)

                Button(action: { vm.toggleMute(stemID: stem.id) }) {
                    Text("M")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(width: 24, height: 20)
                        .background(stem.isMuted ? Color.red : Color.gray.opacity(0.15))
                        .foregroundStyle(stem.isMuted ? .white : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }

            // Volume slider
            VStack(spacing: 0) {
                Slider(value: Binding(
                    get: { stem.volume },
                    set: { vm.setVolume(stemID: stem.id, volume: Float($0)) }
                ), in: 0...1.5)
                    .frame(width: 70)

                Text("\(Int(stem.volume * 100))%")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Mini waveform
            Canvas { context, size in
                drawWaveform(context: context, size: size)
            }
            .frame(height: 56)
            .background(Color(white: 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isSelected ? stem.stemType.color : Color.gray.opacity(0.15),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    // Cmd+click: toggle selection (multi-select)
                    vm.toggleStemSelection(stem.id)
                } else {
                    // Plain click: single select
                    vm.selectedStemIDs = [stem.id]
                }
            }

            // Actions
            VStack(spacing: 4) {
                Button(action: { vm.exportStem(stem) }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Export this stem")

                Button(action: { vm.sendToSampler(stem) }) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Send to Sampler")
            }
            .frame(width: 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? stem.stemType.color.opacity(0.05) : Color.clear)
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let data = stem.waveformData
        guard !data.isEmpty else { return }

        let centerY = size.height / 2
        let pixelCount = Int(size.width)
        let color = stem.stemType.color

        var path = Path()
        path.move(to: CGPoint(x: 0, y: centerY))

        for x in 0..<pixelCount {
            let bucketIdx = min(data.count - 1, x * data.count / max(1, pixelCount))
            let topY = centerY - CGFloat(data[bucketIdx].max) * centerY * 0.85
            path.addLine(to: CGPoint(x: CGFloat(x), y: topY))
        }

        for x in stride(from: pixelCount - 1, through: 0, by: -1) {
            let bucketIdx = min(data.count - 1, x * data.count / max(1, pixelCount))
            let botY = centerY - CGFloat(data[bucketIdx].min) * centerY * 0.85
            path.addLine(to: CGPoint(x: CGFloat(x), y: botY))
        }

        path.closeSubpath()

        context.fill(path, with: .color(color.opacity(0.5)))

        // Center line
        var centerLine = Path()
        centerLine.move(to: CGPoint(x: 0, y: centerY))
        centerLine.addLine(to: CGPoint(x: size.width, y: centerY))
        context.stroke(centerLine, with: .color(Color.white.opacity(0.1)), lineWidth: 0.5)
    }
}
