import SwiftUI
import MetalKit

/// SwiftUI wrapper for the Metal-accelerated waveform renderer.
/// Minimal bridge — renderer reads state directly from ViewModel in draw().
struct MetalWaveformView: NSViewRepresentable {
    @EnvironmentObject var vm: SamplerViewModel

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.layer?.isOpaque = true

        guard let renderer = MetalWaveformRenderer(mtkView: mtkView) else {
            print("[MetalWaveform] Failed to create renderer, falling back")
            return mtkView
        }

        renderer.viewModel = vm
        context.coordinator.renderer = renderer

        // 60fps continuous rendering via display link
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60

        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.renderer?.viewModel = vm
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var renderer: MetalWaveformRenderer?
    }
}
