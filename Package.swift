// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "wifi-cli",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "wifi", targets: ["wifi"])],
    targets: [
        .target(name: "WiFiKit"),
        .executableTarget(name: "wifi", dependencies: ["WiFiKit"]),
        .testTarget(name: "WiFiKitTests", dependencies: ["WiFiKit"]),
    ]
)
