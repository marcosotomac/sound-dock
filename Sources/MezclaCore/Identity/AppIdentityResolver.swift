public import Darwin

/// Facts about a process gathered from the OS. Separated from resolution so the rules are testable.
public struct ProcessFacts: Hashable, Sendable {
    public var pid: pid_t
    public var executablePath: String?
    /// Executable of the process macOS holds responsible (the app that launched an XPC service).
    public var responsibleExecutablePath: String?
    public var coreAudioBundleID: String?

    public init(pid: pid_t, executablePath: String?, responsibleExecutablePath: String?, coreAudioBundleID: String?) {
        self.pid = pid
        self.executablePath = executablePath
        self.responsibleExecutablePath = responsibleExecutablePath
        self.coreAudioBundleID = coreAudioBundleID
    }
}

public struct BundleMetadata: Hashable, Sendable {
    public let identifier: String
    public let name: String
    public let isBackgroundOnly: Bool

    public init(identifier: String, name: String, isBackgroundOnly: Bool) {
        self.identifier = identifier
        self.name = name
        self.isBackgroundOnly = isBackgroundOnly
    }
}

public protocol BundleMetadataProviding {
    func metadata(forBundleAt path: String) -> BundleMetadata?
}

/// Groups audio processes under the app the user recognises.
///
/// Browsers and Electron apps play audio from helper processes, and Safari plays it from a shared
/// WebKit service. The rules, in order:
/// 1. A process inside an `.app` belongs to the outermost app (`Chrome.app/…/Chrome Helper.app` → Chrome).
/// 2. A system XPC service belongs to the app macOS holds responsible for it (WebKit GPU → Safari).
/// 3. Anything else stands on its own: command-line tools (`afplay`, `mpv`) or macOS services.
public struct AppIdentityResolver {
    private let bundles: any BundleMetadataProviding

    public init(bundles: any BundleMetadataProviding) {
        self.bundles = bundles
    }

    public func resolve(_ facts: ProcessFacts) -> AppIdentity {
        if let identity = appIdentity(containing: facts.executablePath) {
            return identity
        }
        if Self.isServiceOfResponsibleApp(facts), let identity = appIdentity(containing: facts.responsibleExecutablePath) {
            return identity
        }
        if let executable = facts.executablePath {
            let name = executable.split(separator: "/").last.map(String.init) ?? executable
            let kind: AppIdentity.Kind = Self.isSystemLocation(executable) ? .systemService : .executable
            return AppIdentity(id: AppID("exe:" + executable), name: name, path: executable, kind: kind)
        }
        if let bundleID = facts.coreAudioBundleID {
            let name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return AppIdentity(id: AppID(bundleID), name: name, path: nil, kind: .executable)
        }
        return AppIdentity(id: AppID("pid:\(facts.pid)"), name: "PID \(facts.pid)", path: nil, kind: .executable)
    }

    /// `/Applications/Foo.app/Contents/Frameworks/Bar.app/Contents/MacOS/Bar` → `/Applications/Foo.app`.
    public static func outermostAppBundle(in path: String) -> String? {
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path.hasSuffix(".app") ? path : nil
    }

    private func appIdentity(containing path: String?) -> AppIdentity? {
        guard let path,
              let bundlePath = Self.outermostAppBundle(in: path),
              let metadata = bundles.metadata(forBundleAt: bundlePath)
        else { return nil }
        return AppIdentity(
            id: AppID(metadata.identifier),
            name: metadata.name,
            path: bundlePath,
            kind: metadata.isBackgroundOnly ? .backgroundApplication : .application
        )
    }

    private static let systemLocations = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"]

    private static func isSystemLocation(_ path: String) -> Bool {
        systemLocations.contains { path.hasPrefix($0) }
    }

    private static func isServiceOfResponsibleApp(_ facts: ProcessFacts) -> Bool {
        guard let executable = facts.executablePath else { return true }
        return executable.contains(".xpc/") || (facts.coreAudioBundleID?.hasPrefix("com.apple.WebKit") ?? false)
    }
}
