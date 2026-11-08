// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Noty",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Noty", targets: ["Noty"]),
        // Widget extension (Live Activity „Schultag“, Widget „Heute“; docs/LIVE-ACTIVITY-PLAN.md).
        // Built and embedded only when xtool.yml lists it under `extensions:`
        // (publish_ota.sh does that for NOTY_CHANNEL=calendar); the other apps build without it.
        .library(name: "NotyCalendarWidgets", targets: ["NotyCalendarWidgets"]),
    ],
    dependencies: [.package(path: "Core")],
    targets: [
        // ActivityKit conformance and App-Group file access shared by app and extension
        // (the activity attributes must be the same type in both).
        .target(name: "NotyCalendarShared", dependencies: [.product(name: "NotebookCore", package: "Core")]),
        .target(name: "Noty", dependencies: [.product(name: "NotebookCore", package: "Core"), "NotyCalendarShared"]),
        .target(
            name: "NotyCalendarWidgets",
            dependencies: [.product(name: "NotebookCore", package: "Core"), "NotyCalendarShared"],
            // xtool links extensions with `-e _NSExtensionMain`; without a reference the
            // linker drops the @main WidgetBundle and the .appex is empty (xtool #313).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_main"])]
        ),
    ]
)
