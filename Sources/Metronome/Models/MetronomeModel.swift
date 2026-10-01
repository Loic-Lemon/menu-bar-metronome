import SwiftUI
import Observation

@MainActor
@Observable
final class MetronomeModel {
    var bpm: Double = 120
    var timeSignature: TimeSignature = .fourFour
    var subdivision: Subdivision = .quarter
    var soundSet: SoundSet = .woodBlock
    var isPlaying = false
    var currentBeatIndex: Int = 0
    var visualFlashEnabled = true
    var screenBorderFlashEnabled = false
    var accentDownbeat = true
    var volume: Double = 0.7
    var selectedOutputDeviceUID: String?
    var showSettings = false
    var popoverVisible = false

    private(set) var menuBarIconName = "metronome"
    private(set) var menuBarPointerFlipped = false

    let audio = AudioEngine()
    let hotkeys = HotkeyManager()
    @ObservationIgnored private let screenBorderFlash = ScreenBorderFlash()
    private var flashTask: Task<Void, Never>?
    private var taps: [Date] = []

    init() {
        loadPreferences()
        hotkeys.onTogglePlay = { [weak self] in
            let model = self
            Task { @MainActor in
                if model?.isPlaying == true { model?.stop() }
                else { model?.start() }
            }
        }
        hotkeys.onTapTempo = { [weak self] in
            Task { @MainActor in self?.tap() }
        }
        hotkeys.register()
    }

    deinit {
        audio.stop()
    }

    func start() {
        guard !isPlaying else { return }
        do {
            try audio.start(
                bpm: bpm,
                timeSignature: timeSignature,
                subdivision: subdivision,
                soundSet: soundSet,
                accentDownbeat: accentDownbeat,
                volume: volume,
                onBeat: { [weak self] beatIndex, isMainBeat in
                    let model = self
                    Task { @MainActor in
                        guard let model, model.isPlaying else { return }
                        if isMainBeat, model.screenBorderFlashEnabled {
                            model.screenBorderFlash.pulse(bpm: model.bpm)
                        }
                        if model.popoverVisible, model.currentBeatIndex != beatIndex {
                            model.currentBeatIndex = beatIndex
                        }
                        model.menuBarPointerFlipped.toggle()
                        if model.visualFlashEnabled {
                            model.triggerFlash()
                        }
                    }
                }
            )
            isPlaying = true
            currentBeatIndex = 0
        } catch {
            print("Failed to start audio: \(error)")
        }
    }

    func stop() {
        guard isPlaying else { return }
        audio.stop()
        screenBorderFlash.stop()
        isPlaying = false
        currentBeatIndex = 0
        menuBarIconName = "metronome"
    }

    func togglePlay() {
        if isPlaying { stop() }
        else { start() }
    }

    func tap() {
        taps.append(Date.now)
        let window: TimeInterval = 2.0
        let maxTaps = 8
        let recent = taps.suffix(maxTaps).filter { Date.now.timeIntervalSince($0) < window }
        taps = Array(recent)
        guard taps.count >= 2 else { return }
        let intervals = zip(taps.dropFirst(), taps).map { $0.0.timeIntervalSince($0.1) }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        let clamped = min(max(60.0 / average, 20.0), 300.0)
        bpm = round(clamped * 10) / 10
        if isPlaying { stop() }
    }

    func apply(_ op: TempoOp) {
        bpm = op.apply(to: bpm)
        didChangeBpm()
    }

    func didChangeBpm() {
        if isPlaying { stop() }
        savePreferences()
    }

    func didChangeTimeSignature() {
        if isPlaying {
            audio.updateTimeSignature(timeSignature)
        }
        savePreferences()
    }

    func didChangeSubdivision() {
        if isPlaying {
            audio.updateSubdivision(subdivision)
        }
        savePreferences()
    }

    func didChangeSoundSet() {
        if isPlaying {
            audio.updateSoundSet(soundSet)
        }
        savePreferences()
    }

    func didChangeAccentDownbeat() {
        if isPlaying {
            audio.updateAccentDownbeat(accentDownbeat)
        }
        savePreferences()
    }

    func didChangeVolume() {
        if isPlaying {
            audio.updateVolume(volume)
        }
        savePreferences()
    }

    func didChangeOutputDevice() {
        guard let uid = selectedOutputDeviceUID else { return }
        audio.setOutputDevice(uid: uid)
        savePreferences()
    }

    func didChangeVisualFlash() {
        savePreferences()
    }

    func didChangeScreenBorderFlash() {
        if !screenBorderFlashEnabled { screenBorderFlash.stop() }
        savePreferences()
    }

    private func triggerFlash() {
        // ponytail: guard writes on value change — @Observable notifies on every
        // write even when the value is identical, and onBeat fires per subdivision.
        if menuBarIconName != "metronome.fill" {
            menuBarIconName = "metronome.fill"
        }
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            guard let self, self.menuBarIconName != "metronome" else { return }
            self.menuBarIconName = "metronome"
        }
    }

    // MARK: - Persistence

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "bpm") == nil { bpm = 120 }
        else { bpm = defaults.double(forKey: "bpm").clamped(to: 20...300) }
        if let raw = defaults.string(forKey: "timeSignature"),
           let ts = TimeSignature(rawValue: raw) { timeSignature = ts }
        if let raw = defaults.string(forKey: "subdivision"),
           let sd = Subdivision(rawValue: raw) { subdivision = sd }
        if let raw = defaults.string(forKey: "soundSet"),
           let ss = SoundSet(rawValue: raw) { soundSet = ss }
        visualFlashEnabled = defaults.object(forKey: "visualFlashEnabled").flatMap { $0 as? Bool } ?? true
        screenBorderFlashEnabled = defaults.bool(forKey: "screenBorderFlashEnabled")
        accentDownbeat = defaults.object(forKey: "accentDownbeat").flatMap { $0 as? Bool } ?? true
        volume = defaults.object(forKey: "volume").flatMap { $0 as? Double } ?? 0.7
        selectedOutputDeviceUID = defaults.string(forKey: "selectedOutputDeviceUID")
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(bpm, forKey: "bpm")
        defaults.set(timeSignature.rawValue, forKey: "timeSignature")
        defaults.set(subdivision.rawValue, forKey: "subdivision")
        defaults.set(soundSet.rawValue, forKey: "soundSet")
        defaults.set(visualFlashEnabled, forKey: "visualFlashEnabled")
        defaults.set(screenBorderFlashEnabled, forKey: "screenBorderFlashEnabled")
        defaults.set(accentDownbeat, forKey: "accentDownbeat")
        defaults.set(volume, forKey: "volume")
        if let uid = selectedOutputDeviceUID {
            defaults.set(uid, forKey: "selectedOutputDeviceUID")
        } else {
            defaults.removeObject(forKey: "selectedOutputDeviceUID")
        }
    }
}

enum TempoOp: Sendable {
    case delta(Int)
    case factor(Double)

    func apply(to bpm: Double, range: ClosedRange<Double> = 20...300) -> Double {
        let raw: Double
        switch self {
        case .delta(let d): raw = bpm + Double(d)
        case .factor(let f): raw = bpm * f
        }
        return min(max(raw.rounded(), range.lowerBound), range.upperBound)
    }

    var label: String {
        switch self {
        case .delta(let d): return d >= 0 ? "+\(d)" : "\(d)"
        case .factor(let f):
            return f < 1 ? "÷\(Int((1 / f).rounded()))" : "×\(Int(f.rounded()))"
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
