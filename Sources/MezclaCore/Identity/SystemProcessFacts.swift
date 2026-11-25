public import Darwin
import Foundation

/// Reads process facts from libproc and Launch Services metadata from app bundles.
public enum SystemProcessFacts {
    public static func facts(pid: pid_t, coreAudioBundleID: String?) -> ProcessFacts {
        let responsible = responsiblePID(of: pid).flatMap { $0 == pid ? nil : $0 }
        return ProcessFacts(
            pid: pid,
            executablePath: executablePath(of: pid),
            responsibleExecutablePath: responsible.flatMap(executablePath(of:)),
            coreAudioBundleID: coreAudioBundleID
        )
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<Int(length)], as: UTF8.self)
    }

    /// Uses the same attribution macOS applies in Activity Monitor and privacy prompts.
    /// The symbol is private API, so it is looked up at runtime and its absence is tolerated.
    public static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let responsibility = ResponsibilitySPI.function else { return nil }
        let result = responsibility(pid)
        return result > 0 ? result : nil
    }
}

private enum ResponsibilitySPI {
    typealias Function = @convention(c) (pid_t) -> pid_t

    static let function: Function? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
}

/// Reads bundle identifier, localized display name and background status. Caches by path.
public final class BundleMetadataCache: BundleMetadataProviding {
    private var cache: [String: BundleMetadata?] = [:]

    public init() {}

    public func metadata(forBundleAt path: String) -> BundleMetadata? {
        if let cached = cache[path] {
            return cached
        }
        let metadata = Self.load(path)
        cache[path] = metadata
        return metadata
    }

    private static func load(_ path: String) -> BundleMetadata? {
        guard let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        // Finder's display name is localized (Music.app is "Música" in Spanish) and has no extension.
        let displayName = FileManager.default.displayName(atPath: path)
        let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        return BundleMetadata(
            identifier: identifier,
            name: name,
            isBackgroundOnly: flag(info["LSUIElement"]) || flag(info["LSBackgroundOnly"])
        )
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        case let string as String: string == "1" || string.lowercased() == "yes" || string.lowercased() == "true"
        default: false
        }
    }
}
