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

    /// All suggested connections across every open net, for canvas
    /// rendering.
    public var flylines: [Flyline] {
        opens.flatMap(\.flylines)
    }

    public static var empty: ConnectivityAnalysis {
        ConnectivityAnalysis(nets: [], shorts: [], opens: [])
    }
}
