// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockMirror",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure sync logic: no AppKit, no file I/O, so every rule is unit-testable.
        .target(
            name: "DockMirrorCore",
            path: "Sources/DockMirrorCore"
        ),
        .executableTarget(
            name: "DockMirror",
            dependencies: ["DockMirrorCore"],
            path: "Sources/DockMirror"
        ),
        .testTarget(
            name: "DockMirrorCoreTests",
            dependencies: ["DockMirrorCore"],
            path: "Tests/DockMirrorCoreTests"
        )
    ]
)
