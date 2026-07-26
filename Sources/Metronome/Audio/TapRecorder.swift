#if DEBUG
@preconcurrency import AVFAudio
import Foundation

final class TapRecorder: @unchecked Sendable {
    static let shared = TapRecorder()

    private var captureBuffer: AVAudioPCMBuffer?
    private var playerNode: AVAudioPlayerNode?
    private var captureFormat: AVAudioFormat?
    private let maxSeconds: Float64 = 5

    func arm(on player: AVAudioPlayerNode, seconds: Float64 = 5) {
        guard ProcessInfo.processInfo.environment["METRONOME_TAP_RECORD"] == "1" else { return }

        player.removeTap(onBus: 0)

        let format = player.outputFormat(forBus: 0)
        let capacity = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            print("[TapRecorder] Failed to allocate capture buffer")
            return
        }
        buffer.frameLength = 0

        captureBuffer = buffer
        captureFormat = format
        playerNode = player

        player.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] tapBuffer, _ in
            guard let self, let dest = self.captureBuffer, dest.frameLength < dest.frameCapacity else { return }
            let framesToCopy = min(Int(tapBuffer.frameLength), Int(dest.frameCapacity) - Int(dest.frameLength))
            guard framesToCopy > 0 else { return }
            let chCount = Int(min(tapBuffer.format.channelCount, dest.format.channelCount))
            for ch in 0..<chCount {
                guard let src = tapBuffer.floatChannelData?[ch],
                      let dst = dest.floatChannelData?[ch] else { continue }
                let offset = Int(dest.frameLength)
                memcpy(dst + offset, src, framesToCopy * MemoryLayout<Float>.size)
            }
            dest.frameLength += AVAudioFrameCount(framesToCopy)
            if dest.frameLength >= dest.frameCapacity {
                self.finishCapture()
            }
        }

        print("[TapRecorder] Armed, capturing up to \(seconds)s")
    }

    private func finishCapture() {
        guard let playerNode else { return }
        playerNode.removeTap(onBus: 0)
        self.playerNode = nil

        guard let buf = captureBuffer, let fmt = captureFormat else { return }
        captureBuffer = nil
        captureFormat = nil

        let url = URL(fileURLWithPath: "/tmp/metronome-player-tap.caf")
        Task {
            do {
                try? FileManager.default.removeItem(at: url)
                let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                           commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
                try file.write(from: buf)
                print("[TapRecorder] Wrote \(buf.frameLength) frames to \(url.path)")
            } catch {
                print("[TapRecorder] Write failed: \(error)")
            }
        }
    }
}
#endif
