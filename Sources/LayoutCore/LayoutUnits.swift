import Foundation

public struct LayoutUnits: Hashable, Sendable, Codable {
    public var dbuPerMicron: Double

    public init(dbuPerMicron: Double) {
        self.dbuPerMicron = dbuPerMicron
    }

    public static let defaultUnits = LayoutUnits(dbuPerMicron: 1000)
}
