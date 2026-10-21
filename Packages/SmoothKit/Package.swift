// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmoothKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SmoothKit", targets: ["SCCore", "SCCapture", "SCProject", "SCRender", "SCExport"]),
    ],
    targets: [
        // Pure value types: project document, settings, telemetry. No AppKit, no I/O.
        .target(name: "SCCore"),
        // Permissions, ScreenCaptureKit recording, input telemetry.
        .target(name: "SCCapture", dependencies: ["SCCore"]),
        // .smoothcursor package I/O, library, autosave.
        .target(name: "SCProject", dependencies: ["SCCore"]),
        // Metal render graph shared by preview and export.
        .target(name: "SCRender", dependencies: ["SCCore"]),
        // Offline rendering to file via AVAssetWriter / VideoToolbox.
        .target(name: "SCExport", dependencies: ["SCCore", "SCRender", "SCProject"]),
        // Developer tool: `swift run sc-record --seconds 3` records the main display into a temp package.
        .executableTarget(name: "sc-record", dependencies: ["SCCore", "SCCapture"]),
        // Developer tool: `swift run sc-render <package> --time 2 --out frame.png` renders one frame offline.
        .executableTarget(name: "sc-render", dependencies: ["SCCore", "SCProject", "SCRender"]),
        // Developer tool: `swift run sc-export <package> --out file.mp4` exports a project.
        .executableTarget(name: "sc-export", dependencies: ["SCCore", "SCProject", "SCRender", "SCExport"]),
        .testTarget(name: "SCCoreTests", dependencies: ["SCCore", "SCProject", "SCCapture"]),
    ]
)
