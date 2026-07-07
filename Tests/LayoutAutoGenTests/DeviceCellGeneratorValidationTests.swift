import Testing
import LayoutTech
@testable import LayoutAutoGen

@Suite("Device Cell Generator Validation")
struct DeviceCellGeneratorValidationTests {
    @Test func resistorRejectsNonPositiveResistance() throws {
        try expectInvalidParameter(parameter: "r") {
            _ = try ResistorCellGenerator().generateCell(
                deviceKindID: "resistor",
                instanceName: "R1",
                parameters: ["r": 0],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
    }

    @Test func resistorRejectsInvalidConfiguredSheetResistance() throws {
        try expectInvalidParameter(parameter: "sheetResistance") {
            _ = try ResistorCellGenerator(sheetResistance: .nan).generateCell(
                deviceKindID: "resistor",
                instanceName: "R1",
                parameters: ["r": 1_000],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
    }

    @Test func capacitorRejectsNonFiniteCapacitance() throws {
        try expectInvalidParameter(parameter: "c") {
            _ = try CapacitorCellGenerator().generateCell(
                deviceKindID: "capacitor",
                instanceName: "C1",
                parameters: ["c": .infinity],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
    }

    @Test func capacitorRejectsInvalidConfiguredDensity() throws {
        try expectInvalidParameter(parameter: "oxideCapDensity") {
            _ = try CapacitorCellGenerator(oxideCapDensity: -1).generateCell(
                deviceKindID: "capacitor",
                instanceName: "C1",
                parameters: ["c": 1.0e-15],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
    }

    @Test func mosfetRejectsNonFiniteWidthBeforeGeometryConversion() throws {
        try expectInvalidParameter(parameter: "w") {
            _ = try MOSFETCellGenerator().generateCell(
                deviceKindID: "nmos",
                instanceName: "M1",
                parameters: ["w": .nan, "l": 0.18],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
    }

    @Test func mosfetRejectsFractionalFingerCount() throws {
        try expectInvalidParameter(parameter: "nf") {
            _ = try MOSFETCellGenerator().generateCell(
                deviceKindID: "nmos",
                instanceName: "M1",
                parameters: ["w": 1.0, "l": 0.18, "nf": 1.5],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
    }

    @Test func mosfetRejectsHugeFingerCountBeforeAllocatingGeometry() throws {
        try expectInvalidParameter(parameter: "nf") {
            _ = try MOSFETCellGenerator().generateCell(
                deviceKindID: "nmos",
                instanceName: "M1",
                parameters: ["w": 1.0, "l": 0.18, "nf": 1_025],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
    }

    @Test func generatorsRejectUnsupportedDeviceKindsAtPublicBoundary() throws {
        try expectUnsupportedDevice("capacitor") {
            _ = try ResistorCellGenerator().generateCell(
                deviceKindID: "capacitor",
                instanceName: "R1",
                parameters: ["r": 1_000],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
        try expectUnsupportedDevice("bjt") {
            _ = try MOSFETCellGenerator().generateCell(
                deviceKindID: "bjt",
                instanceName: "Q1",
                parameters: ["w": 1.0, "l": 0.18],
                tech: LayoutTechDatabase.sampleProcess()
            )
        }
    }

    private func expectInvalidParameter(
        parameter: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("Expected invalid parameter '\(parameter)'")
        } catch AutoGenError.invalidParameter(_, let actualParameter, _, _) {
            #expect(actualParameter == parameter)
        } catch {
            Issue.record("Expected invalid parameter '\(parameter)', got \(error)")
        }
    }

    private func expectUnsupportedDevice(
        _ deviceKindID: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("Expected unsupported device '\(deviceKindID)'")
        } catch AutoGenError.unsupportedDevice(let actualDeviceKindID) {
            #expect(actualDeviceKindID == deviceKindID)
        } catch {
            Issue.record("Expected unsupported device '\(deviceKindID)', got \(error)")
        }
    }
}
