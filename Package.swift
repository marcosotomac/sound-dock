// swift-tools-version: 6.0
import PackageDescription

let strictSwift: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Mezcla",
    platforms: [.macOS("14.2")], // Core Audio process taps arrived in macOS 14.2.
    products: [
        .executable(name: "Mezcla", targets: ["Mezcla"]),
        .executable(name: "MezclaBridge", targets: ["MezclaBridge"]),
        .executable(name: "MezclaSafariExtension", targets: ["MezclaSafariExtension"]),
    ],
    targets: [
        // Real-time audio kernel. Plain C so the render callback never touches the Swift runtime.
        .target(
            name: "MezclaDSP",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // The private socket shared by the app and its browser bridge. Foundation only.
        .target(
            name: "MezclaBridgeShared",
            swiftSettings: strictSwift
        ),
        // Native messaging host launched by Chromium browsers for the Mezcla extension.
        .executableTarget(
            name: "MezclaBridge",
            dependencies: ["MezclaBridgeShared"],
            swiftSettings: strictSwift
        ),
        // Native half of the Safari web extension, packaged as Mezcla.app/Contents/PlugIns/MezclaSafari.appex.
        .executableTarget(
            name: "MezclaSafariExtension",
            swiftSettings: strictSwift,
            linkerSettings: [
                .linkedFramework("SafariServices"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        // Core Audio wrappers, process taps, app identity, browser tabs and the mixer engine. No UI.
        .target(
            name: "MezclaCore",
            dependencies: ["MezclaDSP", "MezclaBridgeShared"],
            swiftSettings: strictSwift,
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        // Menu bar app: SwiftUI views, view model, persistence and system services.
        .executableTarget(
            name: "Mezcla",
            dependencies: ["MezclaCore"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "MezclaCoreTests",
            dependencies: ["MezclaCore", "MezclaDSP", "MezclaBridgeShared"],
            swiftSettings: strictSwift
        ),
    ]
)
