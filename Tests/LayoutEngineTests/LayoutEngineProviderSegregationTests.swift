import Foundation
import Testing
import LayoutAutoGen
import LayoutCore
import LayoutEngine
import LayoutTech

@Suite("LayoutEngine Provider Segregation")
struct LayoutEngineProviderSegregationTests {

    @Test func deviceOnlyProviderServesDeviceCellConsumersWithoutFullCatalog() throws {
        let provider = DeviceOnlyProvider(registrations: [
            deviceRegistration(id: "external-passive", canonicalKindID: "external-passive", marker: "generated-passive"),
        ])

        let generatedName = try generatedCellName(
            from: provider,
            canonicalDeviceKindID: "external-passive"
        )

        #expect(provider.deviceCellEngines.map(\.id) == ["external-passive"])
        #expect(generatedName == "generated-passive")
        #expect(provider.deviceCellGenerator(canonicalDeviceKindID: "unsupported") == nil)
    }

    @Test func latestDeviceCellRegistrationOverridesEarlierSupportForSameCanonicalKind() throws {
        var catalog = LayoutEngineCatalog()
        catalog.register(deviceRegistration(id: "first", canonicalKindID: "shared-device", marker: "first-cell"))
        catalog.register(deviceRegistration(id: "second", canonicalKindID: "shared-device", marker: "second-cell"))

        let generatedName = try generatedCellName(
            from: catalog,
            canonicalDeviceKindID: "shared-device"
        )

        #expect(generatedName == "second-cell")
    }

    @Test func postRouteVerifierIsAnExplicitCatalogCapability() throws {
        let standardCatalog = LayoutEngineCatalog.standard()

        do {
            _ = try standardCatalog.makePostRouteVerifier(tech: .standard())
            Issue.record("Expected standard catalog without post-route verifier registration to fail.")
        } catch let error as LayoutEngineCatalogError {
            #expect(error == .missingPostRouteVerifier)
        }

        let catalog = standardCatalog.registering(
            PostRouteVerifierRegistration(
                descriptor: LayoutEngineDescriptor(
                    id: "layer-echo-verifier",
                    name: "Layer Echo Verifier",
                    version: "1.0",
                    role: .postRouteVerification,
                    summary: "Verifies that post-route verifier construction receives technology context.",
                    isDeterministic: true,
                    source: "test"
                ),
                makeVerifier: { tech in
                    LayerEchoPostRouteVerifier(layerName: tech.layers.first?.id.name ?? "missing-layer")
                }
            )
        )

        let verifier = try catalog.makePostRouteVerifier(tech: .standard())
        let violations = try verifier.verify(document: LayoutDocument(name: "probe"))

        #expect(catalog.postRouteVerifiers.map(\.id) == ["layer-echo-verifier"])
        #expect(violations.map(\.message) == ["M1"])
    }

    private func generatedCellName(
        from provider: any DeviceCellEngineProviding,
        canonicalDeviceKindID: String
    ) throws -> String {
        let generator = try #require(provider.deviceCellGenerator(canonicalDeviceKindID: canonicalDeviceKindID))
        let cell = try generator.generateCell(
            deviceKindID: canonicalDeviceKindID,
            instanceName: "X1",
            parameters: [:],
            tech: .standard()
        )
        return cell.name
    }

    private func deviceRegistration(
        id: String,
        canonicalKindID: String,
        marker: String
    ) -> DeviceCellEngineRegistration {
        DeviceCellEngineRegistration(
            descriptor: LayoutEngineDescriptor(
                id: id,
                name: id,
                version: "1.0",
                role: .deviceCellGeneration,
                summary: "Test device-cell provider.",
                isDeterministic: true,
                source: "test"
            ),
            supportedCanonicalDeviceKindIDs: [canonicalKindID],
            makeGenerator: { MarkerDeviceCellGenerator(supportedKindID: canonicalKindID, marker: marker) }
        )
    }
}

private struct DeviceOnlyProvider: DeviceCellEngineProviding {
    private let registrations: [DeviceCellEngineRegistration]

    init(registrations: [DeviceCellEngineRegistration]) {
        self.registrations = registrations
    }

    var deviceCellEngines: [LayoutEngineDescriptor] {
        registrations.map(\.descriptor).sorted { $0.id < $1.id }
    }

    func deviceCellGenerator(canonicalDeviceKindID: String) -> (any DeviceCellGenerator)? {
        for registration in registrations.reversed()
        where registration.supports(canonicalDeviceKindID: canonicalDeviceKindID) {
            return registration.makeGenerator()
        }
        return nil
    }
}

private struct MarkerDeviceCellGenerator: DeviceCellGenerator {
    let supportedKindID: String
    let marker: String

    var supportedDeviceKindIDs: [String] {
        [supportedKindID]
    }

    func generateCell(
        deviceKindID: String,
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> LayoutCell {
        LayoutCell(name: marker)
    }
}

private struct LayerEchoPostRouteVerifier: PostRouteVerifier {
    let layerName: String

    func verify(document: LayoutDocument) throws -> [PostRouteViolation] {
        [PostRouteViolation(message: layerName)]
    }
}
