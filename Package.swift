// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Noty",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Noty", targets: ["Noty"])],
    dependencies: [.package(path: "Core")],
    targets: [
        .target(name: "Noty", dependencies: [.product(name: "NotebookCore", package: "Core")])
    ]
)
