import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Drives a `LiveConnectivitySession` and the batch
/// `LayoutConnectivityExtractor` in lockstep. Every delta is mirrored into
/// a reference document with the session's documented ordering semantics
/// (updates in place, removals drop, adds append), then the live analysis
/// is required to equal the batch extraction bit-exactly — both paths
/// assemble through the same canonical component order, so `==` is the
/// contract, not a weaker multiset comparison.
final class LiveConnectivityEquivalenceHarness {
    private(set) var document: LayoutDocument
    let tech: LayoutTechDatabase
    let session: LiveConnectivitySession
    private let extractor = LayoutConnectivityExtractor()
    private let topIndex: Int

    init(document: LayoutDocument, tech: LayoutTechDatabase) throws {
        guard let topCellID = document.topCellID,
              let index = document.cells.firstIndex(where: { $0.id == topCellID }) else {
            preconditionFailure("harness fixtures must declare a resolvable top cell")
        }
        self.document = document
        self.tech = tech
        self.topIndex = index
        self.session = try LiveConnectivitySession(document: document, tech: tech)
    }

    var topShapes: [LayoutShape] { document.cells[topIndex].shapes }
    var topVias: [LayoutVia] { document.cells[topIndex].vias }

    /// Applies the delta to the session, mirrors it into the reference
    /// document, and requires the live analysis to equal a from-scratch
    /// batch extraction exactly.
    @discardableResult
    func applyAndVerify(
        _ delta: LayoutEditDelta,
        context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> LiveConnectivityUpdate {
        let update = try session.apply(delta)
        mirror(delta)

        let reference = try extractor.extract(document: document, tech: tech)
        if update.analysis != reference {
            Issue.record(
                "\(context): live analysis diverged from batch extraction\n\(Self.describeDivergence(live: update.analysis, batch: reference))",
                sourceLocation: sourceLocation
            )
        }
        #expect(
            session.currentAnalysis == update.analysis,
            "\(context): currentAnalysis must match the returned snapshot",
            sourceLocation: sourceLocation
        )
        return update
    }

    /// Replaces the document (structural change path) and requires the
    /// rebuilt session to equal the batch extraction.
    func rebuildAndVerify(
        document newDocument: LayoutDocument,
        context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        document = newDocument
        let rebuilt = try session.rebuild(document: newDocument)
        let reference = try extractor.extract(document: newDocument, tech: tech)
        #expect(
            rebuilt == reference,
            "\(context): rebuilt analysis diverged from batch extraction",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Reference document mirroring

    private func mirror(_ delta: LayoutEditDelta) {
        var cell = document.cells[topIndex]
        for shape in delta.updatedShapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                preconditionFailure("mirror: updated shape \(shape.id) missing from reference")
            }
            cell.shapes[index] = shape
        }
        if !delta.removedShapeIDs.isEmpty {
            let removed = Set(delta.removedShapeIDs)
            cell.shapes.removeAll { removed.contains($0.id) }
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
        for via in delta.updatedVias {
            guard let index = cell.vias.firstIndex(where: { $0.id == via.id }) else {
                preconditionFailure("mirror: updated via \(via.id) missing from reference")
            }
            cell.vias[index] = via
        }
        if !delta.removedViaIDs.isEmpty {
            let removed = Set(delta.removedViaIDs)
            cell.vias.removeAll { removed.contains($0.id) }
        }
        cell.vias.append(contentsOf: delta.addedVias)
        document.cells[topIndex] = cell
    }

    // MARK: - Failure diagnostics

    private static func describeDivergence(
        live: ConnectivityAnalysis,
        batch: ConnectivityAnalysis
    ) -> String {
        var lines: [String] = []
        if live.nets.count != batch.nets.count {
            lines.append("net count: live=\(live.nets.count) batch=\(batch.nets.count)")
        }
        if live.shorts.count != batch.shorts.count {
            lines.append("short count: live=\(live.shorts.count) batch=\(batch.shorts.count)")
        }
        if live.opens.count != batch.opens.count {
            lines.append("open count: live=\(live.opens.count) batch=\(batch.opens.count)")
        }
        for (index, pair) in zip(live.nets, batch.nets).enumerated() where pair.0 != pair.1 {
            lines.append("net[\(index)]: live shapes=\(pair.0.shapeIDs.count) vias=\(pair.0.viaIDs.count) declared=\(pair.0.declaredNetIDs.count); batch shapes=\(pair.1.shapeIDs.count) vias=\(pair.1.viaIDs.count) declared=\(pair.1.declaredNetIDs.count)")
        }
        for (index, pair) in zip(live.opens, batch.opens).enumerated() where pair.0 != pair.1 {
            lines.append("open[\(index)] net \(pair.0.netID): live islands=\(pair.0.islands.count) flylines=\(pair.0.flylines.count); batch islands=\(pair.1.islands.count) flylines=\(pair.1.flylines.count)")
        }
        return lines.isEmpty ? "(component membership differs)" : lines.joined(separator: "\n")
    }
}
