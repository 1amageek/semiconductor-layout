import SwiftUI
import Foundation
import LayoutCore
import LayoutTech
import LayoutIO

extension LayoutEditorViewModel {
    // MARK: - File Import

    public func loadMaskData(from url: URL) throws {
        let resolvedTech: LayoutTechDatabase
        let sidecarResolver = LayoutTechSidecarResolver()
        if let sidecarTech = try sidecarResolver.resolve(for: url) {
            resolvedTech = sidecarTech
        } else {
            resolvedTech = tech
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw error
        }
        let converter = MaskDataFormatConverter(tech: resolvedTech)
        let document = try converter.importFromData(data)

        loadDocument(document, tech: resolvedTech)
    }

    /// Replaces the edited document (and optionally the technology) and
    /// re-syncs all document-derived state: active cell, navigation,
    /// selection, render index, and live verification sessions.
    ///
    /// Assigning ``editor`` directly leaves that state pointing at the old
    /// document (a stale ``activeCellID`` makes the canvas draw nothing) —
    /// always go through this method to swap documents.
    public func loadDocument(_ document: LayoutDocument, tech newTech: LayoutTechDatabase? = nil) {
        if let newTech {
            self.tech = newTech
            self.gridSize = newTech.grid
            self.activeLayer = newTech.layers.first?.id ?? LayoutLayerID(name: "M1", purpose: "drawing")
            self.activeViaID = newTech.vias.first?.id ?? "VIA1"
            self.pathWidth = defaultPathWidth(for: newTech)
        }
        self.editor = LayoutDocumentEditor(document: document)
        self.activeCellID = document.topCellID ?? document.cells.first?.id
        self.cellNavigationPath = Self.initialNavigationPath(document: document, activeCellID: self.activeCellID)
        self.cellBackStack.removeAll()
        self.selectedShapeIDs.removeAll()
        self.selectedInstanceID = nil
        self.hiddenLayers.removeAll()
        self.violations.removeAll()
        // The technology may have changed with the document; a live
        // session cannot absorb that, so start fresh ones.
        restartLiveDRC()
        restartLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
        clearNetHighlight()
    }

    public func centerOn(_ point: LayoutPoint) {
        offset = CGPoint(
            x: canvasSize.width / 2 - CGFloat(point.x) * zoom,
            y: canvasSize.height / 2 - CGFloat(point.y) * zoom
        )
    }

    public func clearSelection() {
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
    }

    /// Selects every shape on a visible layer in the active cell.
    public func selectAllShapes() {
        selectedShapeIDs = Set(
            documentShapes()
                .filter { !hiddenLayers.contains($0.layer) }
                .map(\.id)
        )
    }
    func defaultPathWidth(for tech: LayoutTechDatabase) -> Double {
        // Use the minimum width of the first layer, or fall back to grid
        if let firstLayer = tech.layers.first,
           let ruleSet = tech.ruleSet(for: firstLayer.id),
           ruleSet.minWidth > 0 {
            return ruleSet.minWidth
        }
        return tech.grid * 10
    }

}
