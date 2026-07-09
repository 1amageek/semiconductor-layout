import Foundation
import LayoutCore
import LayoutVerify
import Testing
@testable import LayoutAutoGen

@Suite("Analog array placement generator", .timeLimit(.minutes(1)))
struct AnalogArrayPlacementGeneratorTests {
    @Test func generatedArrayPlacesMembersIntoCommonCentroidOrder() throws {
        let fixture = try makeFixture()
        let request = AnalogArrayPlacementRequest(
            memberInstanceIDs: fixture.memberIDs,
            pattern: [0, 0, 1, 1],
            firstSlotCenter: LayoutPoint(x: 0, y: 0),
            slotPitch: LayoutSize(width: 2, height: 0)
        )

        let result = try AnalogArrayPlacementGenerator().generate(
            document: fixture.document,
            cellID: fixture.topCellID,
            request: request
        )

        #expect(result.status == "generated")
        #expect(result.slotLabels == [0, 1, 1, 0])
        #expect(result.arrangedMemberInstanceIDs == [
            fixture.memberIDs[0],
            fixture.memberIDs[2],
            fixture.memberIDs[3],
            fixture.memberIDs[1],
        ])
        #expect(result.persistedConstraints.count == 3)
        #expect(result.placements.map(\.slotCenter) == [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 2, y: 0),
            LayoutPoint(x: 4, y: 0),
            LayoutPoint(x: 6, y: 0),
        ])

        let placed = try apply(result: result, to: fixture.document, topCellID: fixture.topCellID)
        let violations = try LayoutConstraintChecker().check(document: placed, cellID: fixture.topCellID)
        #expect(violations.isEmpty, "analog array constraints should be clean, got \(violations)")
    }

    @Test func rejectsOddGroupCountsWithoutExplicitSlotLabels() throws {
        let fixture = try makeFixture(memberCount: 3)
        let request = AnalogArrayPlacementRequest(
            memberInstanceIDs: fixture.memberIDs,
            pattern: [0, 0, 1],
            firstSlotCenter: .zero,
            slotPitch: LayoutSize(width: 2, height: 0)
        )

        #expect(throws: AutoGenError.self) {
            _ = try AnalogArrayPlacementGenerator().generate(
                document: fixture.document,
                cellID: fixture.topCellID,
                request: request
            )
        }
    }

    @Test func rejectsSlotPitchThatOverlapsMembers() throws {
        let fixture = try makeFixture()
        let request = AnalogArrayPlacementRequest(
            memberInstanceIDs: fixture.memberIDs,
            pattern: [0, 0, 1, 1],
            firstSlotCenter: .zero,
            slotPitch: LayoutSize(width: 0.5, height: 0)
        )

        #expect(throws: AutoGenError.self) {
            _ = try AnalogArrayPlacementGenerator().generate(
                document: fixture.document,
                cellID: fixture.topCellID,
                request: request
            )
        }
    }

    private struct Fixture {
        var document: LayoutDocument
        var topCellID: UUID
        var memberIDs: [UUID]
    }

    private func makeFixture(memberCount: Int = 4) throws -> Fixture {
        let topCellID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000501"))
        let deviceCellID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000502"))
        let memberIDs = try (0..<memberCount).map { index in
            try #require(UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", 503 + index))"))
        }
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let device = LayoutCell(
            id: deviceCellID,
            name: "unit",
            shapes: [
                LayoutShape(
                    layer: layer,
                    geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 2)))
                ),
            ]
        )
        let top = LayoutCell(
            id: topCellID,
            name: "top",
            instances: memberIDs.enumerated().map { index, id in
                LayoutInstance(
                    id: id,
                    cellID: deviceCellID,
                    name: "m\(index)",
                    transform: LayoutTransform(translation: LayoutPoint(x: Double(index) * 10, y: 4))
                )
            }
        )
        let document = LayoutDocument(name: "analog-array", cells: [top, device], topCellID: topCellID)
        return Fixture(document: document, topCellID: topCellID, memberIDs: memberIDs)
    }

    private func apply(
        result: AnalogArrayPlacementResult,
        to document: LayoutDocument,
        topCellID: UUID
    ) throws -> LayoutDocument {
        var updated = document
        var top = try #require(updated.cell(withID: topCellID))
        for placement in result.placements {
            let index = try #require(top.instances.firstIndex { $0.id == placement.instanceID })
            top.instances[index].transform = placement.proposedTransform
        }
        top.constraints.append(contentsOf: result.persistedConstraints)
        updated.updateCell(top)
        return updated
    }
}
