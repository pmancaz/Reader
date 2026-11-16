// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Reader",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ReaderCore", targets: ["ReaderCore"]), .executable(name: "Reader", targets: ["Reader"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ReaderCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Reader", dependencies: ["ReaderCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "ReaderCoreChecks", dependencies: ["ReaderCore", "CSQLite"], path: "Tests/ReaderCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
