import Foundation
import Metal
import MetalKit
import simd

/// Metal GPU-accelerated waveform renderer. Draws beat grid, loop region,
/// 3-band RGB waveform, slice markers, and playhead at 60fps.
@MainActor
final class MetalWaveformRenderer: NSObject, MTKViewDelegate {

    // MARK: - Metal Core

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Pipeline states
    private var bandPipeline: MTLRenderPipelineState!
    private var bandAdditivePipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var quadPipeline: MTLRenderPipelineState!
    private var outlinePipeline: MTLRenderPipelineState!

    // MARK: - Shared Types (must match .metal)

    struct BandUniforms {
        var bandColor: SIMD4<Float>
        var viewportSize: SIMD2<Float>
        var visibleStart: Float
        var visibleEnd: Float
        var centerY: Float
        var halfHeight: Float
        var scale: Float
        var totalBuckets: Int32
        var useAdditive: Int32
    }

    struct LineVertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
    }

    struct QuadVertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
    }

    struct OutlineUniforms {
        var viewportSize: SIMD2<Float>
        var visibleStart: Float
        var visibleEnd: Float
        var centerY: Float
        var halfHeight: Float
        var scale: Float
        var totalBuckets: Int32
        var glowWidth: Float
        var glowColor: SIMD4<Float>
    }

    // MARK: - Direct ViewModel Reference (bypasses SwiftUI update cycle)

    weak var viewModel: SamplerViewModel?

    // Snapshot of ViewModel state read at start of each draw() call
    private var totalSamples: Int = 0
    private var sampleRate: Double = 44100
    private var bpm: Int? = nil
    private var zoom: CGFloat = 1.0
    private var offset: CGFloat = 0
    private var currentPosition: Int = 0
    private var isPlaying: Bool = false
    private var speed: Double = 1.0
    private var loopEnabled: Bool = false
    private var loopStartSample: Int = 0
    private var loopEndSample: Int = 0
    private var gridOffsetSamples: Int = 0
    private var sliceMarkers: [SliceMarker] = []
    private var showStereo: Bool = false

    // MARK: - Industry Standard DJ Colors

    private let lowColor  = SIMD4<Float>(0.85, 0.15, 0.15, 0.80)  // Red (bass)
    private let midColor  = SIMD4<Float>(0.15, 0.80, 0.20, 0.75)  // Green (mids)
    private let highColor = SIMD4<Float>(0.20, 0.60, 0.95, 0.70)  // Blue/cyan (highs)

    // MARK: - Cached Buffers

    private var lastLODLevel: Int = -1
    private var bandBufferLow: MTLBuffer?
    private var bandBufferMid: MTLBuffer?
    private var bandBufferHigh: MTLBuffer?
    private var outlineBuffer: MTLBuffer?
    private var cachedBucketCount: Int = 0

    // Stereo buffers
    private var stereoBandBufferLowL: MTLBuffer?
    private var stereoBandBufferMidL: MTLBuffer?
    private var stereoBandBufferHighL: MTLBuffer?
    private var stereoBandBufferLowR: MTLBuffer?
    private var stereoBandBufferMidR: MTLBuffer?
    private var stereoBandBufferHighR: MTLBuffer?
    private var stereoOutlineBufferL: MTLBuffer?
    private var stereoOutlineBufferR: MTLBuffer?

    // MARK: - Pre-allocated Reusable Buffers (avoid per-frame makeBuffer)

    private var lineBuffer: MTLBuffer?
    private var lineBufferCapacity: Int = 0
    private var quadBuffer: MTLBuffer?
    private var quadBufferCapacity: Int = 0

    // LOD data references (set during state snapshot)
    private var currentColorData: [(low: Float, mid: Float, high: Float)] = []
    private var currentMonoData: [(min: Float, max: Float)] = []
    private var currentStereoData: [(leftMin: Float, leftMax: Float, rightMin: Float, rightMax: Float)] = []

    // MARK: - Init

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        super.init()

        mtkView.device = device
        mtkView.sampleCount = 4  // MSAA 4x
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        mtkView.delegate = self

        guard setupPipelines(mtkView: mtkView) else { return nil }
    }

    private func setupPipelines(mtkView: MTKView) -> Bool {
        // Try default library first (Xcode builds), fall back to runtime compilation (SPM)
        let library: MTLLibrary
        if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
        } else {
            // Compile from source at runtime (SPM command-line builds)
            guard let lib = try? device.makeLibrary(source: Self.shaderSource, options: nil) else {
                print("[MetalWaveform] Failed to compile Metal shaders from source")
                return false
            }
            library = lib
        }

        let sampleCount = mtkView.sampleCount

        // Band pipeline (alpha blending)
        if let vs = library.makeFunction(name: "waveformBandVertex"),
           let fs = library.makeFunction(name: "waveformBandFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.rasterSampleCount = sampleCount
            desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            bandPipeline = try? device.makeRenderPipelineState(descriptor: desc)

            // Additive blending pipeline for natural color mixing
            let addDesc = MTLRenderPipelineDescriptor()
            addDesc.vertexFunction = vs
            addDesc.fragmentFunction = fs
            addDesc.rasterSampleCount = sampleCount
            addDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            addDesc.colorAttachments[0].isBlendingEnabled = true
            addDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            addDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            addDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            addDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
            bandAdditivePipeline = try? device.makeRenderPipelineState(descriptor: addDesc)
        }

        // Line pipeline
        if let vs = library.makeFunction(name: "lineVertex"),
           let fs = library.makeFunction(name: "lineFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.rasterSampleCount = sampleCount
            desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            linePipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Quad pipeline
        if let vs = library.makeFunction(name: "quadVertex"),
           let fs = library.makeFunction(name: "quadFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.rasterSampleCount = sampleCount
            desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            quadPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Outline pipeline
        if let vs = library.makeFunction(name: "outlineVertex"),
           let fs = library.makeFunction(name: "outlineFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.rasterSampleCount = sampleCount
            desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            outlinePipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        return bandPipeline != nil && linePipeline != nil && quadPipeline != nil
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Read all state directly from ViewModel on the main thread.
    private func snapshotState() {
        guard let vm = viewModel else { return }

        totalSamples = vm.sampleFile?.totalSamples ?? 0
        sampleRate = vm.sampleFile?.sampleRate ?? 44100
        bpm = vm.sampleFile?.bpm
        speed = vm.speed
        gridOffsetSamples = vm.gridOffsetSamples
        showStereo = vm.showStereoWaveform
        sliceMarkers = vm.sliceMarkers
        loopEnabled = vm.loopEnabled
        isPlaying = vm.isPlaying
        zoom = vm.waveformZoom
        offset = vm.waveformOffset
        currentPosition = vm.currentPosition

        if let region = vm.loopRegion {
            loopStartSample = region.startSample
            loopEndSample = region.endSample
        }
    }

    /// Select LOD level and rebuild band buffers only when level changes
    private func selectLODAndUpdateBuffers(viewWidth: Float) {
        guard let vm = viewModel else { return }

        if let lod = vm.waveformLOD, !lod.levels.isEmpty {
            let level = lod.selectLevel(zoom: zoom, viewWidth: CGFloat(viewWidth), totalSamples: totalSamples)
            let lodLevel = lod.levels[level]

            if level != lastLODLevel || cachedBucketCount != lodLevel.bucketCount {
                lastLODLevel = level
                cachedBucketCount = lodLevel.bucketCount
                currentColorData = lodLevel.color
                currentMonoData = lodLevel.mono
                currentStereoData = lodLevel.stereo
                rebuildBuffers(colorData: currentColorData, monoData: currentMonoData, stereoData: currentStereoData)
            }
        } else if !vm.frequencyColorData.isEmpty {
            let colorData = vm.frequencyColorData
            if cachedBucketCount != colorData.count {
                cachedBucketCount = colorData.count
                currentColorData = colorData
                currentMonoData = vm.waveformData
                currentStereoData = vm.stereoWaveformData
                rebuildBuffers(colorData: currentColorData, monoData: currentMonoData, stereoData: currentStereoData)
            }
        } else if !vm.waveformData.isEmpty {
            let monoData = vm.waveformData
            if cachedBucketCount != monoData.count {
                cachedBucketCount = monoData.count
                currentColorData = []
                currentMonoData = monoData
                currentStereoData = vm.stereoWaveformData
                rebuildBuffers(colorData: currentColorData, monoData: currentMonoData, stereoData: currentStereoData)
            }
        }
    }

    func draw(in view: MTKView) {
        // Snapshot all state from ViewModel directly (bypasses SwiftUI)
        snapshotState()

        guard totalSamples > 0 else { return }
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let viewWidth = Float(view.bounds.width)
        let viewHeight = Float(view.bounds.height)
        guard viewWidth > 0, viewHeight > 0 else { return }

        let viewportSize = SIMD2<Float>(viewWidth, viewHeight)

        // Select LOD level and update buffers if needed
        selectLODAndUpdateBuffers(viewWidth: viewWidth)

        let colorData = currentColorData
        let monoData = currentMonoData

        let bucketCount = max(colorData.count, monoData.count)
        guard bucketCount > 0 else { commandBuffer.commit(); return }

        // Compute visible bucket range
        let visibleStart = Float(offset / (CGFloat(viewWidth) * zoom)) * Float(bucketCount)
        let visibleEnd = Float((offset + CGFloat(viewWidth)) / (CGFloat(viewWidth) * zoom)) * Float(bucketCount)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            commandBuffer.commit()
            return
        }

        // 1. Draw grid
        drawGrid(encoder: encoder, viewportSize: viewportSize)

        // 2. Draw loop region
        drawLoopRegion(encoder: encoder, viewportSize: viewportSize)

        // 3. Draw waveform bands
        if showStereo {
            drawStereoWaveform(encoder: encoder, viewportSize: viewportSize,
                               visibleStart: visibleStart, visibleEnd: visibleEnd,
                               bucketCount: bucketCount)
        } else {
            drawMonoWaveform(encoder: encoder, viewportSize: viewportSize,
                            visibleStart: visibleStart, visibleEnd: visibleEnd,
                            bucketCount: bucketCount)
        }

        // 4. Draw slice markers
        drawSliceMarkers(encoder: encoder, viewportSize: viewportSize)

        // 5. Draw playhead
        drawPlayhead(encoder: encoder, viewportSize: viewportSize)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Buffer Building

    private func rebuildBuffers(colorData: [(low: Float, mid: Float, high: Float)],
                                monoData: [(min: Float, max: Float)],
                                stereoData: [(leftMin: Float, leftMax: Float, rightMin: Float, rightMax: Float)]) {
        if !colorData.isEmpty {
            let lowAmps = colorData.map { $0.low }
            let midAmps = colorData.map { $0.mid }
            let highAmps = colorData.map { $0.high }
            bandBufferLow = makeBuffer(lowAmps)
            bandBufferMid = makeBuffer(midAmps)
            bandBufferHigh = makeBuffer(highAmps)
        } else {
            // Fallback: use mono max as single band
            let amps = monoData.map { max(abs($0.min), abs($0.max)) }
            bandBufferLow = makeBuffer(amps)
            bandBufferMid = nil
            bandBufferHigh = nil
        }

        // Outline data: (min, max) pairs as SIMD2<Float>
        let minMax = monoData.map { SIMD2<Float>($0.min, $0.max) }
        outlineBuffer = device.makeBuffer(bytes: minMax, length: minMax.count * MemoryLayout<SIMD2<Float>>.stride)

        // Stereo buffers
        if !stereoData.isEmpty && !colorData.isEmpty {
            // For stereo, we scale color bands by per-channel amplitude ratio
            let monoMaxes = monoData.map { max(abs($0.min), abs($0.max)) }
            let leftMaxes = stereoData.map { max(abs($0.leftMin), abs($0.leftMax)) }
            let rightMaxes = stereoData.map { max(abs($0.rightMin), abs($0.rightMax)) }

            func scaledBand(_ band: [Float], _ channelMax: [Float], _ monoMax: [Float]) -> [Float] {
                return zip(band, zip(channelMax, monoMax)).map { (b, cm) in
                    let (ch, mn) = cm
                    return mn > 0.001 ? b * (ch / mn) : b
                }
            }

            let lowAmps = colorData.map { $0.low }
            let midAmps = colorData.map { $0.mid }
            let highAmps = colorData.map { $0.high }

            stereoBandBufferLowL = makeBuffer(scaledBand(lowAmps, leftMaxes, monoMaxes))
            stereoBandBufferMidL = makeBuffer(scaledBand(midAmps, leftMaxes, monoMaxes))
            stereoBandBufferHighL = makeBuffer(scaledBand(highAmps, leftMaxes, monoMaxes))
            stereoBandBufferLowR = makeBuffer(scaledBand(lowAmps, rightMaxes, monoMaxes))
            stereoBandBufferMidR = makeBuffer(scaledBand(midAmps, rightMaxes, monoMaxes))
            stereoBandBufferHighR = makeBuffer(scaledBand(highAmps, rightMaxes, monoMaxes))

            let leftMinMax = stereoData.map { SIMD2<Float>($0.leftMin, $0.leftMax) }
            let rightMinMax = stereoData.map { SIMD2<Float>($0.rightMin, $0.rightMax) }
            stereoOutlineBufferL = device.makeBuffer(bytes: leftMinMax, length: leftMinMax.count * MemoryLayout<SIMD2<Float>>.stride)
            stereoOutlineBufferR = device.makeBuffer(bytes: rightMinMax, length: rightMinMax.count * MemoryLayout<SIMD2<Float>>.stride)
        }
    }

    private func makeBuffer(_ data: [Float]) -> MTLBuffer? {
        guard !data.isEmpty else { return nil }
        return device.makeBuffer(bytes: data, length: data.count * MemoryLayout<Float>.stride)
    }

    // MARK: - Draw Grid

    private func drawGrid(encoder: MTLRenderCommandEncoder, viewportSize: SIMD2<Float>) {
        guard let bpm = bpm, bpm > 0 else { return }

        let effectiveBPM = Double(bpm) * speed
        let samplesPerBeat = sampleRate * 60.0 / effectiveBPM
        let samplesPerBar = samplesPerBeat * 4.0
        let gridOffset = Double(gridOffsetSamples)
        let viewWidth = viewportSize.x

        let barPixelWidth = samplesPerBar / Double(totalSamples) * Double(viewWidth) * Double(zoom)
        let hasCustomGrid = gridOffsetSamples != 0

        var lineVertices: [LineVertex] = []

        var barPosition = gridOffset
        while barPosition < Double(totalSamples) {

            let x = sampleToPixel(Int(barPosition), viewWidth: viewWidth)

            if x >= -2 && x <= viewWidth + 2 {
                // Bar line
                let barColor: SIMD4<Float> = hasCustomGrid
                    ? SIMD4<Float>(1.0, 0.65, 0.0, 0.25)   // Orange
                    : SIMD4<Float>(1.0, 1.0, 1.0, 0.12)    // White
                appendLine(&lineVertices, x: x, height: viewportSize.y, color: barColor)
            }

            // Beat lines
            if barPixelWidth > 60 {
                for beat in 1..<4 {
                    let beatPos = barPosition + Double(beat) * samplesPerBeat
                    let bx = sampleToPixel(Int(beatPos), viewWidth: viewWidth)
                    if bx >= 0 && bx <= viewWidth {
                        let beatColor: SIMD4<Float> = hasCustomGrid
                            ? SIMD4<Float>(1.0, 0.65, 0.0, 0.10)
                            : SIMD4<Float>(1.0, 1.0, 1.0, 0.06)
                        appendLine(&lineVertices, x: bx, height: viewportSize.y, color: beatColor)
                    }
                }
            }

            // 16th subdivision
            let sixteenthPixelWidth = barPixelWidth / 16.0
            if sixteenthPixelWidth > 12 {
                for s in 0..<16 {
                    if s % 4 == 0 { continue }
                    let subPos = barPosition + Double(s) * samplesPerBeat / 4.0
                    let sx = sampleToPixel(Int(subPos), viewWidth: viewWidth)
                    if sx >= 0 && sx <= viewWidth {
                        appendLine(&lineVertices, x: sx, height: viewportSize.y,
                                  color: SIMD4<Float>(1.0, 1.0, 1.0, 0.03))
                    }
                }
            }

            barPosition += samplesPerBar
        }

        // Grid offset label (rendered as a small colored quad indicator)
        if hasCustomGrid {
            // Draw a small orange indicator dot at top-left
            let indicatorColor = SIMD4<Float>(1.0, 0.65, 0.0, 0.8)
            var quads: [QuadVertex] = []
            appendQuad(&quads, rect: SIMD4<Float>(4, 4, 8, 8), color: indicatorColor)
            drawQuads(encoder: encoder, vertices: quads, viewportSize: viewportSize)
        }

        drawLines(encoder: encoder, vertices: lineVertices, viewportSize: viewportSize)
    }

    // MARK: - Draw Loop Region

    private func drawLoopRegion(encoder: MTLRenderCommandEncoder, viewportSize: SIMD2<Float>) {
        guard loopEnabled else { return }

        let viewWidth = viewportSize.x
        let viewHeight = viewportSize.y
        let startX = sampleToPixel(loopStartSample, viewWidth: viewWidth)
        let endX = sampleToPixel(loopEndSample, viewWidth: viewWidth)

        var quads: [QuadVertex] = []

        // Dim areas outside loop
        if startX > 0 {
            appendQuad(&quads, rect: SIMD4<Float>(0, 0, startX, viewHeight),
                      color: SIMD4<Float>(0, 0, 0, 0.4))
        }
        if endX < viewWidth {
            appendQuad(&quads, rect: SIMD4<Float>(endX, 0, viewWidth - endX, viewHeight),
                      color: SIMD4<Float>(0, 0, 0, 0.4))
        }

        // Green tint in loop
        appendQuad(&quads, rect: SIMD4<Float>(startX, 0, endX - startX, viewHeight),
                  color: SIMD4<Float>(0, 1, 0, 0.06))

        // Green top bar
        appendQuad(&quads, rect: SIMD4<Float>(startX, 0, endX - startX, 3),
                  color: SIMD4<Float>(0, 1, 0, 0.8))

        drawQuads(encoder: encoder, vertices: quads, viewportSize: viewportSize)

        // Loop border lines
        var lines: [LineVertex] = []
        let greenBorder = SIMD4<Float>(0.0, 0.85, 0.0, 0.9)
        appendLine(&lines, x: startX, height: viewHeight, color: greenBorder, width: 2)
        appendLine(&lines, x: endX, height: viewHeight, color: greenBorder, width: 2)
        drawLines(encoder: encoder, vertices: lines, viewportSize: viewportSize)
    }

    // MARK: - Draw Mono Waveform

    private func drawMonoWaveform(encoder: MTLRenderCommandEncoder, viewportSize: SIMD2<Float>,
                                   visibleStart: Float, visibleEnd: Float, bucketCount: Int) {
        let centerY = viewportSize.y / 2.0
        let halfHeight = centerY
        let pixelCount = Int(viewportSize.x)
        let vertexCount = pixelCount * 2

        if let lowBuf = bandBufferLow, let midBuf = bandBufferMid, let highBuf = bandBufferHigh {
            // 3-band rendering with additive blending
            let bands: [(MTLBuffer, SIMD4<Float>)] = [
                (lowBuf, lowColor),
                (midBuf, midColor),
                (highBuf, highColor)
            ]

            for (buffer, color) in bands {
                var uniforms = BandUniforms(
                    bandColor: color,
                    viewportSize: viewportSize,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    centerY: centerY,
                    halfHeight: halfHeight,
                    scale: 0.9,
                    totalBuckets: Int32(bucketCount),
                    useAdditive: 1
                )

                encoder.setRenderPipelineState(bandAdditivePipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<BandUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)
            }
        } else if let buf = bandBufferLow {
            // Fallback: single band
            let fallbackColor = SIMD4<Float>(0.2, 0.6, 0.85, 0.55)
            var uniforms = BandUniforms(
                bandColor: fallbackColor,
                viewportSize: viewportSize,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                centerY: centerY,
                halfHeight: halfHeight,
                scale: 0.9,
                totalBuckets: Int32(bucketCount),
                useAdditive: 0
            )

            encoder.setRenderPipelineState(bandPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<BandUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)
        }

        // Outline with glow
        if let outBuf = outlineBuffer, outlinePipeline != nil {
            let monoCount = max(currentMonoData.count, cachedBucketCount)
            var outUni = OutlineUniforms(
                viewportSize: viewportSize,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                centerY: centerY,
                halfHeight: halfHeight,
                scale: 0.9,
                totalBuckets: Int32(monoCount),
                glowWidth: 3.0,
                glowColor: SIMD4<Float>(1.0, 1.0, 1.0, 0.15)
            )

            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setVertexBuffer(outBuf, offset: 0, index: 0)
            encoder.setVertexBytes(&outUni, length: MemoryLayout<OutlineUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(viewportSize.x) * 4)
        }
    }

    // MARK: - Draw Stereo Waveform

    private func drawStereoWaveform(encoder: MTLRenderCommandEncoder, viewportSize: SIMD2<Float>,
                                     visibleStart: Float, visibleEnd: Float, bucketCount: Int) {
        let halfH = viewportSize.y / 2.0
        let lCenter = halfH * 0.5
        let rCenter = halfH + halfH * 0.5
        let channelHalfH = halfH * 0.5
        let pixelCount = Int(viewportSize.x)
        let vertexCount = pixelCount * 2

        let leftBands: [(MTLBuffer?, SIMD4<Float>)] = [
            (stereoBandBufferLowL, lowColor),
            (stereoBandBufferMidL, midColor),
            (stereoBandBufferHighL, highColor)
        ]

        let rightBands: [(MTLBuffer?, SIMD4<Float>)] = [
            (stereoBandBufferLowR, lowColor),
            (stereoBandBufferMidR, midColor),
            (stereoBandBufferHighR, highColor)
        ]

        for (bands, centerY) in [(leftBands, lCenter), (rightBands, rCenter)] {
            for (buffer, color) in bands {
                guard let buf = buffer else { continue }
                var uniforms = BandUniforms(
                    bandColor: color,
                    viewportSize: viewportSize,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    centerY: centerY,
                    halfHeight: channelHalfH,
                    scale: 0.9,
                    totalBuckets: Int32(bucketCount),
                    useAdditive: 1
                )

                encoder.setRenderPipelineState(bandAdditivePipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<BandUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)
            }
        }

        // Stereo outlines
        for (outBuf, centerY) in [(stereoOutlineBufferL, lCenter), (stereoOutlineBufferR, rCenter)] {
            guard let buf = outBuf, outlinePipeline != nil else { continue }
            var outUni = OutlineUniforms(
                viewportSize: viewportSize,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                centerY: centerY,
                halfHeight: channelHalfH,
                scale: 0.9,
                totalBuckets: Int32(bucketCount),
                glowWidth: 2.0,
                glowColor: SIMD4<Float>(1.0, 1.0, 1.0, 0.12)
            )

            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&outUni, length: MemoryLayout<OutlineUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(viewportSize.x) * 4)
        }

        // Center divider line
        var divLines: [LineVertex] = []
        let divColor = SIMD4<Float>(0.5, 0.5, 0.5, 0.5)
        appendHLine(&divLines, y: halfH, width: viewportSize.x, color: divColor)
        drawLines(encoder: encoder, vertices: divLines, viewportSize: viewportSize)
    }

    // MARK: - Draw Slice Markers

    private func drawSliceMarkers(encoder: MTLRenderCommandEncoder, viewportSize: SIMD2<Float>) {
        guard !sliceMarkers.isEmpty else { return }

        var lines: [LineVertex] = []
        var quads: [QuadVertex] = []

        for marker in sliceMarkers {
            let x = sampleToPixel(marker.samplePosition, viewWidth: viewportSize.x)
            guard x >= -2 && x <= viewportSize.x + 2 else { continue }

            let color: SIMD4<Float>
            switch marker.type {
            case .transient: color = SIMD4<Float>(1.0, 0.65, 0.0, 0.8)  // Orange
            case .manual:    color = SIMD4<Float>(0.0, 0.85, 0.0, 0.8)  // Green
            case .grid:      color = SIMD4<Float>(1.0, 1.0, 0.0, 0.8)   // Yellow
            }

            appendLine(&lines, x: x, height: viewportSize.y, color: color)

            // Triangle marker at top
            let triVerts = triangleVertices(x: x, y: 0, size: 4, color: color)
            quads.append(contentsOf: triVerts)
        }

        drawLines(encoder: encoder, vertices: lines, viewportSize: viewportSize)
        if !quads.isEmpty {
            drawQuads(encoder: encoder, vertices: quads, viewportSize: viewportSize)
        }
    }

    // MARK: - Draw Playhead

    private func drawPlayhead(encoder: MTLRenderCommandEncoder, viewportSize: SIMD2<Float>) {
        let x = sampleToPixel(currentPosition, viewWidth: viewportSize.x)
        let clampedX = max(-2, min(viewportSize.x + 2, x))

        // White line
        var lines: [LineVertex] = []
        appendLine(&lines, x: clampedX, height: viewportSize.y,
                  color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0), width: 2)
        drawLines(encoder: encoder, vertices: lines, viewportSize: viewportSize)

        // Red triangle head
        var quads: [QuadVertex] = []
        let red = SIMD4<Float>(1.0, 0.0, 0.0, 1.0)
        let triVerts = triangleVertices(x: clampedX, y: 0, size: 6, color: red)
        quads.append(contentsOf: triVerts)
        drawQuads(encoder: encoder, vertices: quads, viewportSize: viewportSize)
    }

    // MARK: - Helpers

    private func sampleToPixel(_ sample: Int, viewWidth: Float) -> Float {
        guard totalSamples > 0 else { return 0 }
        return Float(sample) / Float(totalSamples) * viewWidth * Float(zoom) - Float(offset)
    }

    private func appendLine(_ vertices: inout [LineVertex], x: Float, height: Float,
                           color: SIMD4<Float>, width: Float = 1) {
        // Each line = 2 vertices forming a degenerate triangle strip
        // For width > 1, use a thin quad
        let halfW = width / 2.0
        vertices.append(LineVertex(position: SIMD2<Float>(x - halfW, 0), color: color))
        vertices.append(LineVertex(position: SIMD2<Float>(x + halfW, 0), color: color))
        vertices.append(LineVertex(position: SIMD2<Float>(x - halfW, height), color: color))
        vertices.append(LineVertex(position: SIMD2<Float>(x + halfW, height), color: color))
    }

    private func appendHLine(_ vertices: inout [LineVertex], y: Float, width: Float,
                            color: SIMD4<Float>) {
        vertices.append(LineVertex(position: SIMD2<Float>(0, y - 0.5), color: color))
        vertices.append(LineVertex(position: SIMD2<Float>(width, y - 0.5), color: color))
        vertices.append(LineVertex(position: SIMD2<Float>(0, y + 0.5), color: color))
        vertices.append(LineVertex(position: SIMD2<Float>(width, y + 0.5), color: color))
    }

    private func appendQuad(_ vertices: inout [QuadVertex], rect: SIMD4<Float>, color: SIMD4<Float>) {
        let (x, y, w, h) = (rect.x, rect.y, rect.z, rect.w)
        // Two triangles = 6 vertices
        vertices.append(QuadVertex(position: SIMD2<Float>(x, y), color: color))
        vertices.append(QuadVertex(position: SIMD2<Float>(x + w, y), color: color))
        vertices.append(QuadVertex(position: SIMD2<Float>(x, y + h), color: color))
        vertices.append(QuadVertex(position: SIMD2<Float>(x + w, y), color: color))
        vertices.append(QuadVertex(position: SIMD2<Float>(x + w, y + h), color: color))
        vertices.append(QuadVertex(position: SIMD2<Float>(x, y + h), color: color))
    }

    private func triangleVertices(x: Float, y: Float, size: Float, color: SIMD4<Float>) -> [QuadVertex] {
        return [
            QuadVertex(position: SIMD2<Float>(x - size, y), color: color),
            QuadVertex(position: SIMD2<Float>(x + size, y), color: color),
            QuadVertex(position: SIMD2<Float>(x, y + size * 1.5), color: color)
        ]
    }

    private func drawLines(encoder: MTLRenderCommandEncoder, vertices: [LineVertex], viewportSize: SIMD2<Float>) {
        guard !vertices.isEmpty else { return }
        var vp = viewportSize
        let byteCount = vertices.count * MemoryLayout<LineVertex>.stride

        // Reuse or grow pre-allocated buffer
        if lineBuffer == nil || lineBufferCapacity < byteCount {
            // Allocate with 2x headroom to avoid frequent resizes
            let allocSize = max(byteCount, lineBufferCapacity * 2, 4096)
            lineBuffer = device.makeBuffer(length: allocSize, options: .storageModeShared)
            lineBufferCapacity = allocSize
        }

        guard let buf = lineBuffer else { return }
        memcpy(buf.contents(), vertices, byteCount)

        encoder.setRenderPipelineState(linePipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for i in stride(from: 0, to: vertices.count, by: 4) {
            let count = min(4, vertices.count - i)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: i, vertexCount: count)
        }
    }

    private func drawQuads(encoder: MTLRenderCommandEncoder, vertices: [QuadVertex], viewportSize: SIMD2<Float>) {
        guard !vertices.isEmpty else { return }
        var vp = viewportSize
        let byteCount = vertices.count * MemoryLayout<QuadVertex>.stride

        // Reuse or grow pre-allocated buffer
        if quadBuffer == nil || quadBufferCapacity < byteCount {
            let allocSize = max(byteCount, quadBufferCapacity * 2, 4096)
            quadBuffer = device.makeBuffer(length: allocSize, options: .storageModeShared)
            quadBufferCapacity = allocSize
        }

        guard let buf = quadBuffer else { return }
        memcpy(buf.contents(), vertices, byteCount)

        encoder.setRenderPipelineState(quadPipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    // MARK: - Embedded Shader Source (for SPM runtime compilation)

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float4 color;
    };

    struct BandUniforms {
        float4 bandColor;
        float2 viewportSize;
        float visibleStart;
        float visibleEnd;
        float centerY;
        float halfHeight;
        float scale;
        int totalBuckets;
        int useAdditive;
    };

    vertex VertexOut waveformBandVertex(
        uint vertexID [[vertex_id]],
        const device float* amplitudes [[buffer(0)]],
        constant BandUniforms& uniforms [[buffer(1)]]
    ) {
        uint pixelX = vertexID / 2;
        bool isBottom = (vertexID % 2) == 1;
        float viewWidth = uniforms.viewportSize.x;
        float t = float(pixelX) / viewWidth;
        float bucketF = uniforms.visibleStart + t * (uniforms.visibleEnd - uniforms.visibleStart);
        int idx0 = clamp(int(bucketF), 0, uniforms.totalBuckets - 1);
        int idx1 = clamp(idx0 + 1, 0, uniforms.totalBuckets - 1);
        float frac = bucketF - float(idx0);
        float amp = mix(amplitudes[idx0], amplitudes[idx1], frac);
        float x = (float(pixelX) / viewWidth) * 2.0 - 1.0;
        float yOffset = amp * uniforms.halfHeight * uniforms.scale;
        float y = isBottom ? (uniforms.centerY + yOffset) : (uniforms.centerY - yOffset);
        float yNDC = 1.0 - (y / uniforms.viewportSize.y) * 2.0;
        VertexOut out;
        out.position = float4(x, yNDC, 0.0, 1.0);
        out.color = uniforms.bandColor;
        return out;
    }

    fragment float4 waveformBandFragment(VertexOut in [[stage_in]]) {
        return in.color;
    }

    struct LineVertex {
        float2 position;
        float4 color;
    };

    vertex VertexOut lineVertex(
        uint vertexID [[vertex_id]],
        const device LineVertex* vertices [[buffer(0)]],
        constant float2& viewportSize [[buffer(1)]]
    ) {
        LineVertex v = vertices[vertexID];
        float x = (v.position.x / viewportSize.x) * 2.0 - 1.0;
        float y = 1.0 - (v.position.y / viewportSize.y) * 2.0;
        VertexOut out;
        out.position = float4(x, y, 0.0, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 lineFragment(VertexOut in [[stage_in]]) {
        return in.color;
    }

    struct QuadVertex {
        float2 position;
        float4 color;
    };

    vertex VertexOut quadVertex(
        uint vertexID [[vertex_id]],
        const device QuadVertex* vertices [[buffer(0)]],
        constant float2& viewportSize [[buffer(1)]]
    ) {
        QuadVertex v = vertices[vertexID];
        float x = (v.position.x / viewportSize.x) * 2.0 - 1.0;
        float y = 1.0 - (v.position.y / viewportSize.y) * 2.0;
        VertexOut out;
        out.position = float4(x, y, 0.0, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 quadFragment(VertexOut in [[stage_in]]) {
        return in.color;
    }

    struct OutlineUniforms {
        float2 viewportSize;
        float visibleStart;
        float visibleEnd;
        float centerY;
        float halfHeight;
        float scale;
        int totalBuckets;
        float glowWidth;
        float4 glowColor;
    };

    vertex VertexOut outlineVertex(
        uint vertexID [[vertex_id]],
        const device float2* minMaxData [[buffer(0)]],
        constant OutlineUniforms& uniforms [[buffer(1)]]
    ) {
        uint pixelX = vertexID / 4;
        uint sub = vertexID % 4;
        float viewWidth = uniforms.viewportSize.x;
        float t = float(pixelX) / viewWidth;
        float bucketF = uniforms.visibleStart + t * (uniforms.visibleEnd - uniforms.visibleStart);
        int idx0 = clamp(int(bucketF), 0, uniforms.totalBuckets - 1);
        int idx1 = clamp(idx0 + 1, 0, uniforms.totalBuckets - 1);
        float frac = bucketF - float(idx0);
        float2 mm0 = minMaxData[idx0];
        float2 mm1 = minMaxData[idx1];
        float minVal = mix(mm0.x, mm1.x, frac);
        float maxVal = mix(mm0.y, mm1.y, frac);
        float x = (float(pixelX) / viewWidth) * 2.0 - 1.0;
        float topY = uniforms.centerY - maxVal * uniforms.halfHeight * uniforms.scale;
        float botY = uniforms.centerY - minVal * uniforms.halfHeight * uniforms.scale;
        float y;
        float alpha;
        float glowPx = uniforms.glowWidth;
        switch (sub) {
            case 0: y = topY - glowPx; alpha = 0.0; break;
            case 1: y = topY;          alpha = 1.0; break;
            case 2: y = botY;          alpha = 1.0; break;
            case 3: y = botY + glowPx; alpha = 0.0; break;
            default: y = topY; alpha = 0.0; break;
        }
        float yNDC = 1.0 - (y / uniforms.viewportSize.y) * 2.0;
        VertexOut out;
        out.position = float4(x, yNDC, 0.0, 1.0);
        out.color = float4(uniforms.glowColor.rgb, uniforms.glowColor.a * alpha);
        return out;
    }

    fragment float4 outlineFragment(VertexOut in [[stage_in]]) {
        return in.color;
    }
    """
}
