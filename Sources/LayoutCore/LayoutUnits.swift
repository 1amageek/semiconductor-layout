import Foundation
import CircuiteFoundation

public struct LayoutUnits: Hashable, Sendable, Codable {
    public let scale: DatabaseUnitScale

    public init(scale: DatabaseUnitScale) {
        self.scale = scale
    }

    public static let defaultUnits = LayoutUnits(scale: .nanometerGrid)
}
