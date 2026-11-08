// swift-tools-version: 6.0
// Push-Dienst für noty calendar (docs/PUSH.md). Linux-Server, getrennt von
// der App und von Core/Package.swift. Bindet NotebookCore per Pfad ein:
// WebUntis-Anfragen/Parsing, Snapshot und Änderungserkennung kommen aus Core
// (eine Quelle der Wahrheit mit der App).
import PackageDescription

let package = Package(
    name: "NotyPush",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "noty-push", targets: ["noty-push"])],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(name: "NotyPushKit", dependencies: [
            .product(name: "NotebookCore", package: "Core"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "noty-push", dependencies: ["NotyPushKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NotyPushKitTests", dependencies: ["NotyPushKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
