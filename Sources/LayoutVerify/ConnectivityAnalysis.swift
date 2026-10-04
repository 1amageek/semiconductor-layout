import Foundation
import LayoutCore

/// Full connectivity verdict for one flattened design generation:
/// label-free extracted conductor pieces plus the shorts and opens that
/// follow from comparing them with the declared nets.
///
/// Both the batch extractor and the live session emit this type through
/// one shared assembly path over canonically ordered components, so equal
/// designs produce bit-identical analyses regardless of edit history.
public struct ConnectivityAnalysis: Equatable, Sendable {
    /// Every extracted conductor piece, in canonical component order.
    public var nets: [ConnectivityNet]
    /// Conductor pieces shorting two or more declared nets, in canonical
    /// component order.
    public var shorts: [ConnectivityShort]
    /// Declared nets split across disconnected conductor pieces, ordered
    /// by net ID.
    public var opens: [ConnectivityOpen]
    /// Owns the source-index and occurrence lifetime of this generation.
    /// Nil is reserved for the empty presentation value and unmigrated internal
    /// assembly paths, which must not publish production electrical results.
    public var sourceSnapshot: LayoutConductorSnapshot? = nil

    public func rootNetReference(for netID: UUID) -> LayoutConductorSnapshot.NetReference? {
        guard let snapshot = sourceSnapshot,
              let root = snapshot.hierarchy.occurrences.firstIndex(where: {
                  $0.parentIndex == nil && $0.sourceCellID == snapshot.hierarchy.rootCellID
              }) else { return nil }
        return .init(occurrenceIndex: root, netID: netID)
    }

    /// All suggested connections across every open net, for canvas
    /// rendering.
    public var flylines: [Flyline] {
        opens.flatMap(\.flylines)
    }

    public static var empty: ConnectivityAnalysis {
        ConnectivityAnalysis(nets: [], shorts: [], opens: [])
    }
}
