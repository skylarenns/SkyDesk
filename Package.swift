// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkyDesk",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SkyDeskCore", targets: ["SkyDeskCore"]),
               .executable(name: "skydesk-check", targets: ["SkyDeskCheck"])],
    targets: [
        .target(name: "SkyDeskCore", path: "Sources/Core"),
        .executableTarget(name: "SkyDeskCheck", dependencies: ["SkyDeskCore"], path: "Tools/Check"),
        .testTarget(name: "SkyDeskCoreTests", dependencies: ["SkyDeskCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
