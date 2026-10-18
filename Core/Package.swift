// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotebookCore",
    products: [.library(name: "NotebookCore", targets: ["NotebookCore"])],
    targets: [
        .target(name: "NotebookCore"),
        .testTarget(name: "NotebookCoreTests", dependencies: ["NotebookCore"])
    ]
)
