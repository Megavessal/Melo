// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Melo",
    platforms: [
        .macOS("15.4")
    ],
    products: [
        .executable(name: "Melo", targets: ["Melo"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/wadetregaskis/FluidMenuBarExtra.git",
            exact: "1.0.0"
        ),
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts.git",
            exact: "2.4.0"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.5"
        )
    ],
    targets: [
        .executableTarget(
            name: "Melo",
            dependencies: [
                .product(name: "FluidMenuBarExtra", package: "FluidMenuBarExtra"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Melo",
            exclude: ["Assets.xcassets"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("AppIntents"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreAudioKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
