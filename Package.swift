// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ScarlettKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ScarlettKit", targets: ["ScarlettKit"])],
    targets: [
        .target(name: "CUSB", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "ScarlettKit", dependencies: ["CUSB"]),
        .executableTarget(name: "scarlett-probe", dependencies: ["ScarlettKit"]),
        .testTarget(name: "ScarlettKitTests", dependencies: ["ScarlettKit"]),
    ]
)
