// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "metal-pt",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MPTCore", targets: ["MPTCore"]),
        .executable(name: "mptprobe", targets: ["mptprobe"]),
        .executable(name: "mpt", targets: ["mpt"]),
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
        .target(name: "MPTCore", dependencies: ["CMacPrivate"]),
        .executableTarget(name: "mptprobe", dependencies: ["MPTCore"]),
        .executableTarget(name: "mpt", dependencies: ["MPTCore"]),
        .testTarget(name: "MPTCoreTests", dependencies: ["MPTCore"]),
    ]
)
