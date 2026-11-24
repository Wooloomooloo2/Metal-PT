// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "metal-pt",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MPTCore", targets: ["MPTCore"]),
        .library(name: "MPTApp", targets: ["MPTApp"]),
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
        .target(name: "MPTApp", dependencies: ["MPTCore"]),
        .executableTarget(name: "mptprobe", dependencies: ["MPTCore"]),
        .executableTarget(name: "mpt", dependencies: ["MPTCore"]),
        .testTarget(name: "MPTCoreTests", dependencies: ["MPTCore"]),
        .testTarget(name: "MPTAppTests", dependencies: ["MPTApp", "MPTCore"]),
    ]
)
