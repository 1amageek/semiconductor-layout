import Foundation

public enum AnalogArrayConstraintKind: String, Codable, Sendable, Equatable, CaseIterable {
    case commonCentroid
    case interdigitated
    case matching
}
