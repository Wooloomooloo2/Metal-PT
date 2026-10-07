// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fw-helper-mac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FWCore", targets: ["FWCore"]),
    ],
    targets: [
        .target(name: "FWCore"),
        .testTarget(name: "FWCoreTests", dependencies: ["FWCore"]),
    ]
)
