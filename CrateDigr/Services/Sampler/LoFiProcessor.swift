import Foundation
import Accelerate

struct LoFiProcessor {

    // MARK: - Presets

    struct LoFiPreset {
        let name: String
        let bitDepth: Int
        let targetSampleRate: Double
        let drive: Float
        let crackle: Float
        let wowFlutter: Float

        static let sp1200 = LoFiPreset(name: "SP-1200", bitDepth: 12, targetSampleRate: 26040, drive: 0.2, crackle: 0, wowFlutter: 0)
        static let mpc60 = LoFiPreset(name: "MPC60", bitDepth: 12, targetSampleRate: 40000, drive: 0.15, crackle: 0, wowFlutter: 0)
        static let vinylDusty = LoFiPreset(name: "Vinyl Dusty", bitDepth: 16, targetSampleRate: 44100, drive: 0.1, crackle: 0.7, wowFlutter: 0.4)
        static let tapeWarm = LoFiPreset(name: "Tape Warm", bitDepth: 16, targetSampleRate: 44100, drive: 0.5, crackle: 0, wowFlutter: 0.2)

        static let all: [LoFiPreset] = [sp1200, mpc60, vinylDusty, tapeWarm]
    }

    // MARK: - DSP Functions

    /// Bit crush: reduce amplitude resolution by quantizing to fewer levels.
    static func bitCrush(samples: [Float], bitDepth: Int) -> [Float] {
        guard bitDepth < 16 else { return samples }
        let levels = powf(2.0, Float(bitDepth))
        return samples.map { sample in
            round(sample * levels) / levels
        }
    }

    /// Sample rate reduce: decimate by holding samples (creates aliasing artifacts).
    static func sampleRateReduce(samples: [Float], originalRate: Double, targetRate: Double) -> [Float] {
        guard targetRate < originalRate else { return samples }
        let ratio = max(1, Int(originalRate / targetRate))
        guard ratio > 1 else { return samples }
        var result = [Float](repeating: 0, count: samples.count)
        var held: Float = 0
        for i in 0..<samples.count {
            if i % ratio == 0 { held = samples[i] }
            result[i] = held
        }
        return result
    }

    /// Tape saturation: soft-clip waveshaper using tanh for warm overdrive.
    static func tapeSaturation(samples: [Float], drive: Float) -> [Float] {
        guard drive > 0 else { return samples }
        let gain = 1.0 + drive * 4.0  // drive 0-1 maps to gain 1-5
        let normFactor = 1.0 / tanh(gain)
        return samples.map { sample in
            tanh(sample * gain) * normFactor
        }
    }

    /// Vinyl simulation: sparse crackle impulses + wow/flutter pitch modulation.
    static func vinylSim(samples: [Float], sampleRate: Double,
                         crackleAmount: Float, wowFlutter: Float) -> [Float] {
        var result = samples
        let count = samples.count

        // Add crackle noise (random sparse impulses)
        if crackleAmount > 0 {
            let crackleRate = max(1, Int(sampleRate / (20.0 * Double(crackleAmount))))
            for i in stride(from: 0, to: count, by: crackleRate) {
                let offset = Int.random(in: 0..<max(1, crackleRate / 2))
                let idx = min(count - 1, i + offset)
                result[idx] += Float.random(in: -0.02...0.02) * crackleAmount
            }

            // Add continuous low-level surface noise
            let noiseLevel = crackleAmount * 0.003
            for i in 0..<count {
                result[i] += Float.random(in: -noiseLevel...noiseLevel)
            }
        }

        // Wow/flutter: slow pitch modulation via sample interpolation
        if wowFlutter > 0 {
            let wowFreq = 0.5   // Hz (slow warble)
            let flutterFreq = 6.0  // Hz (fast flutter)
            let wowDepth = Double(wowFlutter) * 0.003
            let flutterDepth = Double(wowFlutter) * 0.001
            var modulated = [Float](repeating: 0, count: count)

            for i in 0..<count {
                let t = Double(i) / sampleRate
                let mod = wowDepth * sin(2.0 * .pi * wowFreq * t) +
                          flutterDepth * sin(2.0 * .pi * flutterFreq * t)
                let srcIdx = Double(i) + mod * sampleRate
                let idx0 = Int(srcIdx)
                let frac = Float(srcIdx - Double(idx0))
                if idx0 >= 0 && idx0 + 1 < count {
                    modulated[i] = result[idx0] * (1 - frac) + result[idx0 + 1] * frac
                } else if idx0 >= 0 && idx0 < count {
                    modulated[i] = result[idx0]
                }
            }
            result = modulated
        }

        return result
    }

    // MARK: - Combined Application

    /// Apply a preset (or custom settings) to samples.
    static func apply(preset: LoFiPreset, to samples: [Float], sampleRate: Double) -> [Float] {
        var result = samples
        if preset.bitDepth < 16 {
            result = bitCrush(samples: result, bitDepth: preset.bitDepth)
        }
        if preset.targetSampleRate < sampleRate {
            result = sampleRateReduce(samples: result, originalRate: sampleRate, targetRate: preset.targetSampleRate)
        }
        if preset.drive > 0 {
            result = tapeSaturation(samples: result, drive: preset.drive)
        }
        if preset.crackle > 0 || preset.wowFlutter > 0 {
            result = vinylSim(samples: result, sampleRate: sampleRate, crackleAmount: preset.crackle, wowFlutter: preset.wowFlutter)
        }
        return result
    }
}
