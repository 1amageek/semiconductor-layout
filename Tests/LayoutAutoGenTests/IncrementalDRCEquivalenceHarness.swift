import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Drives an `IncrementalDRCSession` and an independent full-scan
/// reference in lockstep. Every delta is mirrored into a reference
/// document with the session's documented ordering semantics (updates in
/// place, removals drop, adds append), then the session snapshot is
/// compared against `LayoutDRCService.run` as a canonical multiset —
/// full-run emission order depends on `Dictionary` iteration, so order is
/// not part of the contract, but every payload field is.
final class IncrementalDRCEquivalenceHarness {
    private(set) var document: LayoutDocument
    let tech: LayoutTechDatabase
    let session: IncrementalDRCSession
    private let service = LayoutDRCService()
    private let topIndex: Int

    init(document: LayoutDocument, tech: LayoutTechDatabase) throws {
        guard let topCellID = document.topCellID,
              let index = document.cells.firstIndex(where: { $0.id == topCellID }) else {
            throw IncrementalDRCEquivalenceHarnessError.unresolvableTopCell
        }
        self.document = document
        self.tech = tech
        self.topIndex = index
        self.session = try IncrementalDRCSession(document: document, tech: tech)
    }

    var topShapes: [LayoutShape] { document.cells[topIndex].shapes }
    var topVias: [LayoutVia] { document.cells[topIndex].vias }

    /// Applies the delta to the session, mirrors it into the reference
    /// document, and requires the live snapshot (minus the deferred
    /// antenna tier) to equal a from-scratch full run.
    @discardableResult
    func applyAndVerify(
        _ delta: LayoutEditDelta,
        context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> IncrementalDRCUpdate {
        let staleBefore = session.staleKinds
        let update = try session.apply(delta)
        try mirror(delta)

        let reference = service.run(document: document, tech: tech)
        expectEquivalent(
            update.result,
            reference,
            excludingAntenna: true,
            context: context,
            sourceLocation: sourceLocation
        )

        // A real edit defers the antenna tier; an empty delta must keep
        // the previous staleness instead of manufacturing it.
        let expectedStale: Set<LayoutViolationKind>
        if delta.isEmpty {
            expectedStale = staleBefore
        } else {
            expectedStale = tech.antennaRules.isEmpty ? [] : [.antenna]
        }
        #expect(
            update.staleKinds == expectedStale,
            "\(context): staleKinds must report exactly the deferred checks",
            sourceLocation: sourceLocation
        )
        #expect(
            Self.canonicalCounts(session.currentResult.violations, excludingAntenna: false)
                == Self.canonicalCounts(update.result.violations, excludingAntenna: false),
            "\(context): currentResult must match the returned snapshot",
            sourceLocation: sourceLocation
        )
        return update
    }

    /// Commits the deferred tier and requires exact equality with the
    /// full run, antenna included.
    func verifyCommit(
        context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let committed = session.commit()
        let reference = service.run(document: document, tech: tech)
        expectEquivalent(
            committed,
            reference,
            excludingAntenna: false,
            context: context,
            sourceLocation: sourceLocation
        )
        #expect(
            session.staleKinds.isEmpty,
            "\(context): commit must clear staleKinds",
            sourceLocation: sourceLocation
        )
    }

    /// Replaces the document (structural change path) and requires the
    /// rebuilt session to equal the full run, antenna included.
    func rebuildAndVerify(
        document newDocument: LayoutDocument,
        context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        document = newDocument
        let rebuilt = try session.rebuild(document: newDocument)
        let reference = service.run(document: newDocument, tech: tech)
        expectEquivalent(
            rebuilt,
            reference,
            excludingAntenna: false,
            context: context,
            sourceLocation: sourceLocation
        )
        #expect(
            session.staleKinds.isEmpty,
            "\(context): rebuild must leave no stale checks",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Reference document mirroring

    private func mirror(_ delta: LayoutEditDelta) throws {
        var cell = document.cells[topIndex]
        for shape in delta.updatedShapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                throw IncrementalDRCEquivalenceHarnessError.missingReferenceShape(shape.id)
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
                throw IncrementalDRCEquivalenceHarnessError.missingReferenceVia(via.id)
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

    // MARK: - Canonical multiset comparison

    private func expectEquivalent(
        _ actual: LayoutDRCResult,
        _ reference: LayoutDRCResult,
        excludingAntenna: Bool,
        context: String,
        sourceLocation: SourceLocation
    ) {
        let actualCounts = Self.canonicalCounts(actual.violations, excludingAntenna: excludingAntenna)
        let referenceCounts = Self.canonicalCounts(reference.violations, excludingAntenna: excludingAntenna)
        if actualCounts == referenceCounts { return }

        var lines: [String] = []
        for key in Set(actualCounts.keys).union(referenceCounts.keys).sorted()
        where actualCounts[key] != referenceCounts[key] {
            lines.append("session=\(actualCounts[key] ?? 0) reference=\(referenceCounts[key] ?? 0) :: \(key)")
        }
        Issue.record(
            "\(context): incremental snapshot diverged from full run\n\(lines.joined(separator: "\n"))",
            sourceLocation: sourceLocation
        )
    }

    /// Canonical violation key: every payload field except the random
    /// `id`; ID arrays are sorted because their order is not part of the
    /// reported semantics.
    static func canonicalKey(_ violation: LayoutViolation) -> String {
        let region = violation.region
        let regionKey = "\(region.origin.x),\(region.origin.y),\(region.size.width),\(region.size.height)"
        let layerKey: String = violation.layer.map { "\($0.name).\($0.purpose)" } ?? "-"
        let measuredKey: String = violation.measured.map { String($0) } ?? "-"
        let requiredKey: String = violation.required.map { String($0) } ?? "-"

        var parts: [String] = []
        parts.append(String(describing: violation.kind))
        parts.append(violation.ruleID ?? "-")
        parts.append(String(describing: violation.severity))
        parts.append(violation.message)
        parts.append(layerKey)
        parts.append(regionKey)
        parts.append(measuredKey)
        parts.append(requiredKey)
        parts.append(violation.unit ?? "-")
        parts.append(violation.shapeIDs.map(\.uuidString).sorted().joined(separator: ","))
        parts.append(violation.viaIDs.map(\.uuidString).sorted().joined(separator: ","))
        parts.append(violation.pinIDs.map(\.uuidString).sorted().joined(separator: ","))
        parts.append(violation.netIDs.map(\.uuidString).sorted().joined(separator: ","))
        parts.append(violation.suggestedFix ?? "-")
        return parts.joined(separator: "|")
    }

    static func canonicalCounts(
        _ violations: [LayoutViolation],
        excludingAntenna: Bool
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for violation in violations where !(excludingAntenna && violation.kind == .antenna) {
            counts[canonicalKey(violation), default: 0] += 1
        }
        return counts
    }
}

private enum IncrementalDRCEquivalenceHarnessError: Error, CustomStringConvertible {
    case unresolvableTopCell
    case missingReferenceShape(UUID)
    case missingReferenceVia(UUID)

    var description: String {
        switch self {
        case .unresolvableTopCell:
            return "Harness fixtures must declare a resolvable top cell."
        case .missingReferenceShape(let id):
            return "Mirror update referenced missing shape \(id)."
        case .missingReferenceVia(let id):
            return "Mirror update referenced missing via \(id)."
        }
    }
}

// MARK: - Rich fixture

extension IncrementalDRCEquivalenceHarness {
    /// Fixture exercising every check family: multi-layer rules with
    /// density windows, notch and wide-metal spacing, an unruled layer for
    /// coverage, a marker-enclosure rule, antenna rules (deferred tier),
    /// vias, nets, and a child cell instantiated twice so flattened child
    /// IDs duplicate.
    struct RichFixture {
        let document: LayoutDocument
        let tech: LayoutTechDatabase
        /// Nets random edits may assign; the child cell's internal net is
        /// deliberately excluded so its buckets stay session-constant.
        let netPool: [UUID]
        let m1: LayoutLayerID
        let m2: LayoutLayerID
        /// Has geometry rules deliberately omitted: shapes here trip the
        /// rule-coverage check.
        let m3: LayoutLayerID
        let mark: LayoutLayerID
        let netA: UUID
        let netB: UUID
        /// M1 wire on net A spanning the fixture.
        let wireA: LayoutShape
        /// M2 pad on net B landed on `viaB`.
        let padB: LayoutShape
        let viaB: LayoutVia
        /// Flattened ID of a child-cell shape; reusing it at top level
        /// must be rejected as a hierarchy collision.
        let childShapeID: UUID
    }

    static func makeRichFixture() -> RichFixture {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let m3 = LayoutLayerID(name: "M3", purpose: "drawing")
        let via1 = LayoutLayerID(name: "VIA1", purpose: "cut")
        let mark = LayoutLayerID(name: "MARK", purpose: "drawing")

        let tech = LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [m1, m2, m3, via1, mark].enumerated().map { index, id in
                LayoutLayerDefinition(
                    id: id,
                    displayName: id.name,
                    gdsLayer: index + 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
                )
            },
            vias: [
                LayoutViaDefinition(
                    id: "VIA1",
                    cutLayer: via1,
                    topLayer: m2,
                    bottomLayer: m1,
                    cutSize: LayoutSize(width: 0.22, height: 0.22),
                    enclosure: LayoutViaEnclosure(top: 0.05, bottom: 0.05),
                    cutSpacing: 0.25
                )
            ],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1,
                    minWidth: 0.23,
                    minSpacing: 0.23,
                    minArea: 0.1,
                    minDensity: 0.0,
                    maxDensity: 0.55,
                    densityWindow: LayoutSize(width: 4, height: 4),
                    densityStep: 4,
                    minNotch: 0.3,
                    wideWidthThreshold: 1.2,
                    wideSpacing: 0.5
                ),
                LayoutLayerRuleSet(
                    layerID: m2,
                    minWidth: 0.28,
                    minSpacing: 0.28,
                    minArea: 0.1,
                    minDensity: 0.0,
                    maxDensity: 1.0
                ),
                LayoutLayerRuleSet(
                    layerID: via1,
                    minWidth: 0,
                    minSpacing: 0.25,
                    minArea: 0,
                    minDensity: 0.0,
                    maxDensity: 1.0
                ),
                LayoutLayerRuleSet(
                    layerID: mark,
                    minWidth: 0.1,
                    minSpacing: 0.1,
                    minArea: 0,
                    minDensity: 0.0,
                    maxDensity: 1.0
                ),
            ],
            antennaRules: [
                LayoutAntennaRule(layerID: m1, maxRatio: 400),
                LayoutAntennaRule(layerID: m2, maxRatio: 400),
            ],
            enclosureRules: [
                LayoutEnclosureRule(outerLayer: mark, innerLayer: m2, minEnclosure: 0.1)
            ]
        )

        let childNet = UUID()
        let childShapeID = UUID()
        let childCell = LayoutCell(
            name: "UNIT",
            shapes: [
                LayoutShape(
                    id: childShapeID,
                    layer: m1,
                    netID: childNet,
                    geometry: .rect(LayoutRect(
                        origin: .zero,
                        size: LayoutSize(width: 0.6, height: 0.4)
                    ))
                ),
                LayoutShape(
                    layer: m2,
                    netID: childNet,
                    geometry: .rect(LayoutRect(
                        origin: LayoutPoint(x: 0.05, y: 0),
                        size: LayoutSize(width: 0.5, height: 0.4)
                    ))
                ),
            ],
            vias: [
                LayoutVia(
                    viaDefinitionID: "VIA1",
                    position: LayoutPoint(x: 0.3, y: 0.2),
                    netID: childNet
                )
            ]
        )

        let netA = UUID()
        let netB = UUID()
        let netPool = [netA, netB, UUID(), UUID(), UUID(), UUID()]

        let wireA = LayoutShape(
            layer: m1,
            netID: netA,
            geometry: .rect(LayoutRect(
                origin: .zero,
                size: LayoutSize(width: 8, height: 0.4)
            ))
        )
        let wireB = LayoutShape(
            layer: m1,
            netID: netB,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 1.5),
                size: LayoutSize(width: 8, height: 0.4)
            ))
        )
        let padA = LayoutShape(
            layer: m2,
            netID: netA,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.3, y: 0),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        let padB = LayoutShape(
            layer: m2,
            netID: netB,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 3.3, y: 1.5),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        let markCover = LayoutShape(
            layer: mark,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: -0.5, y: -0.5),
                size: LayoutSize(width: 6, height: 6)
            ))
        )
        let viaA = LayoutVia(
            viaDefinitionID: "VIA1",
            position: LayoutPoint(x: 0.5, y: 0.2),
            netID: netA
        )
        let viaB = LayoutVia(
            viaDefinitionID: "VIA1",
            position: LayoutPoint(x: 3.5, y: 1.7),
            netID: netB
        )

        let topCell = LayoutCell(
            name: "TOP",
            shapes: [wireA, wireB, padA, padB, markCover],
            vias: [viaA, viaB],
            pins: [
                LayoutPin(
                    name: "A",
                    position: LayoutPoint(x: 0.1, y: 0.2),
                    size: LayoutSize(width: 0.1, height: 0.1),
                    layer: m1,
                    netID: netA
                )
            ],
            instances: [
                LayoutInstance(
                    cellID: childCell.id,
                    name: "u1",
                    transform: LayoutTransform(translation: LayoutPoint(x: 2.0, y: 2.3))
                ),
                LayoutInstance(
                    cellID: childCell.id,
                    name: "u2",
                    transform: LayoutTransform(translation: LayoutPoint(x: 6.5, y: 6.5))
                ),
            ]
        )

        let document = LayoutDocument(
            name: "incremental-drc-fixture",
            cells: [topCell, childCell],
            topCellID: topCell.id
        )
        return RichFixture(
            document: document,
            tech: tech,
            netPool: netPool,
            m1: m1,
            m2: m2,
            m3: m3,
            mark: mark,
            netA: netA,
            netB: netB,
            wireA: wireA,
            padB: padB,
            viaB: viaB,
            childShapeID: childShapeID
        )
    }
}
