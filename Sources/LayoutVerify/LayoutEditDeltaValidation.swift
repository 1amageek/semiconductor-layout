import Foundation
import LayoutCore

public extension LayoutEditDelta {
    /// Validates that this delta has an unambiguous end state for the
    /// current editable cell contents.
    func validateAgainstKnownElements(
        shapeIDs: Set<UUID>,
        viaIDs: Set<UUID>
    ) throws {
        try validateShapes(knownShapeIDs: shapeIDs)
        try validateVias(knownViaIDs: viaIDs)
    }
}

private extension LayoutEditDelta {
    func validateShapes(knownShapeIDs: Set<UUID>) throws {
        var seenShapeIDs: Set<UUID> = []
        for shape in addedShapes {
            try acceptNewElementID(shape.id, seenIDs: &seenShapeIDs)
            guard !knownShapeIDs.contains(shape.id) else {
                throw LayoutEditDeltaValidationError.duplicateShapeID(shape.id)
            }
        }
        for shape in updatedShapes {
            try acceptNewElementID(shape.id, seenIDs: &seenShapeIDs)
            guard knownShapeIDs.contains(shape.id) else {
                throw LayoutEditDeltaValidationError.unknownShapeID(shape.id)
            }
        }
        for id in removedShapeIDs {
            try acceptNewElementID(id, seenIDs: &seenShapeIDs)
            guard knownShapeIDs.contains(id) else {
                throw LayoutEditDeltaValidationError.unknownShapeID(id)
            }
        }
    }

    func validateVias(knownViaIDs: Set<UUID>) throws {
        var seenViaIDs: Set<UUID> = []
        for via in addedVias {
            try acceptNewElementID(via.id, seenIDs: &seenViaIDs)
            guard !knownViaIDs.contains(via.id) else {
                throw LayoutEditDeltaValidationError.duplicateViaID(via.id)
            }
        }
        for via in updatedVias {
            try acceptNewElementID(via.id, seenIDs: &seenViaIDs)
            guard knownViaIDs.contains(via.id) else {
                throw LayoutEditDeltaValidationError.unknownViaID(via.id)
            }
        }
        for id in removedViaIDs {
            try acceptNewElementID(id, seenIDs: &seenViaIDs)
            guard knownViaIDs.contains(id) else {
                throw LayoutEditDeltaValidationError.unknownViaID(id)
            }
        }
    }

    func acceptNewElementID(_ id: UUID, seenIDs: inout Set<UUID>) throws {
        guard seenIDs.insert(id).inserted else {
            throw LayoutEditDeltaValidationError.conflictingDeltaEntry(id)
        }
    }
}
