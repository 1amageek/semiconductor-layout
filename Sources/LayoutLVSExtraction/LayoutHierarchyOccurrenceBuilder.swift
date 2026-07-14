import Foundation
import LayoutCore

public struct LayoutHierarchyOccurrenceBuilder: LayoutHierarchyOccurrenceBuilding {
    public init() {}

    public func build(
        document: LayoutDocument,
        topCellID: UUID,
        maximumOccurrenceCount: Int = 1_000_000
    ) throws -> LayoutHierarchyInventory {
        guard maximumOccurrenceCount > 0 else {
            throw LayoutHierarchyOccurrenceBuilderError.invalidOccurrenceLimit(
                maximumOccurrenceCount
            )
        }
        var cellsByID: [UUID: LayoutCell] = [:]
        for cell in document.cells {
            guard cellsByID[cell.id] == nil else {
                throw LayoutHierarchyOccurrenceBuilderError.duplicateCellID(cell.id)
            }
            cellsByID[cell.id] = cell
        }
        guard let topCell = cellsByID[topCellID] else {
            throw LayoutHierarchyOccurrenceBuilderError.missingTopCell(topCellID)
        }

        var state = TraversalState(maximumOccurrenceCount: maximumOccurrenceCount)
        state.occurrences.append(LayoutExtractionOccurrence(
            objectID: LayoutExtractionObjectID(
                rawValue: "occurrence:/\(topCell.name)"
            ),
            cellName: topCell.name,
            hierarchyPath: [topCell.name],
            sourceObjectID: "cell:/\(topCell.name)",
            transformDescription: "identity"
        ))
        traverse(
            cell: topCell,
            hierarchyPath: [topCell.name],
            occurrencePath: [topCell.name],
            activeCellIDs: [topCell.id],
            transformPath: [],
            cellsByID: cellsByID,
            state: &state
        )
        return LayoutHierarchyInventory(
            topCell: topCell.name,
            occurrences: state.occurrences,
            issues: state.issues
        )
    }

    private struct TraversalState {
        let maximumOccurrenceCount: Int
        var occurrences: [LayoutExtractionOccurrence] = []
        var issues: [LayoutExtractionIssue] = []
        var limitReported = false
    }

    private func traverse(
        cell: LayoutCell,
        hierarchyPath: [String],
        occurrencePath: [String],
        activeCellIDs: Set<UUID>,
        transformPath: [String],
        cellsByID: [UUID: LayoutCell],
        state: inout TraversalState
    ) {
        let orderedInstances = cell.instances.enumerated().sorted {
            let lhsKey = instanceOrderKey($0.element, cellsByID: cellsByID)
            let rhsKey = instanceOrderKey($1.element, cellsByID: cellsByID)
            return lhsKey == rhsKey ? $0.offset < $1.offset : lhsKey < rhsKey
        }
        for (instanceIndex, indexedInstance) in orderedInstances.enumerated() {
            let instance = indexedInstance.element
            for (replicaIndex, transform) in instance.occurrenceTransforms().enumerated() {
                guard state.occurrences.count < state.maximumOccurrenceCount else {
                    if !state.limitReported {
                        state.issues.append(LayoutExtractionIssue(
                            code: "hierarchy-occurrence-limit-exceeded",
                            severity: .blocking,
                            message: "Layout hierarchy exceeded the configured occurrence limit."
                        ))
                        state.limitReported = true
                    }
                    return
                }
                let pathSegment = "\(instance.name)#\(instanceIndex)[\(replicaIndex)]"
                let nextOccurrencePath = occurrencePath + [pathSegment]
                let occurrenceID = LayoutExtractionObjectID(
                    rawValue: "occurrence:\(nextOccurrencePath.joined(separator: "/"))"
                )
                let nextTransformPath = transformPath + [transformDescription(transform)]
                guard let child = cellsByID[instance.cellID] else {
                    state.occurrences.append(LayoutExtractionOccurrence(
                        objectID: occurrenceID,
                        cellName: "<missing>",
                        hierarchyPath: hierarchyPath + [instance.name],
                        sourceObjectID: "instance:\(nextOccurrencePath.joined(separator: "/"))",
                        transformDescription: nextTransformPath.joined(separator: " -> ")
                    ))
                    state.issues.append(LayoutExtractionIssue(
                        code: "missing-child-cell",
                        severity: .blocking,
                        message: "Instance \(instance.name) references a missing child cell.",
                        affectedObjectIDs: [occurrenceID]
                    ))
                    continue
                }
                let nextHierarchyPath = hierarchyPath + [instance.name]
                state.occurrences.append(LayoutExtractionOccurrence(
                    objectID: occurrenceID,
                    cellName: child.name,
                    hierarchyPath: nextHierarchyPath,
                    sourceObjectID: "instance:\(nextOccurrencePath.joined(separator: "/"))",
                    transformDescription: nextTransformPath.joined(separator: " -> ")
                ))
                guard !activeCellIDs.contains(child.id) else {
                    state.issues.append(LayoutExtractionIssue(
                        code: "recursive-cell-hierarchy",
                        severity: .blocking,
                        message: "Layout hierarchy contains a recursive cell reference at \(instance.name).",
                        affectedObjectIDs: [occurrenceID]
                    ))
                    continue
                }
                var nextActiveCellIDs = activeCellIDs
                nextActiveCellIDs.insert(child.id)
                traverse(
                    cell: child,
                    hierarchyPath: nextHierarchyPath,
                    occurrencePath: nextOccurrencePath,
                    activeCellIDs: nextActiveCellIDs,
                    transformPath: nextTransformPath,
                    cellsByID: cellsByID,
                    state: &state
                )
            }
        }
    }

    private func instanceOrderKey(
        _ instance: LayoutInstance,
        cellsByID: [UUID: LayoutCell]
    ) -> String {
        [
            instance.name,
            cellsByID[instance.cellID]?.name ?? "<missing>",
            instance.occurrenceTransforms().map(transformDescription).joined(separator: ";"),
        ].joined(separator: "|")
    }

    private func transformDescription(_ transform: LayoutTransform) -> String {
        [
            "x=\(transform.translation.x)",
            "y=\(transform.translation.y)",
            "rotation=\(transform.rotationDegrees)",
            "magnification=\(transform.magnification)",
            "mirrorX=\(transform.mirrorX)",
            "mirrorY=\(transform.mirrorY)",
        ].joined(separator: ",")
    }
}
