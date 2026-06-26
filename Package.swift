// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmbientGen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AmbientGen",
            path: "Sources",
            exclude: ["Info.plist"],
            resources: [
                .process("Icon.svg")
            ]
        )
    ]
)
