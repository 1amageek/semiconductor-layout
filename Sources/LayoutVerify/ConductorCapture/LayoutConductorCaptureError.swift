import Foundation
import LayoutCore
import MaskGeometry

public enum LayoutConductorCaptureError: Error, Equatable, Sendable {
    public enum Resource: Sendable, Equatable {
        case technologyRecords, footprints, contactProbes, spatialIndexEntries
    }
    case invalidLimits
    case invalidCoordinateUnits
    case limitExceeded(Resource)
    case unknownLayer(LayoutLayerID)
    case ambiguousLayerRole(LayoutLayerID)
    case duplicateTechnologyID(String)
    case missingViaDefinition(String)
    case incompleteViaTopology(viaID: UUID, definitionID: String)
    case unknownTerminal(occurrenceIndex: Int, name: String)
    case unsupportedGeometry(UUID)
    case invalidGridGeometry(UUID)
    case conflictingTerminalBinding(occurrenceIndex: Int, netID: UUID)
    case invalidFootprintIndex(Int)
    case invalidPinIndex(Int)
    case invalidComposition
    case invalidSpatialBounds
    case incompatibleContactTopology
    case incompatibleContactUnits
    case decompositionFailed(RectilinearDecompositionError)
    case cancelled
}
