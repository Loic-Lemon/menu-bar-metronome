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
    private let lookAheadSeconds: Double = 0.15
    private let preScheduleSeconds: Double = 0.6
    private let refillInterval: TimeInterval = 0.3
    private let flashInterval: TimeInterval = 1.0 / 60.0

    private var onBeat: (@Sendable (Int) -> Void)?
    private var scheduledRanges: [ScheduledRange] = []
    private var lastKnownSampleTime: Int64 = 0
    private var lastFiredRange: Range<Int64>?
    private var configObserver: NSObjectProtocol?

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
            print("[AudioEngine] Configuration change — re-preparing engine")
            self.player.stop()
            self.engine.stop()
            guard let format = self.currentFormat else { return }
            let newFormat = self.engine.outputNode.outputFormat(forBus: 0)
            let effectiveFormat = newFormat.sampleRate > 0 ? newFormat : format
            self.currentFormat = effectiveFormat
            self.engine.connect(self.player, to: self.engine.mainMixerNode, format: effectiveFormat)
            self.generateBuffersIfNeeded(format: effectiveFormat)
            self.engine.prepare()
            do {
                try self.engine.start()
                self.lastFiredRange = nil
                self.player.play()
                self._reschedule()
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
            self.player.volume = Float(min(vol * 3.0, 1.0))
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
                format = liveFormat
            } else {
                format = existingFormat
            }
        }

        player.volume = Float(min(volume * 3.0, 1.0))
        player.play()
        print("[AudioEngine] Player is playing (volume: \(min(volume * 3.0, 1.0)))")

        let currentSample = currentRenderSample()
        let sr = format.sampleRate
        nextSampleTime = currentSample + Int64(lookAheadSeconds * sr)
        print("[AudioEngine] First sample at \(nextSampleTime) (current render sample: \(currentSample))")
        beatInBar = 0
        subIndex = 0
        lastFiredRange = nil
        scheduledRanges = []
        scheduleAhead()
        startTimers()

        isRunning = true
    }

    private func _stop() {
        guard isRunning else { return }
        stopTimers()
        player.stop()
        isRunning = false
        print("[AudioEngine] Stopped")
    }

    private func _reschedule() {
        guard isRunning, let format = currentFormat else { return }
        let currentSample = currentRenderSample()
        let sr = format.sampleRate
        nextSampleTime = currentSample + Int64(lookAheadSeconds * sr)
        beatInBar = 0
        subIndex = 0
        lastFiredRange = nil
        scheduledRanges = []
        scheduleAhead()
    }

    private func _resumeAfterDeviceChange() throws {
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

        player.volume = Float(min(volume * 3.0, 1.0))
        player.play()
        print("[AudioEngine] Player resumed after device change (volume: \(min(volume * 3.0, 1.0)))")

        let currentSample = currentRenderSample()
        let sr = format.sampleRate
        nextSampleTime = currentSample + Int64(lookAheadSeconds * sr)
        print("[AudioEngine] Resumed, first sample at \(nextSampleTime) (current render sample: \(currentSample))")
        lastFiredRange = nil
        beatInBar = 0
        subIndex = 0
        scheduledRanges = []
        scheduleAhead()
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
        if let time = engine.mainMixerNode.lastRenderTime ?? player.lastRenderTime {
            lastKnownSampleTime = time.sampleTime
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
        let horizon = currentSample + Int64(preScheduleSeconds * sr)
        let buf = buffers[soundSet]!

        var scheduledCount = 0
        let maxScheduled = 500

        while nextSampleTime < horizon && scheduledCount < maxScheduled {
            let isDownbeat = accentDownbeat && subIndex == 0 && beatInBar == 0
            let isSub = subIndex != 0
            let buffer: AVAudioPCMBuffer = isDownbeat ? buf.accent : (isSub ? buf.subdivision : buf.normal)

            guard buffer.format == engine.mainMixerNode.inputFormat(forBus: 0) else {
                print("[AudioEngine] Format mismatch: buffer \(buffer.format) vs mixer input \(engine.mainMixerNode.inputFormat(forBus: 0)) — regenerating buffers")
                let mixerFormat = engine.mainMixerNode.inputFormat(forBus: 0)
                generateBuffersIfNeeded(format: mixerFormat)
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
        refillTimer?.schedule(deadline: .now() + refillInterval, repeating: refillInterval, leeway: .milliseconds(10))
        refillTimer?.setEventHandler { [weak self] in
            self?.scheduleAhead()
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
