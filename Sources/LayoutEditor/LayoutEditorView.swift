import SwiftUI
import UniformTypeIdentifiers
import LayoutCore
import LayoutTech
import LayoutIO
import LayoutIR

public struct LayoutEditorView: View {
    @Bindable var viewModel: LayoutEditorViewModel
    @State private var showFileImporter = false
    @State private var fileImportError: String?

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            LayoutCanvasView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 8) {
                        LayoutToolPaletteOverlay(viewModel: viewModel)
                        LayoutLayerPaletteOverlay(viewModel: viewModel)
                    }
                    .padding(12)
                }
                .overlay(alignment: .top) {
                    LayoutToolOptionsOverlay(viewModel: viewModel)
                        .padding(.top, 12)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 8) {
                        LayoutZoomControlView(viewModel: viewModel)
                        LayoutScaleBarView(viewModel: viewModel)
                    }
                    .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    LayoutMiniMapView(viewModel: viewModel)
                        .padding(12)
                }
                .layoutPriority(1)

            if !viewModel.violations.isEmpty {
                LayoutDiagnosticsBar(violations: viewModel.violations)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Open", systemImage: "doc.badge.plus")
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.maskDataContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                do {
                    try viewModel.loadMaskData(from: url)
                    viewModel.fitAll()
                } catch {
                    fileImportError = error.localizedDescription
                }
            case .failure(let error):
                fileImportError = error.localizedDescription
            }
        }
        .alert("Import Error", isPresented: Binding(
            get: { fileImportError != nil },
            set: { if !$0 { fileImportError = nil } }
        )) {
            Button("OK") { fileImportError = nil }
        } message: {
            Text(fileImportError ?? "")
        }
    }

    private static let maskDataContentTypes: [UTType] = {
        var types: [UTType] = [.data]
        if let gds = UTType(filenameExtension: "gds") { types.append(gds) }
        if let gds2 = UTType(filenameExtension: "gds2") { types.append(gds2) }
        if let oas = UTType(filenameExtension: "oas") { types.append(oas) }
        if let cif = UTType(filenameExtension: "cif") { types.append(cif) }
        if let dxf = UTType(filenameExtension: "dxf") { types.append(dxf) }
        return types
    }()
}

#Preview("Layout Editor") {
    LayoutEditorView(viewModel: LayoutEditorViewModel())
        .frame(width: 1200, height: 700)
}

#Preview("NAND Flash GDS (Artifacts)") {
    LayoutEditorView(viewModel: LayoutEditorView.makeNAND2ViewModel())
        .frame(width: 1200, height: 700)
}

extension LayoutEditorView {
    @MainActor
    static func makeNAND2ViewModel() -> LayoutEditorViewModel {
        let tech = LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: LayoutLayerID(name: "DIFF", purpose: "drawing"),
                    displayName: "Diffusion",
                    gdsLayer: 1, gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.8, blue: 0.3),
                    fillPattern: .solid
                ),
                LayoutLayerDefinition(
                    id: LayoutLayerID(name: "POLY", purpose: "drawing"),
                    displayName: "Poly",
                    gdsLayer: 2, gdsDatatype: 0,
                    color: LayoutColor(red: 0.9, green: 0.2, blue: 0.2),
                    fillPattern: .forwardDiagonal
                ),
                LayoutLayerDefinition(
                    id: LayoutLayerID(name: "M1", purpose: "drawing"),
                    displayName: "Metal1",
                    gdsLayer: 3, gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9),
                    fillPattern: .backwardDiagonal
                ),
                LayoutLayerDefinition(
                    id: LayoutLayerID(name: "CONT", purpose: "drawing"),
                    displayName: "Contact",
                    gdsLayer: 4, gdsDatatype: 0,
                    color: LayoutColor(red: 0.6, green: 0.6, blue: 0.6),
                    fillPattern: .crosshatch
                ),
                LayoutLayerDefinition(
                    id: LayoutLayerID(name: "NPLUS", purpose: "drawing"),
                    displayName: "N+ Implant",
                    gdsLayer: 5, gdsDatatype: 0,
                    color: LayoutColor(red: 0.2, green: 0.4, blue: 0.95, alpha: 0.35),
                    fillPattern: .dots
                ),
                LayoutLayerDefinition(
                    id: LayoutLayerID(name: "M2", purpose: "drawing"),
                    displayName: "Metal2",
                    gdsLayer: 6, gdsDatatype: 0,
                    color: LayoutColor(red: 0.95, green: 0.62, blue: 0.22),
                    fillPattern: .backwardDiagonal
                ),
                LayoutLayerDefinition(
                    id: LayoutLayerID(name: "VIA1", purpose: "cut"),
                    displayName: "Via1",
                    gdsLayer: 7, gdsDatatype: 0,
                    color: LayoutColor(red: 0.95, green: 0.95, blue: 0.35),
                    fillPattern: .crosshatch
                ),
            ],
            vias: [],
            layerRules: []
        )

        if let artifactURL = findNANDArtifactURL() {
            do {
                let sidecarResolver = LayoutTechSidecarResolver()
                let resolvedTech = try sidecarResolver.resolve(for: artifactURL) ?? tech
                let data = try Data(contentsOf: artifactURL)
                let converter = MaskDataFormatConverter(tech: resolvedTech)
                let document = try converter.importFromData(data)
                let viewModel = LayoutEditorViewModel(document: document, tech: resolvedTech)
                viewModel.canvasSize = CGSize(width: 1200, height: 700)
                viewModel.fitAll()
                return viewModel
            } catch {
                // Fallback to inline sample below if artifact import fails.
            }
        }

        let bridge = IRLayoutBridge()
        let irLib = buildNAND2IRLibrary()
        let document = bridge.importLibrary(irLib, tech: tech)
        let viewModel = LayoutEditorViewModel(document: document, tech: tech)
        viewModel.canvasSize = CGSize(width: 1200, height: 700)
        viewModel.fitAll()
        return viewModel
    }

    private static func findNANDArtifactURL() -> URL? {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let fileManager = FileManager.default
        let candidates = [
            projectRoot.appendingPathComponent("Artifacts/nand_flash_small.gds"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Artifacts/nand_flash_small.gds"),
            URL(fileURLWithPath: "/Users/1amageek/Desktop/semiconductor-layout/Artifacts/nand_flash_small.gds"),
        ]

        for url in candidates {
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func buildNAND2IRLibrary() -> IRLibrary {
        let diffLayer: Int16 = 1
        let polyLayer: Int16 = 2
        let metal1Layer: Int16 = 3
        let contactLayer: Int16 = 4

        var elements: [IRElement] = []

        // N-diffusion region
        elements.append(.boundary(IRBoundary(
            layer: diffLayer, datatype: 0,
            points: [
                IRPoint(x: 400, y: 0), IRPoint(x: 1600, y: 0),
                IRPoint(x: 1600, y: 3000), IRPoint(x: 400, y: 3000),
                IRPoint(x: 400, y: 0),
            ],
            properties: []
        )))
        // Poly gate A
        elements.append(.boundary(IRBoundary(
            layer: polyLayer, datatype: 0,
            points: [
                IRPoint(x: 0, y: 600), IRPoint(x: 2000, y: 600),
                IRPoint(x: 2000, y: 900), IRPoint(x: 0, y: 900),
                IRPoint(x: 0, y: 600),
            ],
            properties: []
        )))
        // Poly gate B
        elements.append(.boundary(IRBoundary(
            layer: polyLayer, datatype: 0,
            points: [
                IRPoint(x: 0, y: 1600), IRPoint(x: 2000, y: 1600),
                IRPoint(x: 2000, y: 1900), IRPoint(x: 0, y: 1900),
                IRPoint(x: 0, y: 1600),
            ],
            properties: []
        )))
        // Contacts
        let contactRects: [(Int32, Int32, Int32, Int32)] = [
            (850, 100, 1150, 400),
            (850, 1100, 1150, 1400),
            (850, 2200, 1150, 2500),
        ]
        for r in contactRects {
            elements.append(.boundary(IRBoundary(
                layer: contactLayer, datatype: 0,
                points: [
                    IRPoint(x: r.0, y: r.1), IRPoint(x: r.2, y: r.1),
                    IRPoint(x: r.2, y: r.3), IRPoint(x: r.0, y: r.3),
                    IRPoint(x: r.0, y: r.1),
                ],
                properties: []
            )))
        }
        // Metal1 GND rail
        elements.append(.path(IRPath(
            layer: metal1Layer, datatype: 0,
            pathType: .halfWidthExtend, width: 200,
            points: [IRPoint(x: 0, y: 200), IRPoint(x: 2000, y: 200)],
            properties: []
        )))
        // Metal1 VDD rail
        elements.append(.path(IRPath(
            layer: metal1Layer, datatype: 0,
            pathType: .halfWidthExtend, width: 200,
            points: [IRPoint(x: 0, y: 2800), IRPoint(x: 2000, y: 2800)],
            properties: []
        )))
        // Labels
        elements.append(.text(IRText(layer: polyLayer, texttype: 0, transform: .identity,
                                     position: IRPoint(x: -200, y: 750), string: "A", properties: [])))
        elements.append(.text(IRText(layer: polyLayer, texttype: 0, transform: .identity,
                                     position: IRPoint(x: -200, y: 1750), string: "B", properties: [])))
        elements.append(.text(IRText(layer: metal1Layer, texttype: 0, transform: .identity,
                                     position: IRPoint(x: 1000, y: 200), string: "GND", properties: [])))
        elements.append(.text(IRText(layer: metal1Layer, texttype: 0, transform: .identity,
                                     position: IRPoint(x: 1000, y: 2800), string: "VDD", properties: [])))

        return IRLibrary(
            name: "NANDLIB",
            units: IRUnits(dbuPerMicron: 1000),
            cells: [IRCell(name: "NAND2", elements: elements)]
        )
    }
}
