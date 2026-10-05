// swift-tools-version: 6.3
import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    exact: "26.812.0"
)

let swiftMaskDataDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/swift-mask-data.git",
    revision: "41f72fe3ca7a35b1cda53f59e780b029faf1b718"
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
            ],
            exclude: ["DESIGN.md", "ViaGeometry/DESIGN.md"]
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
            ],
            exclude: ["DESIGN.md", "HierarchyCapture/DESIGN.md", "ConductorCapture/DESIGN.md"]
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
            ],
            exclude: ["DESIGN.md", "DEFMasterComposition/DESIGN.md"]
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
            exclude: ["DESIGN.md", "SDLIntent/DESIGN.md"],
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
                .product(name: "LEF", package: "swift-mask-data"),
                "LayoutCore",
                "LayoutIO",
                "LayoutTech",
                "LayoutVerify",
                "LayoutAutoGen",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
            ],
            exclude: ["DESIGN.md"]
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
                "LayoutVerify",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "GDSII", package: "swift-mask-data"),
                .product(name: "LayoutIR", package: "swift-mask-data"),
                .product(name: "TechIR", package: "swift-mask-data"),
                .product(name: "LEF", package: "swift-mask-data"),
            ],
            exclude: ["Fixtures"]
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
                .product(name: "LEF", package: "swift-mask-data"),
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
