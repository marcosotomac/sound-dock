import CoreFoundation
import Darwin

public enum CapturePermissionStatus: Sendable {
    case authorized
    case denied
    case undetermined
}

/// Access to "System Audio Recording", which process taps require.
public protocol AudioCapturePermissionProviding: Sendable {
    func status() -> CapturePermissionStatus
    /// Shows the system prompt if the user has not decided yet. Returns whether access is granted.
    func request() async -> Bool
}

/// Talks to TCC directly. Apple offers no public API to query this permission, so the functions are
/// resolved at runtime. If they ever disappear we report `.authorized` and let Core Audio prompt.
public struct SystemAudioCapturePermission: AudioCapturePermissionProviding {
    public init() {}

    public func status() -> CapturePermissionStatus {
        guard let preflight = TCC.preflight else { return .authorized }
        switch preflight(TCC.audioCaptureService, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    public func request() async -> Bool {
        guard let request = TCC.request else { return true }
        return await withCheckedContinuation { continuation in
            request(TCC.audioCaptureService, nil) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private enum TCC {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var audioCaptureService: CFString { "kTCCServiceAudioCapture" as CFString }

    // The handle is immutable after first access, and the dynamic loader is thread-safe.
    nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    static let preflight: Preflight? = symbol("TCCAccessPreflight")
    static let request: Request? = symbol("TCCAccessRequest")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
