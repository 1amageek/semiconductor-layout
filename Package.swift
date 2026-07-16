// swift-tools-version: 6.3
import PackageDescription
import Foundation

let workspaceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let circuiteFoundationDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("CircuiteFoundation/Package.swift").path
)
    ? .package(path: "../CircuiteFoundation")
    : .package(
        url: "https://github.com/1amageek/CircuiteFoundation.git",
        revision: "2ec6ee13a89ac6885be3c26b41a9ee0ef89948ac"
    )

let swiftMaskDataDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("swift-mask-data/Package.swift").path
)
    ? .package(path: "../swift-mask-data")
    : .package(
        url: "https://github.com/1amageek/swift-mask-data.git",
        revision: "69e345fb89b47884bc80fad1c293005a8156e78b"
    )

let signoffToolSupportDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("SignoffToolSupport/Package.swift").path
)
    ? .package(path: "../SignoffToolSupport")
    : .package(
        url: "https://github.com/1amageek/SignoffToolSupport.git",
        revision: "7bfd1864edd147c59a1dc79e58f297120d165323"
    )

let package = Package(
    name: "SemiconductorLayout",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LayoutCore", targets: ["LayoutCore"]),
        .library(name: "LayoutTech", targets: ["LayoutTech"]),
        .library(name: "LayoutLVSExtraction", targets: ["LayoutLVSExtraction"]),
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
        circuiteFoundationDependency,
        swiftMaskDataDependency,
        signoffToolSupportDependency,
    ],
    targets: [
        .target(
            name: "LayoutCore",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            ]
        ),
        .target(
            name: "LayoutTech",
            dependencies: ["LayoutCore"]
        ),
        .target(
            name: "LayoutLVSExtraction",
            dependencies: [
                "LayoutCore",
                "LayoutTech",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ]
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
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
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
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "LayoutIR", package: "swift-mask-data"),
                .product(name: "MaskGeometry", package: "swift-mask-data"),
            ],
            resources: [.copy("Resources")]
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
            dependencies: [
                "LayoutCore",
                "LayoutIO",
                "LayoutTech",
                "LayoutVerify",
                "LayoutAutoGen",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            ]
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
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "LayoutIR", package: "swift-mask-data"),
                .product(name: "TechIR", package: "swift-mask-data"),
                .product(name: "LEF", package: "swift-mask-data"),
            ]
        ),
        .testTarget(
            name: "LayoutLVSExtractionTests",
            dependencies: [
                "LayoutLVSExtraction",
                "LayoutCore",
                "LayoutTech",
            ]
        ),
        .testTarget(
            name: "LayoutCoreTests",
            dependencies: [
                "LayoutCore",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
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
            name: "LayoutEditorTests",
            dependencies: ["LayoutEditor"]
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
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            ],
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
