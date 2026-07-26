import AVFAudio

enum ClickSynthesizer {

    typealias BufferSet = (
        accent: AVAudioPCMBuffer,
        normal: AVAudioPCMBuffer,
        subdivision: AVAudioPCMBuffer
    )

    private struct SeededRNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed != 0 ? seed : 1 }
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let bits = UInt32(truncatingIfNeeded: state >> 33)
            return Float(bits) / Float(UInt32.max) * 2.0 - 1.0
        }
    }

    private static func noiseSeed(soundSet: SoundSet, isAccent: Bool) -> UInt64 {
        var s: UInt64 = 0x4D6574726F6E6F6D
        switch soundSet {
        case .woodBlock:   s &+= 0x01
        case .clave:       s &+= 0x02
        case .digitalBeep: s &+= 0x03
        case .rimShot:     s &+= 0x04
        case .cowbell:     s &+= 0x05
        }
        if isAccent { s &+= 0x10 }
        return s
    }

    static func generateAllSoundSets(for format: AVAudioFormat) -> [SoundSet: BufferSet] {
        let sr = format.sampleRate
        var drafts: [SoundSet: BufferSet] = [:]

        for soundSet in SoundSet.allCases {
            let normal = generateDraft(soundSet: soundSet, isAccent: false, sampleRate: sr, format: format)
            let accent = generateDraft(soundSet: soundSet, isAccent: true, sampleRate: sr, format: format)
            let subdivision = generateDraft(soundSet: soundSet, isAccent: false, sampleRate: sr, format: format)
            drafts[soundSet] = (accent, normal, subdivision)
        }

        let drive: Float = 4.5
        let normalTargetRMS: Float = 0.30
        let accentRelativeGain: Float = 1.5849
        let subRelativeGain: Float = 0.5
        let peakLimit: Float = 0.99

        for (_, set) in drafts {
            applySoftClip(to: set.normal, drive: drive)
            applySoftClip(to: set.subdivision, drive: drive)
            applySoftClip(to: set.accent, drive: drive)
        }

        for (_, set) in drafts {
            applyAttackFade(to: set.normal, attackTime: 0.002, sampleRate: sr)
            applyAttackFade(to: set.subdivision, attackTime: 0.002, sampleRate: sr)
            applyAttackFade(to: set.accent, attackTime: 0.002, sampleRate: sr)

            normalizeAndLimit(buffer: set.normal, targetRMS: normalTargetRMS, peakLimit: peakLimit)
            normalizeAndLimit(buffer: set.subdivision, targetRMS: normalTargetRMS * subRelativeGain, peakLimit: peakLimit)
            normalizeAndLimit(buffer: set.accent, targetRMS: normalTargetRMS * accentRelativeGain, peakLimit: peakLimit)
        }

        return drafts
    }

    private static func generateDraft(
        soundSet: SoundSet,
        isAccent: Bool,
        sampleRate: Double,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let duration: Double = baseDuration(for: soundSet)
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("Failed to create buffer")
        }
        buffer.frameLength = frameCount

        var rng = SeededRNG(seed: Self.noiseSeed(soundSet: soundSet, isAccent: isAccent))
        let channelCount = Int(format.channelCount)
        for ch in 0..<channelCount {
            guard let ptr = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                ptr[i] = Float(sample(soundSet: soundSet, isAccent: isAccent, t: t, duration: duration, rng: &rng))
            }
        }
        return buffer
    }

    private static func baseDuration(for soundSet: SoundSet) -> Double {
        switch soundSet {
        case .woodBlock:   0.035
        case .clave:       0.030
        case .digitalBeep: 0.025
        case .rimShot:     0.015
        case .cowbell:     0.055
        }
    }

    private static func sample(
        soundSet: SoundSet,
        isAccent: Bool,
        t: Double,
        duration: Double,
        rng: inout SeededRNG
    ) -> Float {
        let fd = Float(t)
        let envT = Float(t) / Float(duration)

        switch soundSet {
        case .woodBlock:
            let env = exp(-envT * 20)
            if isAccent {
                return (sin(2 * .pi * 3000 * fd) + 0.6 * sin(2 * .pi * 4400 * fd)) * env * 0.5
            } else {
                return (sin(2 * .pi * 1500 * fd) + 0.6 * sin(2 * .pi * 2200 * fd)) * env * 0.5
            }

        case .clave:
            let pitchBase: Float = isAccent ? 4000 : 2500
            let pitchDrop = pitchBase - 300 * envT
            let env = exp(-envT * 15)
            let phase = pitchDrop * fd - floor(pitchDrop * fd)
            let tri: Float = 2 * abs(2 * phase - 1) - 1
            return tri * env * 0.6

        case .digitalBeep:
            let freq: Float = isAccent ? 1500 : 1000
            let env = exp(-envT * 18)
            let sq: Float = sin(2 * .pi * freq * fd) > 0 ? 1.0 : -1.0
            let noise = rng.next() * 0.05
            return (sq + noise) * env * 0.4

        case .rimShot:
            let env = exp(-envT * 30)
            if isAccent {
                let noise = rng.next()
                let highTone = sin(2 * .pi * 4000 * fd)
                return noise * highTone * env * 0.5
            } else {
                return rng.next() * env * 0.5
            }

        case .cowbell:
            let f1: Float = isAccent ? 1200 : 800
            let f2: Float = isAccent ? 800 : 540
            let env = exp(-envT * 10)
            let s1 = sin(2 * .pi * f1 * fd)
            let s2 = sin(2 * .pi * f2 * fd)
            let modEnv = exp(-envT * 4)
            return (s1 + 0.5 * s2 * modEnv) * env * 0.5
        }
    }

    // MARK: - Helpers

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        var count = 0
        for ch in 0..<channelCount {
            guard let ptr = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<frameCount {
                let s = ptr[i]
                sum += s * s
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return sqrt(sum / Float(count))
    }

    private static func applyAttackFade(
        to buffer: AVAudioPCMBuffer,
        attackTime: Double,
        sampleRate: Double
    ) {
        let attackSamples = max(1, Int(attackTime * sampleRate))
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = min(Int(buffer.frameLength), attackSamples)
        for ch in 0..<channelCount {
            guard let ptr = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<frameCount {
                ptr[i] *= Float(i) / Float(attackSamples)
            }
        }
    }

    private static func applySoftClip(to buffer: AVAudioPCMBuffer, drive: Float) {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        for ch in 0..<channelCount {
            guard let ptr = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<frameCount {
                ptr[i] = tanh(ptr[i] * drive)
            }
        }
    }

    private static func normalizeAndLimit(
        buffer: AVAudioPCMBuffer,
        targetRMS: Float,
        peakLimit: Float
    ) {
        let currentRMS = rms(of: buffer)
        guard currentRMS > 0 else { return }
        let scale = targetRMS / currentRMS
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        for ch in 0..<channelCount {
            guard let ptr = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<frameCount {
                ptr[i] = max(-peakLimit, min(peakLimit, ptr[i] * scale))
            }
        }
    }
}
