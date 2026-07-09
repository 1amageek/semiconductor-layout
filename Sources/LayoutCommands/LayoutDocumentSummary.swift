import Foundation
import LayoutCore

public struct LayoutDocumentSummary: Codable, Sendable, Equatable {
    public let documentID: UUID
    public let name: String
    public let topCellID: UUID?
    public let unitDBUPerMicron: Double
    public let cellCount: Int
    public let shapeCount: Int
    public let viaCount: Int
    public let labelCount: Int
    public let pinCount: Int
    public let instanceCount: Int
    public let netCount: Int
    public let constraintCount: Int
    public let boundingBox: LayoutRect?
    public let cells: [LayoutDocumentCellSummary]
    public let layerUsage: [LayoutDocumentLayerUsage]

    public init(document: LayoutDocument) {
        self.documentID = document.id
        self.name = document.name
        self.topCellID = document.topCellID
        self.unitDBUPerMicron = document.units.dbuPerMicron
        self.cellCount = document.cells.count
        self.shapeCount = document.cells.reduce(0) { $0 + $1.shapes.count }
        self.viaCount = document.cells.reduce(0) { $0 + $1.vias.count }
        self.labelCount = document.cells.reduce(0) { $0 + $1.labels.count }
        self.pinCount = document.cells.reduce(0) { $0 + $1.pins.count }
        self.instanceCount = document.cells.reduce(0) { $0 + $1.instances.count }
        self.netCount = document.cells.reduce(0) { $0 + $1.nets.count }
        self.constraintCount = document.cells.reduce(0) { $0 + $1.constraints.count }
        self.boundingBox = Self.documentBoundingBox(document)
        self.cells = document.cells
            .map { LayoutDocumentCellSummary(cell: $0, topCellID: document.topCellID) }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.cellID.uuidString < rhs.cellID.uuidString }
                return lhs.name < rhs.name
            }
        self.layerUsage = Self.layerUsage(document)
    }

    private static func documentBoundingBox(_ document: LayoutDocument) -> LayoutRect? {
        var boundingBox: LayoutRect?
        for cell in document.cells {
            for shape in cell.shapes {
                let shapeBox = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
                if let current = boundingBox {
                    boundingBox = current.union(shapeBox)
                } else {
                    boundingBox = shapeBox
                }
            }
        }
        return boundingBox
    }

    private static func layerUsage(_ document: LayoutDocument) -> [LayoutDocumentLayerUsage] {
        var counts: [LayoutLayerID: Int] = [:]
        for cell in document.cells {
            for shape in cell.shapes {
                counts[shape.layer, default: 0] += 1
            }
            for via in cell.vias {
                counts[LayoutLayerID(name: via.viaDefinitionID, purpose: "cut"), default: 0] += 1
            }
            for label in cell.labels {
                counts[label.layer, default: 0] += 1
            }
            for pin in cell.pins {
                counts[pin.layer, default: 0] += 1
            }
        }
        return counts.map { LayoutDocumentLayerUsage(layer: $0.key, elementCount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.layer.name == rhs.layer.name {
                    return lhs.layer.purpose < rhs.layer.purpose
                }
                return lhs.layer.name < rhs.layer.name
            }
    }
}

public struct LayoutDocumentCellSummary: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let name: String
    public let isTop: Bool
    public let shapeCount: Int
    public let viaCount: Int
    public let labelCount: Int
    public let pinCount: Int
    public let instanceCount: Int
    public let netCount: Int
    public let constraintCount: Int
    public let boundingBox: LayoutRect?

    public init(cell: LayoutCell, topCellID: UUID?) {
        self.cellID = cell.id
        self.name = cell.name
        self.isTop = cell.id == topCellID
        self.shapeCount = cell.shapes.count
        self.viaCount = cell.vias.count
        self.labelCount = cell.labels.count
        self.pinCount = cell.pins.count
        self.instanceCount = cell.instances.count
        self.netCount = cell.nets.count
        self.constraintCount = cell.constraints.count
        var boundingBox: LayoutRect?
        for shape in cell.shapes {
            let shapeBox = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            if let current = boundingBox {
                boundingBox = current.union(shapeBox)
            } else {
                boundingBox = shapeBox
            }
        }
        self.boundingBox = boundingBox
    }
}

public struct LayoutDocumentLayerUsage: Codable, Sendable, Equatable {
    public let layer: LayoutLayerID
    public let elementCount: Int

    public init(layer: LayoutLayerID, elementCount: Int) {
        self.layer = layer
        self.elementCount = elementCount
    }
}
