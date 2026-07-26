import AVFAudio
import Dispatch

final class AudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let deviceManager = AudioDeviceManager()
    private let queue = DispatchQueue(label: "com.loic.metronome.audio", qos: .userInitiated)

    private var refillTimer: DispatchSourceTimer?
    private var flashTimer: DispatchSourceTimer?

    private var bpm: Double = 120
    private var timeSignature: TimeSignature = .fourFour
    private var subdivision: Subdivision = .quarter
    private var soundSet: SoundSet = .woodBlock
    private var accentDownbeat = true
    private var volume: Double = 0.7
    private var isRunning = false

    private typealias BufferSet = (accent: AVAudioPCMBuffer, normal: AVAudioPCMBuffer, subdivision: AVAudioPCMBuffer)
    private var buffers: [SoundSet: BufferSet] = [:]
    private var currentFormat: AVAudioFormat?
    private var buffersFormat: AVAudioFormat?

    private var nextSampleTime: Int64 = 0
    private var beatInBar: Int = 0
    private var subIndex: Int = 0
    private let lookAheadSeconds: Double = 0.30
    private let preScheduleSeconds: Double = 1.0
    private let refillInterval: TimeInterval = 0.2
    private let flashInterval: TimeInterval = 1.0 / 60.0

    private var onBeat: (@Sendable (Int) -> Void)?
    private var scheduledRanges: [ScheduledRange] = []
    private var lastKnownSampleTime: Int64 = 0
    private var lastFiredRange: Range<Int64>?
    private var configObserver: NSObjectProtocol?
    private var clockAnchored = false

    init() {
        engine.attach(player)
        subscribeToEngineChanges()
    }

    deinit {
        if let token = configObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func subscribeToEngineChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        queue.async {
            guard self.isRunning else { return }
            let newFormat = self.engine.outputNode.outputFormat(forBus: 0)
            guard newFormat.sampleRate > 0, newFormat != self.currentFormat else {
                if newFormat.sampleRate <= 0 {
                    print("[AudioEngine] Configuration change — no output format, ignoring")
                } else {
                    print("[AudioEngine] Configuration change — format unchanged, ignoring")
                }
                return
            }
            print("[AudioEngine] Configuration change — format changed, re-preparing engine")
            self.player.stop()
            self.engine.stop()
            guard let format = self.currentFormat else { return }
            let effectiveFormat = newFormat.sampleRate > 0 ? newFormat : format
            self.currentFormat = effectiveFormat
            self.engine.connect(self.player, to: self.engine.mainMixerNode, format: effectiveFormat)
            self.generateBuffersIfNeeded(format: effectiveFormat)
            self.engine.prepare()
            do {
                try self.engine.start()
                self.lastFiredRange = nil
                self.lastKnownSampleTime = 0
                self.nextSampleTime = 0
                self.player.volume = Float(self.volume)
                self.player.play()
                self.clockAnchored = false
                self.scheduledRanges = []
                print("[AudioEngine] Engine restarted after config change, waiting for clock anchor")
            } catch {
                print("[AudioEngine] Failed to restart after configuration change: \(error)")
                self.isRunning = false
            }
        }
    }

    func start(
        bpm: Double,
        timeSignature: TimeSignature,
        subdivision: Subdivision,
        soundSet: SoundSet,
        accentDownbeat: Bool,
        volume: Double,
        onBeat: @escaping @Sendable (Int) -> Void
    ) throws {
        self.bpm = bpm
        self.timeSignature = timeSignature
        self.subdivision = subdivision
        self.soundSet = soundSet
        self.accentDownbeat = accentDownbeat
        self.volume = volume
        self.onBeat = onBeat

        try queue.sync { try self._start() }
    }

    func stop() {
        queue.sync { self._stop() }
    }

    func updateBpm(_ bpm: Double) {
        queue.sync {
            self.bpm = bpm
            if self.isRunning { self._reschedule() }
        }
    }

    func updateTimeSignature(_ ts: TimeSignature) {
        queue.sync {
            self.timeSignature = ts
            if self.isRunning { self._reschedule() }
        }
    }

    func updateSubdivision(_ sd: Subdivision) {
        queue.sync {
            self.subdivision = sd
            if self.isRunning { self._reschedule() }
        }
    }

    func updateSoundSet(_ ss: SoundSet) {
        queue.sync {
            self.soundSet = ss
            if self.isRunning { self._reschedule() }
        }
    }

    func updateAccentDownbeat(_ accent: Bool) {
        queue.sync {
            self.accentDownbeat = accent
        }
    }

    func updateVolume(_ vol: Double) {
        queue.sync {
            self.volume = vol
            self.player.volume = Float(vol)
        }
    }

    func setOutputDevice(uid: String) {
        queue.sync {
            let wasRunning = self.isRunning
            if wasRunning {
                self._stop()
                self.engine.stop()
            }
            do {
                try self.deviceManager.setOutputDevice(uid: uid, on: self.engine)
            } catch {
                print("Failed to set output device: \(error)")
            }
            if wasRunning { try? self._resumeAfterDeviceChange() }
        }
    }

    var availableOutputDevices: [AudioDeviceInfo] {
        deviceManager.availableDevices
    }

    var currentOutputDevice: AudioDeviceInfo? {
        deviceManager.defaultOutputDevice
    }

    // MARK: - Private (call on queue)

    private func ensureClockAnchor() -> Bool {
        if clockAnchored { return true }
        guard let format = currentFormat,
              let nodeTime = engine.mainMixerNode.lastRenderTime,
              let pt = player.playerTime(forNodeTime: nodeTime),
              pt.sampleTime >= 0,
              pt.sampleTime < Int64(format.sampleRate)
        else { return false }
        clockAnchored = true
        lastKnownSampleTime = pt.sampleTime
        nextSampleTime = pt.sampleTime + Int64(lookAheadSeconds * format.sampleRate)
        beatInBar = 0
        subIndex = 0
        lastFiredRange = nil
        scheduledRanges = []
        print("[AudioEngine] Clock anchored at \(pt.sampleTime)")
        return true
    }

    private func _start() throws {
        guard !isRunning else { return }

        let format: AVAudioFormat
        if !engine.isRunning {
            format = engine.outputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw AudioError.noOutputDevice }
            currentFormat = format

            print("[AudioEngine] Output format: \(format.sampleRate) Hz, \(format.channelCount) ch, common format \(format.commonFormat.rawValue)")

            engine.connect(player, to: engine.mainMixerNode, format: format)
            generateBuffersIfNeeded(format: format)

            engine.prepare()
            try engine.start()
            print("[AudioEngine] Engine started successfully")
        } else {
            guard let existingFormat = currentFormat else { throw AudioError.noOutputDevice }
            let liveFormat = engine.outputNode.outputFormat(forBus: 0)
            if liveFormat.sampleRate > 0 && liveFormat != existingFormat {
                currentFormat = liveFormat
                engine.connect(player, to: engine.mainMixerNode, format: liveFormat)
                generateBuffersIfNeeded(format: liveFormat)
                format = liveFormat
            } else {
                format = existingFormat
            }
        }

        player.volume = Float(volume)
        player.play()
        print("[AudioEngine] Player is playing (volume: \(volume))")

#if DEBUG
        TapRecorder.shared.arm(on: player)
#endif

        clockAnchored = false
        lastFiredRange = nil
        scheduledRanges = []
        lastKnownSampleTime = 0
        nextSampleTime = 0
        startTimers()

        isRunning = true
    }

    private func _stop() {
        guard isRunning else { return }
        stopTimers()
        player.stop()
        scheduledRanges = []
        lastFiredRange = nil
        lastKnownSampleTime = 0
        nextSampleTime = 0
        clockAnchored = false
        isRunning = false
        print("[AudioEngine] Stopped")
    }

    private func _reschedule() {
        guard isRunning, currentFormat != nil else { return }
        player.stop()
        player.play()
        clockAnchored = false
        lastFiredRange = nil
        scheduledRanges = []
        lastKnownSampleTime = 0
        nextSampleTime = 0
        print("[AudioEngine] Rescheduled, waiting for clock anchor")
    }

    private func _resumeAfterDeviceChange() throws {
        guard !isRunning else { return }
        // Engine was stopped by setOutputDevice; restart with new device
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw AudioError.noOutputDevice }
        currentFormat = format

        print("[AudioEngine] Resuming after device change, format: \(format.sampleRate) Hz, \(format.channelCount) ch")

        engine.connect(player, to: engine.mainMixerNode, format: format)
        generateBuffersIfNeeded(format: format)

        engine.prepare()
        try engine.start()
        print("[AudioEngine] Engine restarted after device change")

        player.volume = Float(volume)
        player.play()
        print("[AudioEngine] Player resumed after device change (volume: \(volume))")

        lastFiredRange = nil
        lastKnownSampleTime = 0
        nextSampleTime = 0
        scheduledRanges = []
        clockAnchored = false
        stopTimers()
        startTimers()
        isRunning = true
    }

    private func generateBuffersIfNeeded(format: AVAudioFormat) {
        if buffersFormat != format {
            buffers = ClickSynthesizer.generateAllSoundSets(for: format)
            buffersFormat = format
        }
    }

    private func currentRenderSample() -> Int64 {
        if clockAnchored,
           let nodeTime = engine.mainMixerNode.lastRenderTime,
           let pt = player.playerTime(forNodeTime: nodeTime) {
            lastKnownSampleTime = pt.sampleTime
            return lastKnownSampleTime
        }
        return lastKnownSampleTime
    }

    private func scheduleAhead() {
        guard let format = currentFormat else { return }
        let sr = format.sampleRate
        let samplesPerSub = Int64(sr * 60.0 / bpm / Double(subdivision.count))
        guard samplesPerSub > 0 else { return }

        let currentSample = currentRenderSample()

        let minLead = Int64(0.05 * sr)
        if nextSampleTime < currentSample + minLead {
            print("[AudioEngine] Clock skip (next=\(nextSampleTime) now=\(currentSample)) — resyncing")
            nextSampleTime = currentSample + Int64(lookAheadSeconds * sr)
            beatInBar = 0
            subIndex = 0
        }

        let horizon = currentSample + Int64(preScheduleSeconds * sr)
        guard let buf = buffers[soundSet] else { return }

        var scheduledCount = 0
        let maxScheduled = 500

        while nextSampleTime < horizon && scheduledCount < maxScheduled {
            let isDownbeat = accentDownbeat && subIndex == 0 && beatInBar == 0
            let isSub = subIndex != 0
            let buffer: AVAudioPCMBuffer = isDownbeat ? buf.accent : (isSub ? buf.subdivision : buf.normal)

            let mixerFormat = engine.mainMixerNode.inputFormat(forBus: 0)
            if buffer.format != mixerFormat
                && buffersFormat?.sampleRate != mixerFormat.sampleRate {
                print("[AudioEngine] Sample-rate mismatch: buffer \(buffer.format.sampleRate) vs mixer input \(mixerFormat.sampleRate) — regenerating buffers")
                generateBuffersIfNeeded(format: mixerFormat)
                engine.connect(player, to: engine.mainMixerNode, format: mixerFormat)
                currentFormat = mixerFormat
                scheduleAhead()
                return
            }
            let scheduleTime = AVAudioTime(sampleTime: nextSampleTime, atRate: sr)
            player.scheduleBuffer(buffer, at: scheduleTime, options: [])

            let rangeStart = nextSampleTime
            let rangeEnd = nextSampleTime + Int64(buffer.frameLength)
            scheduledRanges.append(ScheduledRange(
                sampleRange: rangeStart..<rangeEnd,
                beat: beatInBar,
                isDownbeat: isDownbeat
            ))

            subIndex += 1
            if subIndex >= subdivision.count {
                subIndex = 0
                beatInBar = (beatInBar + 1) % timeSignature.beatsPerBar
            }
            nextSampleTime += samplesPerSub
            scheduledCount += 1
        }


    }

    private func startTimers() {
        refillTimer = DispatchSource.makeTimerSource(queue: queue)
        refillTimer?.schedule(deadline: .now() + 0.05, repeating: refillInterval, leeway: .milliseconds(10))
        refillTimer?.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            if self.ensureClockAnchor() { self.scheduleAhead() }
        }
        refillTimer?.resume()

        flashTimer = DispatchSource.makeTimerSource(queue: queue)
        flashTimer?.schedule(deadline: .now() + flashInterval, repeating: flashInterval, leeway: .milliseconds(5))
        flashTimer?.setEventHandler { [weak self] in
            self?.checkFlash()
        }
        flashTimer?.resume()
    }

    private func stopTimers() {
        refillTimer?.cancel()
        refillTimer = nil
        flashTimer?.cancel()
        flashTimer = nil
    }

    private func checkFlash() {
        let currentSample = currentRenderSample()
        while let first = scheduledRanges.first, first.sampleRange.upperBound < currentSample {
            scheduledRanges.removeFirst()
        }
        for range in scheduledRanges {
            if range.sampleRange.contains(currentSample) {
                if range.sampleRange != lastFiredRange {
                    lastFiredRange = range.sampleRange
                    onBeat?(range.beat)
                }
                break
            }
        }
    }
}

private struct ScheduledRange {
    let sampleRange: Range<Int64>
    let beat: Int
    let isDownbeat: Bool
}
