// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IPhonePlugin",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/lagueux/tc4mac-plugin-sdk.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "IPhoneKit",
            dependencies: [.product(name: "TCPluginSDK", package: "tc4mac-plugin-sdk")]),
        .executableTarget(name: "IPhonePlugin", dependencies: ["IPhoneKit"]),
        .testTarget(name: "IPhoneKitTests", dependencies: ["IPhoneKit"])
    ]
)
