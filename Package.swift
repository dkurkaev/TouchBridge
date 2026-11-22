// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TouchBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "touchbridge",
            path: "Sources/TouchBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
