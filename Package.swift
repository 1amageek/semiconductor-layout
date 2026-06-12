// swift-tools-version: 6.3
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
    dependencies: [
        .package(path: "../swift-mask-data"),
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
            dependencies: [
                "LayoutCore",
                "LayoutTech",
                .product(name: "LayoutIR", package: "swift-mask-data"),
                .product(name: "MaskGeometry", package: "swift-mask-data"),
            ]
        ),
        .target(
            name: "LayoutIO",
            dependencies: [
                "LayoutCore",
                "LayoutTech",
                .product(name: "LayoutIR", package: "swift-mask-data"),
                .product(name: "GDSII", package: "swift-mask-data"),
                .product(name: "OASIS", package: "swift-mask-data"),
                .product(name: "CIF", package: "swift-mask-data"),
                .product(name: "DXF", package: "swift-mask-data"),
                .product(name: "FormatDetector", package: "swift-mask-data"),
                .product(name: "TechIR", package: "swift-mask-data"),
                .product(name: "LEF", package: "swift-mask-data"),
            ]
        ),
        .target(
            name: "LayoutIntegration",
            dependencies: ["LayoutCore", "LayoutTech", "LayoutIO", "LayoutVerify"]
        ),
        .target(
            name: "LayoutEditor",
            dependencies: [
                "LayoutCore",
                "LayoutTech",
                "LayoutVerify",
                "LayoutIO",
                "LayoutIntegration",
                "LayoutAutoGen",
                .product(name: "LayoutIR", package: "swift-mask-data"),
                .product(name: "MaskGeometry", package: "swift-mask-data"),
            ]
        ),
        .target(
            name: "LayoutAutoGen",
            dependencies: ["LayoutCore", "LayoutTech"]
        ),
        .testTarget(
            name: "LayoutIOTests",
            dependencies: [
                "LayoutIO",
                "LayoutCore",
                "LayoutTech",
                .product(name: "LayoutIR", package: "swift-mask-data"),
                .product(name: "TechIR", package: "swift-mask-data"),
                .product(name: "LEF", package: "swift-mask-data"),
            ]
        ),
        .testTarget(
            name: "LayoutAutoGenTests",
            dependencies: [
                "LayoutAutoGen",
                "LayoutCore",
                "LayoutTech",
                "LayoutVerify",
                "LayoutEditor",
            ]
        ),
    ]
)
