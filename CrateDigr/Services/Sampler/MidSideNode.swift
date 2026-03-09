import AVFoundation
import AudioToolbox

/// Custom AUAudioUnit for real-time Mid/Side stereo processing.
/// Encodes L/R → Mid/Side, applies independent gains, optionally with frequency crossover, decodes back.
final class MidSideAU: AUAudioUnit {

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("mids"),
        componentManufacturer: fourCC("CrDi"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// Register the component. Call once before instantiation.
    static func register() {
        AUAudioUnit.registerSubclass(
            MidSideAU.self,
            as: componentDescription,
            name: "CrateDigr: MidSide",
            version: 1
        )
    }

    // MARK: - DSP Parameters (main thread writes, render thread reads)
    // ARM64 aligned Float access is atomic — standard practice for audio DSP.

    /// Mid gain, linear (1.0 = unity)
    var midGain: Float = 1.0
    /// Side gain, linear (1.0 = unity)
    var sideGain: Float = 1.0
    /// Crossover frequency in Hz. 0 = disabled (full-range M/S).
    var crossoverHz: Float = 0 {
        didSet { updateCrossoverCoeffs() }
    }

    // MARK: - Bus arrays

    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    // MARK: - Crossover filter state (only touched from render thread)

    private struct BiquadState {
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        mutating func process(_ x0: Float, _ b0: Float, _ b1: Float, _ b2: Float,
                              _ a1: Float, _ a2: Float) -> Float {
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            return y0
        }
    }

    // Per-channel biquad state for LP/HP crossover
    private var lpL = BiquadState(), lpR = BiquadState()
    private var hpL = BiquadState(), hpR = BiquadState()

    // Biquad coefficients (2nd-order Butterworth)
    private var lpB0: Float = 1, lpB1: Float = 0, lpB2: Float = 0
    private var lpA1: Float = 0, lpA2: Float = 0
    private var hpB0: Float = 1, hpB1: Float = 0, hpB2: Float = 0
    private var hpA1: Float = 0, hpA2: Float = 0

    private var renderSampleRate: Double = 44100

    // MARK: - Init

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        _inputBusArray = AUAudioUnitBusArray(
            audioUnit: self, busType: .input,
            busses: [try AUAudioUnitBus(format: fmt)]
        )
        _outputBusArray = AUAudioUnitBusArray(
            audioUnit: self, busType: .output,
            busses: [try AUAudioUnitBus(format: fmt)]
        )
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        renderSampleRate = inputBusses[0].format.sampleRate
        resetFilterState()
        updateCrossoverCoeffs()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
    }

    // MARK: - Render

    override var internalRenderBlock: AUInternalRenderBlock {
        { [unowned self] actionFlags, timestamp, frameCount, outputBusNumber,
          outputData, renderEvent, pullInputBlock in

            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }

            // Pull upstream audio into output buffers
            let status = pullInputBlock(actionFlags, timestamp, frameCount,
                                        outputBusNumber, outputData)
            guard status == noErr else { return status }

            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2,
                  let lPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let rPtr = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr  // Mono: pass through
            }

            let mG = self.midGain
            let sG = self.sideGain
            let frames = Int(frameCount)

            // Bypass when both gains are unity
            if abs(mG - 1.0) < 0.001 && abs(sG - 1.0) < 0.001 { return noErr }

            if self.crossoverHz > 20 {
                // Crossover M/S: process only frequencies above crossover
                for i in 0..<frames {
                    let l = lPtr[i], r = rPtr[i]
                    let lLow = self.lpL.process(l, self.lpB0, self.lpB1, self.lpB2,
                                                self.lpA1, self.lpA2)
                    let rLow = self.lpR.process(r, self.lpB0, self.lpB1, self.lpB2,
                                                self.lpA1, self.lpA2)
                    let lHigh = self.hpL.process(l, self.hpB0, self.hpB1, self.hpB2,
                                                 self.hpA1, self.hpA2)
                    let rHigh = self.hpR.process(r, self.hpB0, self.hpB1, self.hpB2,
                                                 self.hpA1, self.hpA2)
                    let mid  = (lHigh + rHigh) * 0.5 * mG
                    let side = (lHigh - rHigh) * 0.5 * sG
                    lPtr[i] = lLow + mid + side
                    rPtr[i] = rLow + mid - side
                }
            } else {
                // Full-range M/S
                for i in 0..<frames {
                    let l = lPtr[i], r = rPtr[i]
                    let mid  = (l + r) * 0.5 * mG
                    let side = (l - r) * 0.5 * sG
                    lPtr[i] = mid + side
                    rPtr[i] = mid - side
                }
            }

            return noErr
        }
    }

    // MARK: - Filter Helpers

    private func resetFilterState() {
        lpL = BiquadState(); lpR = BiquadState()
        hpL = BiquadState(); hpR = BiquadState()
    }

    private func updateCrossoverCoeffs() {
        let hz = crossoverHz
        let sr = Float(renderSampleRate)
        guard hz > 20 && sr > 0 else {
            // No crossover: LP passes all, HP passes nothing
            lpB0 = 1; lpB1 = 0; lpB2 = 0; lpA1 = 0; lpA2 = 0
            hpB0 = 0; hpB1 = 0; hpB2 = 0; hpA1 = 0; hpA2 = 0
            return
        }

        let w0 = 2.0 * Float.pi * hz / sr
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * sqrt(2.0))  // Butterworth Q = √2/2
        let a0 = 1.0 + alpha

        // Low-pass
        lpB0 = ((1.0 - cosW0) / 2.0) / a0
        lpB1 = (1.0 - cosW0) / a0
        lpB2 = lpB0
        lpA1 = (-2.0 * cosW0) / a0
        lpA2 = (1.0 - alpha) / a0

        // High-pass (same denominator for matched Butterworth)
        hpB0 = ((1.0 + cosW0) / 2.0) / a0
        hpB1 = -(1.0 + cosW0) / a0
        hpB2 = hpB0
        hpA1 = lpA1
        hpA2 = lpA2
    }

    // MARK: - Helpers

    private static func fourCC(_ s: String) -> FourCharCode {
        var r: FourCharCode = 0
        for c in s.utf8.prefix(4) { r = (r << 8) | FourCharCode(c) }
        return r
    }
}
