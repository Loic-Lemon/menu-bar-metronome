import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(MetronomeModel.self) private var model
    @State private var outputDevices: [AudioDeviceInfo] = []
    @State private var hasCheckedDevices = false

    var body: some View {
        VStack(spacing: 12) {
            headerRow
            flashToggle
            Toggle(isOn: screenBorderFlashBinding) {
                Label("Screen border flash", systemImage: "rectangle.inset.filled")
            }
            .help("Soft edge glow on every beat, on all screens. Contains flashing light.")
            accentToggle
            volumeSlider
            outputDevicePicker
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            guard !hasCheckedDevices else { return }
            outputDevices = model.audio.availableOutputDevices
            hasCheckedDevices = true
        }
    }

    private var headerRow: some View {
        HStack {
            Label("Settings", systemImage: "gearshape")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
    }

    private var flashToggle: some View {
        Toggle(isOn: flashBinding) {
            Label("Visual flash", systemImage: "circle.dotted")
        }
    }

    private var accentToggle: some View {
        Toggle(isOn: accentBinding) {
            Label("Accent downbeat", systemImage: "speaker.wave.2")
        }
    }

    private var volumeSlider: some View {
        HStack {
            Label("Volume", systemImage: "speaker.fill")
            Slider(value: volumeBinding, in: 0...1)
                .controlSize(.small)
            Text("\(Int(model.volume * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var outputDevicePicker: some View {
        HStack {
            Label("Output", systemImage: "hifispeaker")
            Spacer()
            Picker("", selection: outputDeviceBinding) {
                ForEach(outputDevices) { device in
                    Text(device.name).tag(device.uid as String?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var flashBinding: Binding<Bool> {
        Binding(
            get: { model.visualFlashEnabled },
            set: { model.visualFlashEnabled = $0; model.didChangeVisualFlash() }
        )
    }

    private var screenBorderFlashBinding: Binding<Bool> {
        Binding(
            get: { model.screenBorderFlashEnabled },
            set: { model.screenBorderFlashEnabled = $0; model.didChangeScreenBorderFlash() }
        )
    }

    private var accentBinding: Binding<Bool> {
        Binding(
            get: { model.accentDownbeat },
            set: { model.accentDownbeat = $0; model.didChangeAccentDownbeat() }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { model.volume },
            set: { model.volume = $0; model.didChangeVolume() }
        )
    }

    private var outputDeviceBinding: Binding<String?> {
        Binding(
            get: { model.selectedOutputDeviceUID },
            set: {
                model.selectedOutputDeviceUID = $0
                model.didChangeOutputDevice()
            }
        )
    }

}
