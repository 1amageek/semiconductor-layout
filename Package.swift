// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SemiconductorLayout",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LayoutCore", targets: ["LayoutCore"]),
        .library(name: "LayoutTech", targets: ["LayoutTech"]),
        .library(name: "LayoutVerify", targets: ["LayoutVerify"]),
        .library(name: "LayoutIO", targets: ["LayoutIO"]),
        .library(name: "LayoutIntegration", targets: ["LayoutIntegration"]),
        .library(name: "LayoutEditor", targets: ["LayoutEditor"]),
        .library(name: "LayoutAutoGen", targets: ["LayoutAutoGen"]),
    ],
    targets: [
        .target(
            name: "LayoutCore",
            dependencies: []
        ),
        .target(
            name: "LayoutTech",
            dependencies: ["LayoutCore"]
        ),
        .target(
            name: "LayoutVerify",
            dependencies: ["LayoutCore", "LayoutTech"]
        ),
        .target(
            name: "LayoutIO",
            dependencies: ["LayoutCore", "LayoutTech"]
        ),
        .target(
            name: "LayoutIntegration",
            dependencies: ["LayoutCore", "LayoutTech", "LayoutIO", "LayoutVerify"]
        ),
        .target(
            name: "LayoutEditor",
            dependencies: ["LayoutCore", "LayoutTech", "LayoutVerify", "LayoutIO", "LayoutIntegration"]
        ),
        .target(
            name: "LayoutAutoGen",
            dependencies: ["LayoutCore", "LayoutTech"]
        ),
    ]
)
