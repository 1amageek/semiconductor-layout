import Foundation
import LayoutCore

extension LayoutCommandRunner {
    func ensureNoCollision(ids: [UUID], existing: Set<UUID>, kind: String) throws {
        var seen: Set<UUID> = []
        for id in ids {
            if existing.contains(id) || seen.contains(id) {
                throw LayoutCommandError.deterministicIDCollision(kind: kind, id: id)
            }
            seen.insert(id)
        }
    }

    func ensureCellMissing(_ cellID: UUID, in document: LayoutDocument) throws {
        if document.cell(withID: cellID) != nil {
            throw LayoutCommandError.duplicateCellID(cellID)
        }
    }

    func ensureNetMissing(_ netID: UUID, cellID: UUID, in document: LayoutDocument) throws {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        if cell.nets.contains(where: { $0.id == netID }) {
            throw LayoutCommandError.duplicateNetID(netID)
        }
    }

    func ensureNetExists(_ netID: UUID, cellID: UUID, in document: LayoutDocument) throws {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        if !cell.nets.contains(where: { $0.id == netID }) {
            throw LayoutCommandError.netNotFound(netID)
        }
    }

    func ensureNetExistsIfPresent(_ netID: UUID?, cellID: UUID, in document: LayoutDocument) throws {
        guard let netID else { return }
        try ensureNetExists(netID, cellID: cellID, in: document)
    }

    func ensureTerminalNetIDsExist(
        _ terminalNetIDs: [String: UUID],
        cellID: UUID,
        in document: LayoutDocument
    ) throws {
        for netID in terminalNetIDs.values {
            try ensureNetExists(netID, cellID: cellID, in: document)
        }
    }

    func ensureShapeMissing(_ shapeID: UUID, cellID: UUID, in document: LayoutDocument) throws {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        if cell.shapes.contains(where: { $0.id == shapeID }) {
            throw LayoutCommandError.duplicateShapeID(shapeID)
        }
    }

    func ensureLabelMissing(_ labelID: UUID, cellID: UUID, in document: LayoutDocument) throws {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        if cell.labels.contains(where: { $0.id == labelID }) {
            throw LayoutCommandError.duplicateLabelID(labelID)
        }
    }

    func ensureViaMissing(_ viaID: UUID, cellID: UUID, in document: LayoutDocument) throws {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        if cell.vias.contains(where: { $0.id == viaID }) {
            throw LayoutCommandError.duplicateViaID(viaID)
        }
    }

    func ensureInstanceMissing(_ instanceID: UUID, cellID: UUID, in document: LayoutDocument) throws {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        if cell.instances.contains(where: { $0.id == instanceID }) {
            throw LayoutCommandError.duplicateInstanceID(instanceID)
        }
    }

    func validateGeometry(_ geometry: LayoutGeometry) throws {
        switch geometry {
        case .rect(let rect):
            guard rect.size.width > 0, rect.size.height > 0 else {
                throw LayoutCommandError.invalidRectSize(width: rect.size.width, height: rect.size.height)
            }
        case .polygon(let polygon):
            guard polygon.isValid, abs(polygonArea(polygon.points)) > 0 else {
                throw LayoutCommandError.invalidShapeGeometry(kind: "polygon")
            }
        case .path(let path):
            guard path.isValid, pathHasLength(path.points) else {
                throw LayoutCommandError.invalidShapeGeometry(kind: "path")
            }
        }
    }

    func ensureUniqueSelectionIDs(_ ids: [UUID]) throws {
        var seen: Set<UUID> = []
        for id in ids {
            if seen.contains(id) {
                throw LayoutCommandError.duplicateSelectionID(id)
            }
            seen.insert(id)
        }
    }

    func ensureInstantiableHierarchy(
        parentCellID: UUID,
        referencedCellID: UUID,
        in document: LayoutDocument
    ) throws {
        guard document.cell(withID: parentCellID) != nil else {
            throw LayoutCommandError.cellNotFound(parentCellID)
        }
        guard document.cell(withID: referencedCellID) != nil else {
            throw LayoutCommandError.cellNotFound(referencedCellID)
        }
        guard parentCellID != referencedCellID else {
            throw LayoutCommandError.invalidInstanceHierarchy(
                parentCellID: parentCellID,
                referencedCellID: referencedCellID
            )
        }
        if cellHierarchyContains(parentCellID, startingAt: referencedCellID, in: document, visited: []) {
            throw LayoutCommandError.invalidInstanceHierarchy(
                parentCellID: parentCellID,
                referencedCellID: referencedCellID
            )
        }
    }

    func cellHierarchyContains(
        _ targetCellID: UUID,
        startingAt currentCellID: UUID,
        in document: LayoutDocument,
        visited: Set<UUID>
    ) -> Bool {
        guard !visited.contains(currentCellID) else { return false }
        guard let cell = document.cell(withID: currentCellID) else { return false }
        var nextVisited = visited
        nextVisited.insert(currentCellID)
        for instance in cell.instances {
            if instance.cellID == targetCellID {
                return true
            }
            if cellHierarchyContains(targetCellID, startingAt: instance.cellID, in: document, visited: nextVisited) {
                return true
            }
        }
        return false
    }

    func findInstance(_ instanceID: UUID, cellID: UUID, in document: LayoutDocument) throws -> LayoutInstance {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        guard let instance = cell.instances.first(where: { $0.id == instanceID }) else {
            throw LayoutCommandError.instanceNotFound(instanceID)
        }
        return instance
    }

    private func polygonArea(_ points: [LayoutPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[index == points.index(before: points.endIndex) ? points.startIndex : points.index(after: index)]
            area += current.x * next.y - next.x * current.y
        }
        return area / 2
    }

    private func pathHasLength(_ points: [LayoutPoint]) -> Bool {
        guard points.count >= 2 else { return false }
        for index in 0..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            if current.x != next.x || current.y != next.y {
                return true
            }
        }
        return false
    }
}
