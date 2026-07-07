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
        transforms: [LayoutTransform],
        terminalNetIDs: [String: UUID],
        shapes: inout [LayoutShape],
        vias: inout [LayoutVia],
        pins: inout [LayoutPin],
        terminalConflicts: inout [TerminalConnectivityConflict]
    ) {
        let terminalConnectivity = terminalConnectivity(cell: cell, terminalNetIDs: terminalNetIDs, tech: tech)
        terminalConflicts.append(contentsOf: terminalConnectivity.conflicts.map {
            $0.transformed(by: transforms)
        })

        for shape in cell.shapes {
            var transformed = shape
            if transformed.netID == nil {
                transformed.netID = terminalConnectivity.shapeNetIDs[shape.id]
            }
            transformed.geometry = applyTransforms(to: shape.geometry, transforms: transforms)
            shapes.append(transformed)
        }

        for via in cell.vias {
            var transformed = via
            if transformed.netID == nil {
                transformed.netID = terminalConnectivity.viaNetIDs[via.id]
            }
            transformed.position = applyTransforms(to: via.position, transforms: transforms)
            vias.append(transformed)
        }

        for pin in cell.pins {
            var transformed = pin
            if transformed.netID == nil {
                transformed.netID = terminalNetIDs[pin.name]
            }
            transformed.position = applyTransforms(to: pin.position, transforms: transforms)
            pins.append(transformed)
        }

        for instance in cell.instances {
            guard let child = document.cell(withID: instance.cellID) else { continue }
            for occurrenceTransform in instance.occurrenceTransforms() {
                flatten(
                    cell: child,
                    document: document,
                    tech: tech,
                    transforms: transforms + [occurrenceTransform],
                    terminalNetIDs: instance.terminalNetIDs,
                    shapes: &shapes,
                    vias: &vias,
                    pins: &pins,
                    terminalConflicts: &terminalConflicts
                )
            }
        }
    }

    private struct TerminalConnectivity: Sendable {
        var shapeNetIDs: [UUID: UUID]
        var viaNetIDs: [UUID: UUID]
        var conflicts: [TerminalConnectivityConflict]
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

    private func terminalConnectivity(
        cell: LayoutCell,
        terminalNetIDs: [String: UUID],
        tech: LayoutTechDatabase
    ) -> TerminalConnectivity {
        guard !terminalNetIDs.isEmpty else {
            return TerminalConnectivity(shapeNetIDs: [:], viaNetIDs: [:], conflicts: [])
        }

        var geometries: [LayoutGeometry] = []
        var layers: [LayoutLayerID?] = []
        var isVia: [Bool] = []
        var viaDefs: [LayoutViaDefinition?] = []
        var viaCutRects: [[LayoutRect]] = []
        var viaContactRectsByLayer: [[LayoutLayerID: [LayoutRect]]] = []
        var shapeIDsByNode: [Int: UUID] = [:]
        var viaIDsByNode: [Int: UUID] = [:]

        for shape in cell.shapes {
            let index = geometries.count
            geometries.append(shape.geometry)
            layers.append(shape.layer)
            isVia.append(false)
            viaDefs.append(nil)
            viaCutRects.append([])
            viaContactRectsByLayer.append([:])
            shapeIDsByNode[index] = shape.id
        }

        for via in cell.vias {
            let index = geometries.count
            let cuts = self.viaCutRects(for: via, tech: tech)
            let conductors = viaConductorRects(for: via, tech: tech)
            let bounds = self.union(rects: conductors) ?? viaCutBoundingBox(for: via, tech: tech)
            geometries.append(.rect(bounds))
            layers.append(nil)
            isVia.append(true)
            viaDefs.append(tech.viaDefinition(for: via.viaDefinitionID))
            viaCutRects.append(cuts)
            viaContactRectsByLayer.append(self.viaContactRectsByLayer(for: via, tech: tech))
            viaIDsByNode[index] = via.id
        }

        guard !geometries.isEmpty else {
            return TerminalConnectivity(shapeNetIDs: [:], viaNetIDs: [:], conflicts: [])
        }

        // Connectivity and pin contact both require geometric intersection,
        // so one spatial index serves the pair scan and the pin probes; the
        // union-find result is independent of pair visiting order.
        let boxes = geometries.map { LayoutGeometryAnalysis.boundingBox(for: $0) }
        let grid = ShapeGridIndex(
            boundingBoxes: boxes,
            cellSize: ShapeGridIndex.defaultCellSize(for: boxes)
        )
        var unionFind = LayoutUnionFind(count: geometries.count)
        if geometries.count > 1 {
            for i in 0..<(geometries.count - 1) {
                for j in grid.candidateIndices(near: boxes[i]) where j > i {
                    guard unionFind.find(i) != unionFind.find(j) else { continue }
                    if shouldConnect(
                        indexA: i,
                        indexB: j,
                        geometries: geometries,
                        layers: layers,
                        isVia: isVia,
                        viaDefs: viaDefs,
                        viaCutRects: viaCutRects,
                        viaContactRectsByLayer: viaContactRectsByLayer
                    ) {
                        unionFind.union(i, j)
                    }
                }
            }
        }

        var netIDsByRoot: [Int: Set<UUID>] = [:]
        var pinIDsByRoot: [Int: Set<UUID>] = [:]

        for pin in cell.pins {
            guard let netID = terminalNetIDs[pin.name] else { continue }
            let pinRect = LayoutRect(
                origin: LayoutPoint(
                    x: pin.position.x - pin.size.width / 2,
                    y: pin.position.y - pin.size.height / 2
                ),
                size: pin.size
            )

            for index in grid.candidateIndices(near: pinRect) {
                guard terminalContactIntersects(
                    pinRect: pinRect,
                    pin: pin,
                    geometry: geometries[index],
                    layer: layers[index],
                    isVia: isVia[index],
                    viaDefinition: viaDefs[index],
                    viaCutRects: viaCutRects[index],
                    viaContactRectsByLayer: viaContactRectsByLayer[index]
                ) else {
                    continue
                }
                let root = unionFind.find(index)
                netIDsByRoot[root, default: []].insert(netID)
                pinIDsByRoot[root, default: []].insert(pin.id)
            }
        }

        let componentNodes = unionFind.components()
        var shapeNetIDs: [UUID: UUID] = [:]
        var viaNetIDs: [UUID: UUID] = [:]
        var conflicts: [TerminalConnectivityConflict] = []

        for (root, netIDs) in netIDsByRoot {
            let nodes = componentNodes[root] ?? []
            if netIDs.count == 1, let netID = netIDs.first {
                for node in nodes {
                    if let shapeID = shapeIDsByNode[node] {
                        shapeNetIDs[shapeID] = netID
                    }
                    if let viaID = viaIDsByNode[node] {
                        viaNetIDs[viaID] = netID
                    }
                }
            } else {
                conflicts.append(TerminalConnectivityConflict(
                    netIDs: netIDs.sorted { $0.uuidString < $1.uuidString },
                    shapeIDs: nodes.compactMap { shapeIDsByNode[$0] },
                    viaIDs: nodes.compactMap { viaIDsByNode[$0] },
                    pinIDs: Array(pinIDsByRoot[root, default: []]).sorted { $0.uuidString < $1.uuidString },
                    region: overallBoundingBox(geometries: nodes.map { geometries[$0] }) ?? .zero
                ))
            }
        }

        return TerminalConnectivity(shapeNetIDs: shapeNetIDs, viaNetIDs: viaNetIDs, conflicts: conflicts)
    }

    private func terminalContactIntersects(
        pinRect: LayoutRect,
        pin: LayoutPin,
        geometry: LayoutGeometry,
        layer: LayoutLayerID?,
        isVia: Bool,
        viaDefinition: LayoutViaDefinition?,
        viaCutRects: [LayoutRect],
        viaContactRectsByLayer: [LayoutLayerID: [LayoutRect]]
    ) -> Bool {
        if isVia {
            guard let viaDefinition else { return false }
            guard pin.layer == viaDefinition.topLayer || pin.layer == viaDefinition.bottomLayer else {
                return false
            }
            if let contactRects = viaContactRectsByLayer[pin.layer], !contactRects.isEmpty {
                return contactRects.contains {
                    $0.intersects(pinRect)
                        || $0.contains(pin.position)
                        || LayoutGeometryAnalysis.intersects(.rect($0), .rect(pinRect))
                }
            }
            if !viaCutRects.isEmpty {
                return viaCutRects.contains {
                    $0.intersects(pinRect)
                        || $0.contains(pin.position)
                        || LayoutGeometryAnalysis.intersects(.rect($0), .rect(pinRect))
                }
            }
        } else {
            guard layer == pin.layer else { return false }
        }

        let geometryBox = LayoutGeometryAnalysis.boundingBox(for: geometry)
        return geometryBox.intersects(pinRect)
            || LayoutGeometryAnalysis.contains(pin.position, in: geometry)
            || LayoutGeometryAnalysis.intersects(geometry, .rect(pinRect))
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

    private func applyTransforms(to point: LayoutPoint, transforms: [LayoutTransform]) -> LayoutPoint {
        var current = point
        for transform in transforms.reversed() {
            current = transform.apply(to: current)
        }
        return current
    }

    private func applyTransforms(to geometry: LayoutGeometry, transforms: [LayoutTransform]) -> LayoutGeometry {
        var current = geometry
        for transform in transforms.reversed() {
            current = current.transformed(by: transform)
        }
        return current
    }

}
