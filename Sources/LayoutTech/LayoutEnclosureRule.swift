import Foundation
import LayoutCore

/// Requires `outerLayer` to enclose `innerLayer` geometry by `minEnclosure`.
///
/// The rule applies only where the two layers interact: an inner feature that
/// does not touch the outer layer at all is outside the rule's scope (e.g.
/// NMOS active is never checked against NWELL). An inner feature that does
/// interact must be fully covered with the required margin, unless
/// `allowsPassThrough` is set.
public struct LayoutEnclosureRule: Hashable, Sendable, Codable {
    public var outerLayer: LayoutLayerID
    public var innerLayer: LayoutLayerID
    public var minEnclosure: Double
    /// When true, inner geometry may cross the outer boundary (e.g. resistor
    /// poly passing through its RESI marker to reach its terminals). Only the
    /// covered portion must keep the enclosure margin; the crossing itself is
    /// not a violation, and the margin is not enforced within `minEnclosure`
    /// of the crossing.
    public var allowsPassThrough: Bool

    public init(
        outerLayer: LayoutLayerID,
        innerLayer: LayoutLayerID,
        minEnclosure: Double,
        allowsPassThrough: Bool = false
    ) {
        self.outerLayer = outerLayer
        self.innerLayer = innerLayer
        self.minEnclosure = minEnclosure
        self.allowsPassThrough = allowsPassThrough
    }

    private enum CodingKeys: String, CodingKey {
        case outerLayer
        case innerLayer
        case minEnclosure
        case allowsPassThrough
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outerLayer = try container.decode(LayoutLayerID.self, forKey: .outerLayer)
        self.innerLayer = try container.decode(LayoutLayerID.self, forKey: .innerLayer)
        self.minEnclosure = try container.decode(Double.self, forKey: .minEnclosure)
        self.allowsPassThrough = try container.decode(Bool.self, forKey: .allowsPassThrough)
    }
}
