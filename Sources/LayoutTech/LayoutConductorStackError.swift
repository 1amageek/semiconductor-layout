import Foundation

/// Failure modes of deriving the conductor fabrication order from a
/// technology database's via and contact definitions.
public enum LayoutConductorStackError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The technology declares no via or contact definitions, so no
    /// bottom-before-top ordering between conductor layers can be derived.
    case noCutDefinitions
    /// The bottom→top relations of the via/contact definitions contain a
    /// cycle, so no fabrication order exists.
    case cyclicLayerOrder

    public var description: String {
        switch self {
        case .noCutDefinitions:
            return "no via or contact definitions to derive a conductor order from"
        case .cyclicLayerOrder:
            return "via/contact bottom-to-top relations form a cycle"
        }
    }
}
