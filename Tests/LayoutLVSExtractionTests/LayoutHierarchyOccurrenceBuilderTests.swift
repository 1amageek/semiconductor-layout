import Foundation
import LayoutCore
import LayoutLVSExtraction
import Testing

struct LayoutHierarchyOccurrenceBuilderTests {
    @Test
    func expandsRepeatedInstancesWithStableOccurrenceIDs() throws {
        let topID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let childID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let instanceID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let child = LayoutCell(id: childID, name: "unit")
        let top = LayoutCell(
            id: topID,
            name: "top",
            instances: [
                LayoutInstance(
                    id: instanceID,
                    cellID: childID,
                    name: "array",
                    repetition: LayoutRepetition(
                        columns: 2,
                        rows: 2,
                        columnStep: LayoutPoint(x: 10, y: 0),
                        rowStep: LayoutPoint(x: 0, y: 20)
                    )
                ),
            ]
        )
        let document = LayoutDocument(name: "test", cells: [top, child], topCellID: topID)

        let first = try LayoutHierarchyOccurrenceBuilder().build(
            document: document,
            topCellID: topID,
            maximumOccurrenceCount: 10
        )
        let second = try LayoutHierarchyOccurrenceBuilder().build(
            document: document,
            topCellID: topID,
            maximumOccurrenceCount: 10
        )

        #expect(first.isComplete)
        #expect(first.occurrences.count == 5)
        #expect(first.occurrences.map(\.objectID) == second.occurrences.map(\.objectID))
        #expect(Set(first.occurrences.map(\.objectID)).count == 5)
    }

    @Test
    func regeneratedSourceUUIDsRetainCanonicalOccurrenceIdentity() throws {
        func makeDocument() -> (LayoutDocument, UUID) {
            let child = LayoutCell(name: "unit")
            let top = LayoutCell(
                name: "top",
                instances: [LayoutInstance(cellID: child.id, name: "child")]
            )
            return (
                LayoutDocument(name: "test", cells: [top, child], topCellID: top.id),
                top.id
            )
        }
        let firstDocument = makeDocument()
        let secondDocument = makeDocument()

        let first = try LayoutHierarchyOccurrenceBuilder().build(
            document: firstDocument.0,
            topCellID: firstDocument.1
        )
        let second = try LayoutHierarchyOccurrenceBuilder().build(
            document: secondDocument.0,
            topCellID: secondDocument.1
        )

        #expect(first.occurrences == second.occurrences)
    }

    @Test
    func missingChildCellBlocksExtraction() throws {
        let topID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let missingID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let top = LayoutCell(
            id: topID,
            name: "top",
            instances: [LayoutInstance(cellID: missingID, name: "missing")]
        )
        let inventory = try LayoutHierarchyOccurrenceBuilder().build(
            document: LayoutDocument(name: "test", cells: [top], topCellID: topID),
            topCellID: topID,
            maximumOccurrenceCount: 10
        )

        #expect(!inventory.isComplete)
        #expect(inventory.issues.map(\.code) == ["missing-child-cell"])
    }

    @Test
    func recursiveHierarchyBlocksWithoutLooping() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let first = LayoutCell(
            id: firstID,
            name: "first",
            instances: [LayoutInstance(cellID: secondID, name: "to-second")]
        )
        let second = LayoutCell(
            id: secondID,
            name: "second",
            instances: [LayoutInstance(cellID: firstID, name: "to-first")]
        )
        let inventory = try LayoutHierarchyOccurrenceBuilder().build(
            document: LayoutDocument(name: "test", cells: [first, second], topCellID: firstID),
            topCellID: firstID,
            maximumOccurrenceCount: 10
        )

        #expect(!inventory.isComplete)
        #expect(inventory.issues.map(\.code) == ["recursive-cell-hierarchy"])
        #expect(inventory.occurrences.count == 3)
    }
}
