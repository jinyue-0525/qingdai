// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QingDai",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QingDai", targets: ["QingDai"])],
    targets: [.executableTarget(name: "QingDai")],
    swiftLanguageVersions: [.v5]
)
