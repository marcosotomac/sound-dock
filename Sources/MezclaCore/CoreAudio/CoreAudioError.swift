public import CoreAudio

/// A failed Core Audio call, carrying the operation for diagnostics.
public struct CoreAudioError: Error, Hashable, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String {
        "\(operation) failed with \(FourCharacterCode(UInt32(bitPattern: status))) (\(status))"
    }
}

extension OSStatus {
    /// Throws a `CoreAudioError` unless the status is `noErr`.
    func check(_ operation: @autoclosure () -> String) throws(CoreAudioError) {
        guard self == noErr else {
            throw CoreAudioError(status: self, operation: operation())
        }
    }
}

/// Renders Core Audio's four-character codes ('!obj', 'who?') and falls back to the number.
struct FourCharacterCode: CustomStringConvertible {
    let value: UInt32

    init(_ value: UInt32) {
        self.value = value
    }

    var description: String {
        let bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return String(value)
        }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}
