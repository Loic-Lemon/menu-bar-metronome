import AVFAudio
import Foundation

enum SelfTest {
    static func run() -> Never {
        let result = testScheduling()
        if result {
            print("[SelfTest] PASS")
            exit(0)
        } else {
            print("[SelfTest] FAIL")
            exit(1)
        }
    }

    private static func testScheduling() -> Bool {
        let sr: Double = 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else {
            print("[SelfTest] Failed to create format")
            return false
        }

        let buffers = ClickSynthesizer.generateAllSoundSets(for: format)
        guard let set = buffers[.woodBlock] else {
            print("[SelfTest] No woodBlock buffers"); return false
        }
        let accentBuf = set.accent
        let normalBuf = set.normal

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        } catch {
            print("[SelfTest] enableManualRenderingMode failed: \(error)")
            return false
        }
        do {
            try engine.start()
        } catch {
            print("[SelfTest] engine.start failed: \(error)")
            return false
        }
        player.play()

        let bpm: Double = 120
        let samplesPerBeat = Int64(sr * 60.0 / bpm)
        let lookAheadFrames = Int64(0.3 * sr)
        let beats = 16

        var expectedOnsets: [Int64] = []
        for i in 0..<beats {
            let time = lookAheadFrames + Int64(i) * samplesPerBeat
            expectedOnsets.append(time)
            let isAccent = i % 4 == 0
            let buf: AVAudioPCMBuffer = isAccent ? accentBuf : normalBuf
            player.scheduleBuffer(buf, at: AVAudioTime(sampleTime: time, atRate: sr), options: [])
        }

        let totalFrames = AVAudioFrameCount(lookAheadFrames + Int64(beats) * samplesPerBeat + Int64(0.5 * sr))
        let outputCapacity = AVAudioFrameCount(Double(totalFrames) * 1.1)
        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
            print("[SelfTest] Failed to allocate output buffer"); return false
        }
        outputBuf.frameLength = 0

        let maxChunk = engine.manualRenderingMaximumFrameCount
        var rendered: AVAudioFrameCount = 0
        while rendered < totalFrames {
            let framesToRender = min(maxChunk, totalFrames - rendered)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRender) else { break }
            chunk.frameLength = framesToRender
            do {
                try engine.renderOffline(framesToRender, to: chunk)
            } catch {
                print("[SelfTest] renderOffline failed at frame \(rendered): \(error)")
                return false
            }
            let copyFrames = min(framesToRender, outputCapacity - outputBuf.frameLength)
            if copyFrames == 0 { break }
            for ch in 0..<Int(format.channelCount) {
                guard let src = chunk.floatChannelData?[ch],
                      let dst = outputBuf.floatChannelData?[ch] else { continue }
                memcpy(dst + Int(outputBuf.frameLength), src, Int(copyFrames) * MemoryLayout<Float>.size)
            }
            outputBuf.frameLength += copyFrames
            rendered += framesToRender
        }

        // Onset detection — energy threshold on channel 0
        let energyThreshold: Float = 0.008
        let refractorySamples = Int64(samplesPerBeat) / 2
        var detectedOnsets: [Int64] = []
        guard let data = outputBuf.floatChannelData?[0] else {
            print("[SelfTest] No channel data"); return false
        }
        let frameCount = Int(outputBuf.frameLength)
        let energyWindow = 256
        let halfWin = energyWindow / 2

        var idx = energyWindow
        while idx < frameCount - energyWindow {
            var energy: Float = 0
            for j in (idx - halfWin)...(idx + halfWin) {
                let s = data[j]
                energy += s * s
            }
            energy /= Float(energyWindow)

            if energy > energyThreshold {
                // refine to peak sample in a wider window
                var peakIdx = idx
                var peakVal: Float = 0
                let searchRadius = 512
                let searchStart = max(0, idx - searchRadius)
                let searchEnd = min(frameCount - 1, idx + searchRadius)
                for j in searchStart...searchEnd {
                    let absVal = abs(data[j])
                    if absVal > peakVal {
                        peakVal = absVal
                        peakIdx = j
                    }
                }
                if detectedOnsets.isEmpty || Int64(peakIdx) - detectedOnsets.last! > refractorySamples {
                    detectedOnsets.append(Int64(peakIdx))
                }
                // skip past this event
                idx += energyWindow * 2
                continue
            }
            idx += 1
        }

        guard detectedOnsets.count == beats else {
            print("[SelfTest] Expected \(beats) onsets, found \(detectedOnsets.count)")
            print("[SelfTest] Detected at: \(detectedOnsets)")
            print("[SelfTest] Expected at: \(expectedOnsets)")
            return false
        }

        let tolerance: Int64 = Int64(0.012 * sr)
        for (i, expected) in expectedOnsets.enumerated() {
            let actual = detectedOnsets[i]
            let diff = abs(actual - expected)
            if diff > tolerance {
                print("[SelfTest] Beat \(i): expected \(expected), got \(actual) (diff \(diff) > \(tolerance))")
                return false
            }
        }

        var accentRMS: Float = 0
        var normalRMS: Float = 0
        var accentCount = 0
        var normalCount = 0
        let envWindow = 512

        for (i, onset) in detectedOnsets.enumerated() {
            let start = max(0, Int(onset) - envWindow / 2)
            let end = min(frameCount, Int(onset) + envWindow / 2)
            var sumSq: Float = 0
            var count = 0
            for j in start..<end {
                let s = data[j]
                sumSq += s * s
                count += 1
            }
            let rms = sqrt(sumSq / Float(max(count, 1)))
            if i % 4 == 0 {
                accentRMS += rms
                accentCount += 1
            } else {
                normalRMS += rms
                normalCount += 1
            }
        }

        accentRMS /= Float(max(accentCount, 1))
        normalRMS /= Float(max(normalCount, 1))

        print("[SelfTest] Accent RMS: \(accentRMS), Normal RMS: \(normalRMS)")
        guard accentRMS > normalRMS * 1.1 else {
            print("[SelfTest] Accent not sufficiently louder than normal")
            return false
        }

        return true
    }
}
