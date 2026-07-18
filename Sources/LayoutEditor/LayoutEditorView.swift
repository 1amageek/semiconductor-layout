import SwiftUI
import UniformTypeIdentifiers
import CircuiteFoundation
import LayoutCore
import LayoutTech
import LayoutIO

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
                    VStack(alignment: .leading, spacing: 8) {
                        LayoutCellBreadcrumbBar(viewModel: viewModel)
                        HStack(alignment: .top, spacing: 8) {
                            LayoutToolPaletteOverlay(viewModel: viewModel)
                            LayoutLayerPaletteOverlay(viewModel: viewModel)
                        }
                    }
                    .padding(12)
                }
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        LayoutToolOptionsOverlay(viewModel: viewModel)
                        if let message = viewModel.lastError {
                            errorBanner(message)
                        }
                    }
                    .padding(.top, 12)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 8) {
                        LayoutZoomControlView(viewModel: viewModel)
                        LayoutCursorReadoutView(viewModel: viewModel)
                        LayoutScaleBarView(viewModel: viewModel)
                    }
                    .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    LayoutMiniMapView(viewModel: viewModel)
                        .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 8) {
                        LayoutTrustDashboard(viewModel: viewModel)
                        LayoutIntentPanel(viewModel: viewModel)
                    }
                    .padding(12)
                }
                .layoutPriority(1)

            if showsDiagnosticsBar {
                LayoutDiagnosticsBar(
                    violations: viewModel.violations,
                    staleKinds: viewModel.staleViolationKinds,
                    connectivity: viewModel.connectivityAnalysis,
                    constraintViolations: viewModel.constraintViolations,
                    lvsExtraction: viewModel.lvsExtraction,
                    lvsComparison: viewModel.lvsComparison,
                    verificationPending: viewModel.inPlaceVerificationPending,
                    onFocusViolation: { viewModel.focusViolation($0) },
                    onFixAll: { viewModel.fixAllViolations() }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("DRD Mode", selection: $viewModel.drdMode) {
                    ForEach(DRDMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Design-rule-driven editing: live verification (Observe) and legal-position drags (Enforce)")
            }
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
        .simultaneousGesture(backSwipeGesture)
    }

    /// The bar appears whenever there is a live verdict to show: DRC
    /// violations, stale checks, connectivity problems, or a pending
    /// in-place verification.
    private var showsDiagnosticsBar: Bool {
        if !viewModel.violations.isEmpty || !viewModel.staleViolationKinds.isEmpty {
            return true
        }
        if viewModel.inPlaceVerificationPending {
            return true
        }
        if let connectivity = viewModel.connectivityAnalysis {
            return !connectivity.shorts.isEmpty || !connectivity.opens.isEmpty
        }
        return false
    }

    /// Errors the engine raised (refused via placement, window miss,
    /// cycle rejection, ...) — visible, dismissible, never silent.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
            Button {
                viewModel.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let deltaX = value.translation.width
                let deltaY = abs(value.translation.height)
                guard deltaX > 140 else { return }
                guard deltaY < 100 else { return }
                guard value.startLocation.x < 80 || deltaX > 220 else { return }
                viewModel.navigateBack()
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

#Preview("NAND Flash GDS") {
    LayoutNANDFlashPreview()
        .frame(width: 1200, height: 700)
}

#Preview("Folded Cascode OTA") {
    do {
        let (document, tech) = try PreviewSampleData.buildFCOTALayout()
        let viewModel = LayoutEditorViewModel(document: document, tech: tech)
        viewModel.canvasSize = CGSize(width: 1200, height: 800)
        viewModel.fitAll()
        return AnyView(
            LayoutEditorView(viewModel: viewModel)
                .frame(width: 1200, height: 800)
        )
    } catch {
        return AnyView(
            ContentUnavailableView(
                "Preview unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(error.localizedDescription)
            )
            .frame(width: 1200, height: 800)
        )
    }
}
