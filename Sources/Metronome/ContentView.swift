import SwiftUI

struct ContentView: View {
    @Environment(MetronomeModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            beatDotsRow
                .padding(.top, densityPadding)

            tempoSection
                .padding(.top, densityPadding)

            controlsRow
                .padding(.top, densityPadding)

            pickersRow
                .padding(.top, densityPadding)

            Divider()
                .padding(.top, densityPadding)
                .padding(.bottom, 6)
            bottomRow

            if model.showSettings {
                SettingsView()
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, suggestivePaddding)
        .padding(.bottom, densityPadding)
    }

    // MARK: - Beat Dots

    private var beatDotsRow: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<model.timeSignature.beatsPerBar, id: \.self) { idx in
                BeatDotView(
                    index: idx,
                    isActive: idx == model.currentBeatIndex,
                    isPlaying: model.isPlaying,
                    size: dotSize,
                    stroke: dotStroke
                )
            }
        }
        .frame(height: dotSize * 2)
    }

    // MARK: - Tempo Section

    private var tempoSection: some View {
        VStack(spacing: 6) {
            Text("\(Int(model.bpm))")
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.snappy, value: model.bpm)

            Slider(value: bpmBinding, in: 20...300, step: 1)
                .controlSize(.small)

            HStack(spacing: 12) {
                button("-", action: { model.apply(.delta(-1)) })
                Text("BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                button("+", action: { model.apply(.delta(1)) })
            }

            HStack(spacing: 8) {
                ForEach(tempoPresets, id: \.label) { op in
                    button(op.label, width: 34, fontSize: 14, action: { model.apply(op) })
                }
            }
        }
    }

    private let tempoPresets: [TempoOp] = [
        .factor(0.5), .delta(-10), .delta(-5), .delta(5), .delta(10), .factor(2),
    ]

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 4) {
                Button(action: { model.togglePlay() }) {
                    Label(model.isPlaying ? "Stop" : "Play",
                          systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isPlaying ? .red : .green)

                Text(HotkeyManager.playShortcutLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button(action: { model.tap() }) {
                Label("Tap", systemImage: "hand.tap")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Pickers

    private var pickersRow: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Time sig")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: timeSigBinding) {
                    ForEach(TimeSignature.allCases, id: \.self) { ts in
                        Text(ts.label).tag(ts)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("Subdiv")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: subdivisionBinding) {
                    ForEach(Subdivision.allCases, id: \.self) { sd in
                        Text(sd.label).tag(sd)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Bottom Row

    private var bottomRow: some View {
        HStack {
            Picker("", selection: soundSetBinding) {
                ForEach(SoundSet.allCases, id: \.self) { ss in
                    Text(ss.label).tag(ss)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Spacer()

            Button(action: { withAnimation(.easeOut(duration: 0.2)) { model.showSettings.toggle() } }) {
                Image(systemName: model.showSettings ? "gearshape.fill" : "gearshape")
                    .foregroundStyle(model.showSettings ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    // MARK: - Helpers

    private func button(_ label: String, width: CGFloat = 28, fontSize: CGFloat = 16, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .frame(width: width, height: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private let densityPadding: CGFloat = 12
    private let suggestivePaddding: CGFloat = 16
    private let dotSize: CGFloat = 12
    private let dotStroke: CGFloat = 1.5
    private let dotSpacing: CGFloat = 4

    private var bpmBinding: Binding<Double> {
        Binding(
            get: { model.bpm },
            set: { model.bpm = $0; model.didChangeBpm() }
        )
    }

    private var timeSigBinding: Binding<TimeSignature> {
        Binding(
            get: { model.timeSignature },
            set: { model.timeSignature = $0; model.didChangeTimeSignature() }
        )
    }

    private var subdivisionBinding: Binding<Subdivision> {
        Binding(
            get: { model.subdivision },
            set: { model.subdivision = $0; model.didChangeSubdivision() }
        )
    }

    private var soundSetBinding: Binding<SoundSet> {
        Binding(
            get: { model.soundSet },
            set: { model.soundSet = $0; model.didChangeSoundSet() }
        )
    }
}

private struct BeatDotView: View {
    let index: Int
    let isActive: Bool
    let isPlaying: Bool
    let size: CGFloat
    let stroke: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: stroke)
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: size, height: size)

            if isActive && isPlaying {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: size * 0.7, height: size * 0.7)
            }
        }
        .scaleEffect(isActive && isPlaying ? 1.3 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isActive)
    }
}
