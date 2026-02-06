import Foundation

public enum LayoutConstraint: Hashable, Sendable, Codable {
    case symmetry(LayoutSymmetryConstraint)
    case matching(LayoutMatchingConstraint)
    case commonCentroid(LayoutCommonCentroidConstraint)
    case interdigitated(LayoutInterdigitatedConstraint)

    private enum CodingKeys: String, CodingKey {
        case kind
        case symmetry
        case matching
        case commonCentroid
        case interdigitated
    }

    private enum Kind: String, Codable {
        case symmetry
        case matching
        case commonCentroid
        case interdigitated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .symmetry:
            let value = try container.decode(LayoutSymmetryConstraint.self, forKey: .symmetry)
            self = .symmetry(value)
        case .matching:
            let value = try container.decode(LayoutMatchingConstraint.self, forKey: .matching)
            self = .matching(value)
        case .commonCentroid:
            let value = try container.decode(LayoutCommonCentroidConstraint.self, forKey: .commonCentroid)
            self = .commonCentroid(value)
        case .interdigitated:
            let value = try container.decode(LayoutInterdigitatedConstraint.self, forKey: .interdigitated)
            self = .interdigitated(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symmetry(let value):
            try container.encode(Kind.symmetry, forKey: .kind)
            try container.encode(value, forKey: .symmetry)
        case .matching(let value):
            try container.encode(Kind.matching, forKey: .kind)
            try container.encode(value, forKey: .matching)
        case .commonCentroid(let value):
            try container.encode(Kind.commonCentroid, forKey: .kind)
            try container.encode(value, forKey: .commonCentroid)
        case .interdigitated(let value):
            try container.encode(Kind.interdigitated, forKey: .kind)
            try container.encode(value, forKey: .interdigitated)
        }
    }
}
