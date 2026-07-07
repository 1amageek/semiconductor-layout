import Foundation
import LayoutCore
import LayoutTech

struct IncrementalDRCApplyAnalysis {
    var dirtyLayers: Set<LayoutLayerID> = []
    var affectedNets: Set<UUID> = []
    var editedShapeIDs: Set<UUID> = []
    var affectedViaIDs: Set<UUID> = []
    var dirtyRectsByLayer: [LayoutLayerID: [LayoutRect]] = [:]
    var editedKeysByLayer: [LayoutLayerID: Set<FlatShapeKey>] = [:]
    var idListChangedLayers: Set<LayoutLayerID> = []
    var openMustRecomputeNets: Set<UUID> = []
    var shapeOpenContactsBefore: [UUID: (netID: UUID, contacts: Set<OpenContactKey>)] = [:]
    var viaOpenContactsBefore: [UUID: (netID: UUID, contacts: Set<OpenContactKey>)] = [:]

    mutating func markShape(_ shape: LayoutShape, forcesOpenRecompute: Bool) {
        dirtyLayers.insert(shape.layer)
        editedShapeIDs.insert(shape.id)
        if let netID = shape.netID {
            affectedNets.insert(netID)
            if forcesOpenRecompute {
                openMustRecomputeNets.insert(netID)
            }
        }
        dirtyRectsByLayer[shape.layer, default: []]
            .append(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        editedKeysByLayer[shape.layer, default: []].insert(.top(shape.id))
    }
}
