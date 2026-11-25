public import CoreAudio

/// The Core Audio system object: devices, default output and audio clients.
public enum AudioSystem {
    static let object = AudioObjectID(kAudioObjectSystemObject)

    static let processListAddress = AudioObjectPropertyAddress(kAudioHardwarePropertyProcessObjectList)
    static let devicesAddress = AudioObjectPropertyAddress(kAudioHardwarePropertyDevices)
    static let defaultOutputAddress = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)

    public static func processObjectIDs() -> [AudioObjectID] {
        (try? AudioObjectIO.readArray(object, processListAddress, placeholder: AudioObjectID(0))) ?? []
    }

    public static func devices() -> [AudioDevice] {
        let ids = (try? AudioObjectIO.readArray(object, devicesAddress, placeholder: AudioDeviceID(0))) ?? []
        return ids.map(AudioDevice.init(id:))
    }

    public static func defaultOutputDevice() -> AudioDevice? {
        guard let id = try? AudioObjectIO.read(object, defaultOutputAddress, initial: AudioDeviceID(kAudioObjectUnknown)),
              id != kAudioObjectUnknown
        else { return nil }
        return AudioDevice(id: id)
    }

    public static func setDefaultOutputDevice(_ device: AudioDevice) throws(CoreAudioError) {
        try AudioObjectIO.write(object, defaultOutputAddress, device.id)
    }
}
