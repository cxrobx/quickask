// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickAsk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuickAsk", targets: ["QuickAsk"])],
    targets: [.executableTarget(name: "QuickAsk")]
)
