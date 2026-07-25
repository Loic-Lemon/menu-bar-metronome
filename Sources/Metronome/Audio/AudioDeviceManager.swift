import CoreAudio
import AVFAudio
import AudioUnit

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var identifier: String { uid }
}

final class AudioDeviceManager: @unchecked Sendable {
    private var cachedDevices: [AudioDeviceInfo] = []
    private var propertyListener: AudioObjectPropertyListenerProc?

    var availableDevices: [AudioDeviceInfo] {
        enumerateDevices()
    }

    var defaultOutputDevice: AudioDeviceInfo? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard err == noErr else { return nil }
        return findDevice(by: deviceID)
    }

    func setOutputDevice(uid: String, on engine: AVAudioEngine) throws {
        guard let device = enumerateDevices().first(where: { $0.uid == uid }) else {
            throw AudioError.deviceNotFound
        }

        let auAudioUnit = engine.outputNode.auAudioUnit
        auAudioUnit.setValue(device.id, forKey: "deviceID")
    }

    func findDevice(by uid: String) -> AudioDeviceInfo? {
        enumerateDevices().first { $0.uid == uid }
    }

    private func findDevice(by id: AudioDeviceID) -> AudioDeviceInfo? {
        enumerateDevices().first { $0.id == id }
    }

    private func enumerateDevices() -> [AudioDeviceInfo] {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize
        ) == noErr else { return [] }

        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &devices
        ) == noErr else { return [] }

        return devices.compactMap { deviceID in
            guard deviceHasOutputChannels(deviceID),
                  let name = getDeviceName(deviceID),
                  let uid = getDeviceUID(deviceID) else { return nil }
            return AudioDeviceInfo(id: deviceID, uid: uid, name: name)
        }
    }

    private func deviceHasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }

        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPtr) == noErr else { return false }

        let bufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
        let ptr = UnsafeMutableAudioBufferListPointer(bufferList)
        return ptr.contains(where: { $0.mNumberChannels > 0 })
    }

    private func getDeviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard err == noErr, let n = name?.takeRetainedValue() as String? else { return nil }
        return n
    }

    private func getDeviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid)
        guard err == noErr, let u = uid?.takeRetainedValue() as String? else { return nil }
        return u
    }

}

enum AudioError: Error, LocalizedError {
    case deviceNotFound
    case noAudioUnit
    case noOutputDevice
    case setPropertyFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: "Audio output device not found"
        case .noAudioUnit: "Could not access audio unit"
        case .noOutputDevice: "No audio output device available"
        case .setPropertyFailed(let err): "Failed to configure audio (OSStatus: \(err))"
        }
    }
}
