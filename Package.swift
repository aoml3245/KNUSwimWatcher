// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KNUSwimWatcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KNUSwimWatcher", targets: ["KNUSwimWatcher"]),
        .executable(name: "KNUSwimWatcherSelfTest", targets: ["KNUSwimWatcherSelfTest"])
    ],
    targets: [
        .target(
            name: "WatcherCore",
            path: "Sources/WatcherCore"
        ),
        .executableTarget(
            name: "KNUSwimWatcher",
            dependencies: ["WatcherCore"],
            path: "Sources/KNUSwimWatcher"
        ),
        .executableTarget(
            name: "KNUSwimWatcherSelfTest",
            dependencies: ["WatcherCore"],
            path: "Sources/KNUSwimWatcherSelfTest"
        )
    ],
    swiftLanguageModes: [.v5]
)
