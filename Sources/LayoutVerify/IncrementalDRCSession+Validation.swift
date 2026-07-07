import Foundation
import LayoutCore
import LayoutTech

extension IncrementalDRCSession {
    func validate(
        _ delta: LayoutEditDelta,
        shapeIndexByID: [UUID: Int],
        viaIndexByID: [UUID: Int]
    ) throws {
        try validateShapeDelta(delta, shapeIndexByID: shapeIndexByID)
        try validateViaDelta(delta, viaIndexByID: viaIndexByID)
    }

    private func validateShapeDelta(
        _ delta: LayoutEditDelta,
        shapeIndexByID: [UUID: Int]
    ) throws {
        var seenShapeIDs: Set<UUID> = []
        for shape in delta.addedShapes {
            guard seenShapeIDs.insert(shape.id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(shape.id)
            }
            guard shapeIndexByID[shape.id] == nil else {
                throw IncrementalDRCSessionError.duplicateShapeID(shape.id)
            }
            guard !childShapeIDs.contains(shape.id) else {
                throw IncrementalDRCSessionError.hierarchyIdentifierCollision(shape.id)
            }
        }
        for shape in delta.updatedShapes {
            guard seenShapeIDs.insert(shape.id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(shape.id)
            }
            guard shapeIndexByID[shape.id] != nil else {
                throw IncrementalDRCSessionError.unknownShapeID(shape.id)
            }
        }
        for id in delta.removedShapeIDs {
            guard seenShapeIDs.insert(id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(id)
            }
            guard shapeIndexByID[id] != nil else {
                throw IncrementalDRCSessionError.unknownShapeID(id)
            }
        }
    }

    private func validateViaDelta(
        _ delta: LayoutEditDelta,
        viaIndexByID: [UUID: Int]
    ) throws {
        var seenViaIDs: Set<UUID> = []
        for via in delta.addedVias {
            guard seenViaIDs.insert(via.id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(via.id)
            }
            guard viaIndexByID[via.id] == nil else {
                throw IncrementalDRCSessionError.duplicateViaID(via.id)
            }
            guard !childViaIDs.contains(via.id) else {
                throw IncrementalDRCSessionError.hierarchyIdentifierCollision(via.id)
            }
        }
        for via in delta.updatedVias {
            guard seenViaIDs.insert(via.id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(via.id)
            }
            guard viaIndexByID[via.id] != nil else {
                throw IncrementalDRCSessionError.unknownViaID(via.id)
            }
        }
        for id in delta.removedViaIDs {
            guard seenViaIDs.insert(id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(id)
            }
            guard viaIndexByID[id] != nil else {
                throw IncrementalDRCSessionError.unknownViaID(id)
            }
        }
    }
}
