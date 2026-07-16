import Foundation
import CircuiteFoundation

public struct LayoutUnits: Hashable, Sendable, Codable {
    public let scale: DatabaseUnitScale

    public init(scale: DatabaseUnitScale) {
        self.scale = scale
    }

    public static let defaultUnits: LayoutUnits = {
        do {
            return LayoutUnits(
                scale: try DatabaseUnitScale(databaseUnitsPerMicrometer: 1_000)
            )
        } catch {
            preconditionFailure("The default database-unit scale must be valid: \(error)")
        }
    }()
}
