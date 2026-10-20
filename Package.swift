// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kumquat",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Kumquat",
            path: "Sources/Kumquat",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "KumquatTests", dependencies: ["Kumquat"], path: "Tests/KumquatTests")
    ]
)
