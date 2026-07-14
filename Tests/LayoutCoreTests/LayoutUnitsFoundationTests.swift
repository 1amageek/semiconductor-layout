import CircuiteFoundation
import LayoutCore
import Testing

@Suite("LayoutUnits Foundation boundary")
struct LayoutUnitsFoundationTests {
    @Test("Layout units can round-trip through the shared database scale")
    func roundTripsThroughDatabaseUnitScale() throws {
        let scale = try DatabaseUnitScale(databaseUnitsPerMicrometer: 1_000.25)
        let units = LayoutUnits(scale: scale)

        #expect(units.dbuPerMicron == 1_000.25)
        #expect(try units.validatedScale == scale)
    }

    @Test("Invalid layout units are rejected at the shared boundary")
    func rejectsInvalidScale() {
        let units = LayoutUnits(dbuPerMicron: .nan)

        #expect(throws: DatabaseUnitScaleError.self) {
            _ = try units.validatedScale
        }
    }
}
