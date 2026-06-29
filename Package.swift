// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ambeat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ambeat",
            path: "Sources",
            exclude: ["Info.plist", "Ambeat.entitlements", "AppIcon.icns", "App icon.svg"],
            resources: [
                .process("Icon.svg")
            ]
        )
    ]
)
