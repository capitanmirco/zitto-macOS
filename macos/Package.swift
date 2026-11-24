// swift-tools-version:5.9
// The native macOS app of zitto. ZittoCore is plain Foundation, so that its tests also run
// where there is no AppKit; the app itself is built only on macOS.
import PackageDescription

var targets: [Target] = [
    .target(name: "ZittoCore", path: "Sources/ZittoCore"),
    .testTarget(name: "ZittoCoreTests", dependencies: ["ZittoCore"], path: "Tests/ZittoCoreTests"),
]
var products: [Product] = [.library(name: "ZittoCore", targets: ["ZittoCore"])]

#if os(macOS)
targets.append(.executableTarget(name: "Zitto", dependencies: ["ZittoCore"], path: "Sources/Zitto"))
products.append(.executable(name: "Zitto", targets: ["Zitto"]))
#endif

let package = Package(
    name: "Zitto",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
