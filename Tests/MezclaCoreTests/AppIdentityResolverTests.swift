import MezclaCore
import Testing

@Suite("AppIdentityResolver")
struct AppIdentityResolverTests {
    private struct FakeBundles: BundleMetadataProviding {
        let entries: [String: BundleMetadata]
        func metadata(forBundleAt path: String) -> BundleMetadata? { entries[path] }
    }

    private let resolver = AppIdentityResolver(bundles: FakeBundles(entries: [
        "/Applications/Google Chrome.app": .init(identifier: "com.google.Chrome", name: "Google Chrome", isBackgroundOnly: false),
        "/Applications/Safari.app": .init(identifier: "com.apple.Safari", name: "Safari", isBackgroundOnly: false),
        "/Applications/Ghostty.app": .init(identifier: "com.mitchellh.ghostty", name: "Ghostty", isBackgroundOnly: false),
        "/Applications/Menu Radio.app": .init(identifier: "dev.radio", name: "Menu Radio", isBackgroundOnly: true),
    ]))

    @Test func helperAppsBelongToTheirOutermostApp() {
        let identity = resolver.resolve(.init(
            pid: 10,
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            responsibleExecutablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            coreAudioBundleID: "com.google.Chrome.helper"
        ))
        #expect(identity.id == "com.google.Chrome")
        #expect(identity.name == "Google Chrome")
        #expect(identity.path == "/Applications/Google Chrome.app")
        #expect(identity.kind == .application)
    }

    @Test func systemWebKitServiceBelongsToResponsibleApp() {
        let identity = resolver.resolve(.init(
            pid: 11,
            executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            responsibleExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            coreAudioBundleID: "com.apple.WebKit.GPU"
        ))
        #expect(identity.id == "com.apple.Safari")
    }

    @Test func commandLineToolsStandOnTheirOwn() {
        let identity = resolver.resolve(.init(
            pid: 12,
            executablePath: "/usr/bin/afplay",
            responsibleExecutablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            coreAudioBundleID: nil
        ))
        #expect(identity.id == "exe:/usr/bin/afplay")
        #expect(identity.name == "afplay")
        #expect(identity.kind == .executable)
    }

    @Test func agentAppsAreMarkedAsBackground() {
        let identity = resolver.resolve(.init(
            pid: 13, executablePath: "/Applications/Menu Radio.app/Contents/MacOS/Menu Radio",
            responsibleExecutablePath: nil, coreAudioBundleID: "dev.radio"
        ))
        #expect(identity.kind == .backgroundApplication)
    }

    @Test func unknownProcessFallsBackToBundleIDThenPID() {
        let byBundle = resolver.resolve(.init(pid: 14, executablePath: nil, responsibleExecutablePath: nil, coreAudioBundleID: "com.example.daemon"))
        #expect(byBundle.id == "com.example.daemon")
        #expect(byBundle.name == "daemon")

        let byPID = resolver.resolve(.init(pid: 15, executablePath: nil, responsibleExecutablePath: nil, coreAudioBundleID: nil))
        #expect(byPID.id == "pid:15")
    }

    @Test func outermostBundleIsFound() {
        #expect(AppIdentityResolver.outermostAppBundle(in: "/A.app/Contents/B.app/Contents/MacOS/B") == "/A.app")
        #expect(AppIdentityResolver.outermostAppBundle(in: "/Applications/Music.app") == "/Applications/Music.app")
        #expect(AppIdentityResolver.outermostAppBundle(in: "/usr/bin/say") == nil)
    }
}

extension AppIdentityResolverTests {
    @Test func macOSServicesAreToldApartFromUserTools() {
        let service = resolver.resolve(.init(
            pid: 16, executablePath: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd",
            responsibleExecutablePath: nil, coreAudioBundleID: "com.apple.CoreSpeech"
        ))
        #expect(service.kind == .systemService)

        let tool = resolver.resolve(.init(pid: 17, executablePath: "/opt/homebrew/bin/mpv", responsibleExecutablePath: nil, coreAudioBundleID: nil))
        #expect(tool.kind == .executable)
    }
}
