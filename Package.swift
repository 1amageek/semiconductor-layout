// swift-tools-version: 6.3
import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    exact: "26.812.0"
)

let swiftMaskDataDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/swift-mask-data.git",
    revision: "3a02e30e7a7343d800319feff5c912816f34565a"
)

let signoffToolSupportDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/SignoffToolSupport.git",
    exact: "26.812.0"
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
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
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
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
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
            ],
            resources: [.process("Fixtures")]
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
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
            ],
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
