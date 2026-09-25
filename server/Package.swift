// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ComputerUseServer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "computer-use-server",
            path: "Sources/ComputerUseServer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .testTarget(
            name: "ComputerUseServerTests",
            dependencies: ["computer-use-server"],
            path: "Tests/ComputerUseServerTests"
        ),
    ]
)
