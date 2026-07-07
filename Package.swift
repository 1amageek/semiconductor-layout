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
        .library(name: "LayoutEngine", targets: ["LayoutEngine"]),
        .library(name: "LayoutCommands", targets: ["LayoutCommands"]),
        .executable(name: "layout-command", targets: ["LayoutCommandCLI"]),
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
                .product(name: "DEF", package: "swift-mask-data"),
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
        .target(
            name: "LayoutEngine",
            dependencies: ["LayoutCore", "LayoutTech", "LayoutAutoGen"]
        ),
        .target(
            name: "LayoutCommands",
            dependencies: ["LayoutCore", "LayoutIO", "LayoutTech", "LayoutVerify"]
        ),
        .executableTarget(
            name: "LayoutCommandCLI",
            dependencies: ["LayoutCommands"]
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
            name: "LayoutIntegrationTests",
            dependencies: [
                "LayoutIntegration",
                "LayoutCore",
                "LayoutIO",
                "LayoutTech",
            ]
        ),
        .testTarget(
            name: "LayoutAutoGenTests",
            dependencies: [
                "LayoutAutoGen",
                "LayoutEngine",
                "LayoutCore",
                "LayoutTech",
                "LayoutVerify",
                "LayoutEditor",
            ]
        ),
        .testTarget(
            name: "LayoutEngineTests",
            dependencies: [
                "LayoutEngine",
                "LayoutAutoGen",
                "LayoutCore",
                "LayoutTech",
            ]
        ),
        .testTarget(
            name: "LayoutCommandsTests",
            dependencies: [
                "LayoutCommands",
                "LayoutCore",
                "LayoutIO",
                "LayoutTech",
                "LayoutVerify",
            ],
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
