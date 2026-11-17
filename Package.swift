// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThreadClip",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ThreadClip", targets: ["ThreadClip"])],
    targets: [
        .target(name: "ThreadHangerCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ThreadClip", dependencies: ["ThreadHangerCore"]),
        .testTarget(name: "ThreadHangerCoreTests", dependencies: ["ThreadHangerCore"]),
        .testTarget(name: "ThreadHangerUITests", dependencies: ["ThreadClip"])
    ]
)
