import Foundation
import CircuiteFoundation

public struct LayoutUnits: Hashable, Sendable, Codable {
    public var dbuPerMicron: Double

    public init(dbuPerMicron: Double) {
        self.dbuPerMicron = dbuPerMicron
    }

    /// Creates layout units from the shared validated database-unit boundary.
    public init(scale: DatabaseUnitScale) {
        self.init(dbuPerMicron: scale.databaseUnitsPerMicrometer)
    }

    /// Returns the shared validated database-unit boundary for this layout.
    ///
    /// The legacy non-throwing initializer remains available for decoding and
    /// compatibility. New layout/technology boundaries should validate by
    /// calling this property before coordinate conversion.
    public var validatedScale: DatabaseUnitScale {
        get throws {
            try DatabaseUnitScale(databaseUnitsPerMicrometer: dbuPerMicron)
        }
    }

    public static let defaultUnits = LayoutUnits(dbuPerMicron: 1000)
}
