import Foundation
import Testing
import LayoutAutoGen
import LayoutCore
import LayoutEngine
import LayoutTech

@Suite("LayoutEngine Catalog Public Contract")
struct LayoutEngineCatalogPublicContractTests {

    @Test func externalPlacementEngineCanBeRegisteredAndSelected() throws {
        let catalog = LayoutEngineCatalog.standard().registering(
            PlacementEngineRegistration(
                descriptor: LayoutEngineDescriptor(
                    id: "external-placement",
                    name: "External Placement",
                    version: "1.0",
                    role: .placement,
                    summary: "Public registration test placement engine.",
                    isDeterministic: true,
                    source: "test"
                ),
                makeEngine: { _ in ExternalPlacementEngine() }
            )
        )

        let engine = try catalog.makePlacementEngine(
            for: .registered("external-placement"),
            constraints: []
        )
        let instanceID = UUID()
        let result = try engine.place(
            instances: [
                PlacementInstance(
                    id: instanceID,
                    cell: LayoutCell(name: "CELL"),
                    deviceType: .passive,
                    name: "X1"
                ),
            ],
            nets: [],
            tech: LayoutTechDatabase.standard()
        )

        #expect(result.placements[instanceID]?.translation == LayoutPoint(x: 7, y: 9))
    }

    @Test func unknownPlacementEngineReportsAvailableIDs() throws {
        do {
            _ = try LayoutEngineCatalog.standard().makePlacementEngine(
                for: .registered("missing"),
                constraints: []
            )
            Issue.record("Expected missing placement engine to fail.")
        } catch let error as LayoutEngineCatalogError {
            guard case .unknownPlacementEngine(let id, let availableIDs) = error else {
                Issue.record("Expected unknown placement engine error.")
                return
            }
            #expect(id == "missing")
            #expect(Set(availableIDs) == Set(["greedy", "optimized"]))
        }
    }

    @Test func externalDeviceCellEngineCanBeRegisteredAndSelected() throws {
        let catalog = LayoutEngineCatalog.standard().registering(
            DeviceCellEngineRegistration(
                descriptor: LayoutEngineDescriptor(
                    id: "external-device-cell",
                    name: "External Device Cell",
                    version: "1.0",
                    role: .deviceCellGeneration,
                    summary: "Public registration test device-cell engine.",
                    isDeterministic: true,
                    source: "test"
                ),
                supportedCanonicalDeviceKindIDs: ["external-device"],
                makeGenerator: { ExternalDeviceCellGenerator() }
            )
        )

        let generator = try #require(catalog.deviceCellGenerator(canonicalDeviceKindID: "external-device"))
        let cell = try generator.generateCell(
            deviceKindID: "external-device",
            instanceName: "X1",
            parameters: [:],
            tech: LayoutTechDatabase.standard()
        )

        #expect(cell.name == "external-device")
    }
}

private struct ExternalPlacementEngine: PlacementEngine {
    func place(
        instances: [PlacementInstance],
        nets: [PlacementNet],
        tech: LayoutTechDatabase
    ) throws -> PlacementResult {
        PlacementResult(
            placements: Dictionary(
                uniqueKeysWithValues: instances.map {
                    ($0.id, LayoutTransform(translation: LayoutPoint(x: 7, y: 9)))
                }
            ),
            powerRails: [],
            totalBoundingBox: LayoutRect(
                origin: LayoutPoint(x: 7, y: 9),
                size: LayoutSize(width: 1, height: 1)
            )
        )
    }
}

private struct ExternalDeviceCellGenerator: DeviceCellGenerator {
    let supportedDeviceKindIDs = ["external-device"]

    func generateCell(
        deviceKindID: String,
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> LayoutCell {
        LayoutCell(name: deviceKindID)
    }
}
