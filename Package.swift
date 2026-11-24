// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fw-helper-mac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FWCore", targets: ["FWCore"]),
        .executable(name: "fwprobe", targets: ["fwprobe"]),
        .executable(name: "fwbench", targets: ["fwbench"]),
    ],
    targets: [
        .target(
            name: "CMacPrivate",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("IOReport"),
            ]
        ),
        .target(name: "FWCore", dependencies: ["CMacPrivate"]),
        .executableTarget(name: "fwprobe", dependencies: ["FWCore"]),
        .executableTarget(name: "fwbench", dependencies: ["FWCore"]),
        .testTarget(name: "FWCoreTests", dependencies: ["FWCore"]),
    ]
)
