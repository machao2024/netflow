// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetFlow",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NetFlow", targets: ["NetFlow"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "NetFlowCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "NetFlow", dependencies: ["NetFlowCore"]),
        .testTarget(name: "NetFlowCoreTests", dependencies: ["NetFlowCore"])
    ]
)
