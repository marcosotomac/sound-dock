import CoreAudio

extension AudioObjectPropertyAddress {
    init(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Typed access to the Core Audio property API. Everything else in the package goes through here.
///
/// Values travel as raw bytes, which is what the HAL expects. Object-valued properties (CFString,
/// CATapDescription) are passed as a single reference, exactly like the C API.
enum AudioObjectIO {
    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func read<Value>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        initial: Value
    ) throws(CoreAudioError) -> Value {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        try status.check("Read \(FourCharacterCode(address.mSelector)) of object \(object)")
        return value
    }

    static func readArray<Element>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        placeholder: Element
    ) throws(CoreAudioError) -> [Element] {
        var address = address
        var size: UInt32 = 0
        try AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
            .check("Size \(FourCharacterCode(address.mSelector)) of object \(object)")
        let count = Int(size) / MemoryLayout<Element>.stride
        guard count > 0 else { return [] }

        var elements = [Element](repeating: placeholder, count: count)
        let status = elements.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        try status.check("Read \(FourCharacterCode(address.mSelector)) of object \(object)")
        return Array(elements.prefix(Int(size) / MemoryLayout<Element>.stride))
    }

    static func readString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws(CoreAudioError) -> String {
        let reference = try read(object, address, initial: Unmanaged<CFString>?.none)
        guard let reference else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "Read string \(FourCharacterCode(address.mSelector))")
        }
        return reference.takeRetainedValue() as String
    }

    static func write<Value>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ value: Value
    ) throws(CoreAudioError) {
        var address = address
        var value = value
        let status = withUnsafeBytes(of: &value) { bytes in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
        }
        try status.check("Write \(FourCharacterCode(address.mSelector)) of object \(object)")
    }
}
