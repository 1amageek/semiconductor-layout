import Foundation
import LayoutCore
import LayoutTech
import LayoutVerify
import Testing
@testable import LayoutAutoGen

@Suite("Guard ring generator", .timeLimit(.minutes(1)))
struct GuardRingGeneratorTests {
    private let active = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
    private let pimp = LayoutLayerID(name: "PIMP", purpose: "drawing")
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    @Test func generatedGuardRingIsDeterministicAndDRCClean() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let netID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000301"))
        let request = GuardRingRequest(
            innerRect: LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 8, height: 4)
            ),
            activeLayer: active,
            implantLayer: pimp,
            metalLayer: m1,
            netID: netID,
            idSeed: "diffpair-guard"
        )

        let first = try GuardRingGenerator().generate(request: request, tech: tech)
        let second = try GuardRingGenerator().generate(request: request, tech: tech)

        #expect(first.status == "generated")
        #expect(first.shapeCount == first.shapes.count)
        #expect(first.viaCount == first.vias.count)
        #expect(first.contactCount > 0)
        #expect(first.shapes.map(\.id) == second.shapes.map(\.id))
        #expect(first.vias.map(\.id) == second.vias.map(\.id))
        #expect(first.activeShapeIDs.count == 4)
        #expect(first.implantShapeIDs.count == 4)
        #expect(first.metalShapeIDs.count == 4)
        #expect(first.contactViaIDs.count == first.contactCount)
        #expect(first.shapes.allSatisfy { $0.properties["analogRole"] == "guardRing" })
        #expect(first.shapes.contains { $0.layer == active && $0.netID == netID })
        #expect(first.shapes.contains { $0.layer == pimp && $0.netID == nil })
        #expect(first.shapes.contains { $0.layer == m1 && $0.netID == netID })
        #expect(first.vias.allSatisfy { $0.viaDefinitionID == "CONT_ACTIVE" && $0.netID == netID })

        let cell = LayoutCell(name: "GUARD", shapes: first.shapes)
        var documentCell = cell
        documentCell.vias = first.vias
        let document = LayoutDocument(name: "guard-ring", cells: [documentCell], topCellID: documentCell.id)
        let drc = LayoutDRCService().run(document: document, tech: tech)
        #expect(drc.violations.isEmpty, "guard ring should be DRC clean, got \(drc.violations)")
    }

    @Test func rejectsContactDefinitionThatDoesNotConnectRequestedLayers() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let request = GuardRingRequest(
            innerRect: LayoutRect(
                origin: .zero,
                size: LayoutSize(width: 8, height: 4)
            ),
            activeLayer: active,
            implantLayer: pimp,
            metalLayer: LayoutLayerID(name: "M2", purpose: "drawing"),
            contactDefinitionID: "CONT_ACTIVE",
            idSeed: "bad-contact"
        )

        do {
            _ = try GuardRingGenerator().generate(request: request, tech: tech)
            Issue.record("Expected invalid contact definition")
        } catch AutoGenError.invalidParameter(_, let parameter, _, _) {
            #expect(parameter == "contactDefinitionID")
        } catch {
            Issue.record("Expected invalid contact definition, got \(error)")
        }
    }
}
