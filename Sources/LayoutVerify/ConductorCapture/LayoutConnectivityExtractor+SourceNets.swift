import Foundation
import LayoutCore

extension LayoutConnectivityExtractor {
    /// Resolves declared source labels once, including sources not selected
    /// as conducting geometry. Every reference addresses this hierarchy.
    static func resolvedSourceNets(_ hierarchy: LayoutHierarchySnapshot,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> [LayoutConductorSnapshot.Source: LayoutConductorSnapshot.NetReference] {
        typealias Snapshot = LayoutConductorSnapshot
        typealias Failure = LayoutConductorCaptureError
        func checkCancellation() throws { if isCancelled() { throw Failure.cancelled } }
        var aliases: [[UUID: Snapshot.NetReference]] = []
        func resolved(_ net: UUID, occurrence: Int) -> Snapshot.NetReference {
            aliases[occurrence][net] ?? Snapshot.NetReference(occurrenceIndex: occurrence, netID: net)
        }
        for (index, occurrence) in hierarchy.occurrences.enumerated() {
            try checkCancellation()
            var local: [UUID: Snapshot.NetReference] = [:]
            if let parent = occurrence.parentIndex {
                let names = Set(occurrence.pinRange.map { hierarchy.pins[$0].name })
                for name in occurrence.terminalNetIDs.keys {
                    try checkCancellation()
                    guard names.contains(name) else { throw Failure.unknownTerminal(occurrenceIndex: index, name: name) }
                }
                for pinIndex in occurrence.pinRange {
                    let pin = hierarchy.pins[pinIndex]
                    guard let localNet = pin.netID, let parentNet = occurrence.terminalNetIDs[pin.name] else { continue }
                    let reference = resolved(parentNet, occurrence: parent)
                    if let previous = local[localNet], previous != reference {
                        throw Failure.conflictingTerminalBinding(occurrenceIndex: index, netID: localNet)
                    }
                    local[localNet] = reference
                }
            }
            aliases.append(local)
        }
        var result: [Snapshot.Source: Snapshot.NetReference] = [:]
        for (index, occurrence) in hierarchy.occurrences.enumerated() {
            try checkCancellation()
            for source in occurrence.shapeRange {
                if let net = hierarchy.shapes[source].netID { result[.shape(source)] = resolved(net, occurrence: index) }
            }
            for source in occurrence.viaRange {
                if let net = hierarchy.vias[source].netID { result[.via(source)] = resolved(net, occurrence: index) }
            }
            for source in occurrence.pinRange {
                let pin = hierarchy.pins[source]
                if let net = pin.netID { result[.pin(source)] = resolved(net, occurrence: index) }
                else if let parent = occurrence.parentIndex, let net = occurrence.terminalNetIDs[pin.name] {
                    result[.pin(source)] = resolved(net, occurrence: parent)
                }
            }
        }
        return result
    }
}
