import Foundation
import LayoutCore
import LayoutTech

/// Live LVS session over geometry edits to one cell.
///
/// The first implementation keeps the live contract simple and exact:
/// every non-empty geometry delta updates an internal document copy, then
/// re-extracts the device-level netlist and compares it with the fixed
/// reference netlist. Empty deltas report a skipped comparison explicitly.
public final class LiveLVSSession {
    private var document: LayoutDocument
    private let tech: LayoutTechDatabase
    private let reference: ComparisonNetlist
    private let extractor: DeviceExtractor
    private let comparator: NetlistComparator
    private var cellID: UUID?

    public private(set) var currentExtraction: DeviceExtractionResult
    public private(set) var currentComparison: NetlistComparison

    public init(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        reference: ComparisonNetlist,
        cellID: UUID? = nil,
        extractor: DeviceExtractor = DeviceExtractor(),
        comparator: NetlistComparator = NetlistComparator()
    ) throws {
        self.document = document
        self.tech = tech
        self.reference = reference
        self.extractor = extractor
        self.comparator = comparator
        self.cellID = cellID
        let extraction = try extractor.extract(document: document, tech: tech, cellID: cellID)
        self.currentExtraction = extraction
        self.currentComparison = comparator.compare(
            extracted: extraction.netlist,
            reference: reference
        )
    }

    public var passed: Bool {
        currentExtraction.issues.isEmpty && currentComparison.passed
    }

    public func apply(_ delta: LayoutEditDelta) throws -> LiveLVSUpdate {
        let clock = ContinuousClock()
        let start = clock.now
        guard !delta.isEmpty else {
            return LiveLVSUpdate(
                extraction: currentExtraction,
                comparison: currentComparison,
                skippedComparison: true,
                duration: clock.now - start
            )
        }

        try applyDelta(delta)
        let extraction = try extractor.extract(document: document, tech: tech, cellID: cellID)
        let comparison = comparator.compare(extracted: extraction.netlist, reference: reference)
        currentExtraction = extraction
        currentComparison = comparison
        return LiveLVSUpdate(
            extraction: extraction,
            comparison: comparison,
            skippedComparison: false,
            duration: clock.now - start
        )
    }

    public func rebuild(document: LayoutDocument, cellID: UUID? = nil) throws -> LiveLVSUpdate {
        let clock = ContinuousClock()
        let start = clock.now
        self.document = document
        self.cellID = cellID
        let extraction = try extractor.extract(document: document, tech: tech, cellID: cellID)
        let comparison = comparator.compare(extracted: extraction.netlist, reference: reference)
        currentExtraction = extraction
        currentComparison = comparison
        return LiveLVSUpdate(
            extraction: extraction,
            comparison: comparison,
            skippedComparison: false,
            duration: clock.now - start
        )
    }

    private func applyDelta(_ delta: LayoutEditDelta) throws {
        let resolvedCellID = try targetCellID()
        var cell = try targetCell(resolvedCellID)
        try delta.validateAgainstKnownElements(
            shapeIDs: Set(cell.shapes.map(\.id)),
            viaIDs: Set(cell.vias.map(\.id))
        )
        try Self.applyShapeDelta(delta, to: &cell)
        try Self.applyViaDelta(delta, to: &cell)
        document.updateCell(cell)
    }

    private func targetCellID() throws -> UUID {
        if let cellID {
            return cellID
        } else if let topCellID = document.topCellID {
            return topCellID
        } else if let first = document.cells.first {
            return first.id
        } else {
            throw DeviceExtractionError.targetCellNotFound
        }
    }

    private func targetCell(_ id: UUID) throws -> LayoutCell {
        guard let cell = document.cell(withID: id) else {
            throw DeviceExtractionError.targetCellNotFound
        }
        return cell
    }

    private static func applyShapeDelta(
        _ delta: LayoutEditDelta,
        to cell: inout LayoutCell
    ) throws {
        for shape in delta.updatedShapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                throw LayoutEditDeltaValidationError.unknownShapeID(shape.id)
            }
            cell.shapes[index] = shape
        }
        if !delta.removedShapeIDs.isEmpty {
            let removed = Set(delta.removedShapeIDs)
            cell.shapes.removeAll { removed.contains($0.id) }
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
    }

    private static func applyViaDelta(
        _ delta: LayoutEditDelta,
        to cell: inout LayoutCell
    ) throws {
        for via in delta.updatedVias {
            guard let index = cell.vias.firstIndex(where: { $0.id == via.id }) else {
                throw LayoutEditDeltaValidationError.unknownViaID(via.id)
            }
            cell.vias[index] = via
        }
        if !delta.removedViaIDs.isEmpty {
            let removed = Set(delta.removedViaIDs)
            cell.vias.removeAll { removed.contains($0.id) }
        }
        cell.vias.append(contentsOf: delta.addedVias)
    }
}
