import Foundation
import LayoutCore
import LayoutTech

extension LayoutDRCService {
    func resolveCell(document: LayoutDocument, cellID: UUID?) -> LayoutCell? {
        if let id = cellID {
            return document.cell(withID: id)
        }
        if let topID = document.topCellID {
            return document.cell(withID: topID)
        }
        return document.cells.first
    }

    func flatten(
        cell: LayoutCell,
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        shapes: inout [LayoutShape],
        vias: inout [LayoutVia],
        pins: inout [LayoutPin],
        terminalConflicts: inout [TerminalConnectivityConflict],
        capturedHierarchy: LayoutHierarchySnapshot? = nil
    ) throws {
        let capture = try capturedHierarchy ?? LayoutConnectivityExtractor().captureHierarchy(document: document, cellID: cell.id)
        shapes = capture.shapes
        vias = capture.vias
        pins = capture.pins
        // Source-wide inferred annotation cannot represent independent bands
        // or occurrence-scoped nets. Electrical consumers use native facts.
        terminalConflicts = []
    }

    struct TerminalConnectivityConflict: Sendable {
        var netIDs: [UUID]
        var shapeIDs: [UUID]
        var viaIDs: [UUID]
        var pinIDs: [UUID]
        var region: LayoutRect

        func transformed(by transforms: [LayoutTransform]) -> TerminalConnectivityConflict {
            TerminalConnectivityConflict(
                netIDs: netIDs,
                shapeIDs: shapeIDs,
                viaIDs: viaIDs,
                pinIDs: pinIDs,
                region: applyTransforms(to: region, transforms: transforms)
            )
        }

        private func applyTransforms(to rect: LayoutRect, transforms: [LayoutTransform]) -> LayoutRect {
            let geometry = LayoutGeometry.rect(rect)
            var current = geometry
            for transform in transforms.reversed() {
                current = current.transformed(by: transform)
            }
            return LayoutGeometryAnalysis.boundingBox(for: current)
        }
    }

    func makeTerminalConflictViolation(_ conflict: TerminalConnectivityConflict) -> LayoutViolation {
        LayoutViolation(
            kind: .overlapShort,
            ruleID: "connectivity.short.terminalComponent",
            message: "Short between terminal nets in one connected component",
            region: conflict.region,
            shapeIDs: conflict.shapeIDs,
            viaIDs: conflict.viaIDs,
            pinIDs: conflict.pinIDs,
            netIDs: conflict.netIDs,
            suggestedFix: "Separate the connected geometry or map the instance terminals to the same net intentionally."
        )
    }

}
