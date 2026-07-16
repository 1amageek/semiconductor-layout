import Foundation
import CircuiteFoundation
import LayoutCore
import Testing

@Suite("LayoutUnits Foundation boundary")
struct LayoutUnitsFoundationTests {
    @Test("Layout units can round-trip through the shared database scale")
    func roundTripsThroughDatabaseUnitScale() throws {
        let scale = try DatabaseUnitScale(databaseUnitsPerMicrometer: 1_000.25)
        let units = LayoutUnits(scale: scale)

        #expect(units.scale.databaseUnitsPerMicrometer == 1_000.25)
        #expect(units.scale == scale)
    }

    @Test("Invalid layout units are rejected while decoding")
    func rejectsInvalidScaleWhileDecoding() {
        let data = Data(#"{"scale":0}"#.utf8)

        #expect(throws: DatabaseUnitScaleError.self) {
            _ = try JSONDecoder().decode(LayoutUnits.self, from: data)
        }
    }
}
