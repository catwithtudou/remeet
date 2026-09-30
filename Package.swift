// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Remeet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Remeet", targets: ["Remeet"])],
    targets: [
        .target(name: "RemeetCore"),
        .executableTarget(name: "Remeet", dependencies: ["RemeetCore"]),
        .testTarget(name: "RemeetTests", dependencies: ["RemeetCore", "Remeet"])
    ]
)
