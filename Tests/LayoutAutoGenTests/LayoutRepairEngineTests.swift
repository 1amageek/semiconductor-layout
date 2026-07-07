import Foundation
import Testing
import LayoutCore
import LayoutEditor
import LayoutTech
import LayoutVerify

/// N1 contract: a violation either comes with a VERIFIED repair — apply
/// it and the violation is gone with no new error-class fallout — or with
/// a typed reason why not. The sweep converges to a fixed point and names
/// every residual.
@Suite("LayoutRepairEngine", .timeLimit(.minutes(2)))
struct LayoutRepairEngineTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private static let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private static let via1 = LayoutLayerID(name: "VIA1", purpose: "cut")

    @Test func spacingViolationGetsAVerifiedDisplacementRepair() throws {
        let netA = UUID()
        let netB = UUID()
        let left = LayoutShape(
            layer: Self.m1,
            netID: netA,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.4)))
        )
        // 0.1 um gap against a 0.2 um rule.
        let right = LayoutShape(
            layer: Self.m1,
            netID: netB,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.1, y: 0),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [left, right])
        var document = LayoutDocument(name: "fix", cells: [cell], topCellID: cell.id)
        let tech = Self.makeTech()
        let service = LayoutDRCService()
        let violation = try #require(
            service.run(document: document, tech: tech).violations
                .first { $0.kind == .minSpacing }
        )

        let engine = LayoutRepairEngine(document: document, tech: tech, cellID: cell.id)
        guard case .repair(let repair) = try engine.repair(for: violation) else {
            Issue.record("expected a computed repair")
            return
        }

        Self.apply(repair.delta, to: &document, cellID: cell.id)
        let after = service.run(document: document, tech: tech).violations
        #expect(after.isEmpty, "the verified repair must actually clean the design")
    }

    @Test func minWidthViolationGrowsTheRect() throws {
        let thin = LayoutShape(
            layer: Self.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 0.1, height: 1)))
        )
        let cell = LayoutCell(name: "TOP", shapes: [thin])
        var document = LayoutDocument(name: "fix", cells: [cell], topCellID: cell.id)
        let tech = Self.makeTech()
        let violation = try #require(
            LayoutDRCService().run(document: document, tech: tech).violations
                .first { $0.kind == .minWidth }
        )

        let engine = LayoutRepairEngine(document: document, tech: tech, cellID: cell.id)
        guard case .repair(let repair) = try engine.repair(for: violation) else {
            Issue.record("expected a computed repair")
            return
        }

        Self.apply(repair.delta, to: &document, cellID: cell.id)
        #expect(LayoutDRCService().run(document: document, tech: tech).violations.isEmpty)
    }

    @Test func minimumCutViolationAddsAVerifiedViaRepair() throws {
        let net = UUID()
        let bottom = LayoutShape(
            layer: Self.m1,
            netID: net,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        let top = LayoutShape(
            layer: Self.m2,
            netID: net,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        let cell = LayoutCell(name: "TOP", shapes: [bottom, top])
        var document = LayoutDocument(name: "fix-mincut", cells: [cell], topCellID: cell.id)
        let tech = Self.makeMinimumCutTech()
        let service = LayoutDRCService()
        let violation = try #require(
            service.run(document: document, tech: tech).violations
                .first { $0.kind == .minimumCut }
        )

        let engine = LayoutRepairEngine(document: document, tech: tech, cellID: cell.id)
        guard case .repair(let repair) = try engine.repair(for: violation) else {
            Issue.record("expected a computed minimum-cut repair")
            return
        }

        #expect(repair.delta.addedVias.count == 1)
        #expect(repair.delta.addedVias.first?.viaDefinitionID == "VIA1")
        #expect(repair.delta.addedVias.first?.netID == net)

        Self.apply(repair.delta, to: &document, cellID: cell.id)
        let after = service.run(document: document, tech: tech).violations
        #expect(!after.contains { $0.kind == .minimumCut })
    }

    @Test func overlapShortGetsAVerifiedDisplacementRepair() throws {
        let netA = UUID()
        let netB = UUID()
        let first = LayoutShape(
            layer: Self.m1,
            netID: netA,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.4)))
        )
        let second = LayoutShape(
            layer: Self.m1,
            netID: netB,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.5, y: 0),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [first, second])
        var document = LayoutDocument(name: "fix-short", cells: [cell], topCellID: cell.id)
        let tech = Self.makeTech()
        let service = LayoutDRCService()
        let violation = try #require(
            service.run(document: document, tech: tech).violations
                .first { $0.kind == .overlapShort }
        )

        let engine = LayoutRepairEngine(document: document, tech: tech, cellID: cell.id)
        guard case .repair(let repair) = try engine.repair(for: violation) else {
            Issue.record("expected a computed short repair")
            return
        }

        #expect(repair.delta.updatedShapes.count == 1)
        Self.apply(repair.delta, to: &document, cellID: cell.id)
        let after = service.run(document: document, tech: tech).violations
        #expect(!after.contains { $0.kind == .overlapShort })
        #expect(after.isEmpty)
    }

    @Test func blockedRepairIsRefusedBeforeMutating() throws {
        // The violating pair is fenced in on all four sides, so every
        // displacement candidate creates a new violation: the engine must
        // answer "blocked", not offer a bad repair.
        var shapes: [LayoutShape] = []
        let netA = UUID()
        let netB = UUID()
        shapes.append(LayoutShape(
            layer: Self.m1,
            netID: netA,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 0.4, height: 0.4)))
        ))
        shapes.append(LayoutShape(
            layer: Self.m1,
            netID: netB,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.5, y: 0),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        ))
        // Fence at 0.25 um gaps: the 0.1 um displacement candidates land
        // at 0.15 um to a fence piece — every slide trades one violation
        // for another.
        let fenceOrigins = [
            LayoutPoint(x: -0.65, y: 0), LayoutPoint(x: 1.15, y: 0),
            LayoutPoint(x: 0, y: 0.65), LayoutPoint(x: 0.5, y: 0.65),
            LayoutPoint(x: 0, y: -0.65), LayoutPoint(x: 0.5, y: -0.65),
        ]
        for origin in fenceOrigins {
            shapes.append(LayoutShape(
                layer: Self.m1,
                netID: UUID(),
                geometry: .rect(LayoutRect(
                    origin: origin,
                    size: LayoutSize(width: 0.4, height: 0.4)
                ))
            ))
        }
        let cell = LayoutCell(name: "TOP", shapes: shapes)
        let document = LayoutDocument(name: "fenced", cells: [cell], topCellID: cell.id)
        let tech = Self.makeTech()
        let violation = try #require(
            LayoutDRCService().run(document: document, tech: tech).violations
                .first {
                    $0.kind == .minSpacing
                        && Set($0.shapeIDs) == Set([shapes[0].id, shapes[1].id])
                }
        )

        let engine = LayoutRepairEngine(document: document, tech: tech, cellID: cell.id)
        let outcome = try engine.repair(for: violation)

        guard case .infeasible(let reason) = outcome else {
            Issue.record("a fenced-in violation must be refused")
            return
        }
        #expect(reason == .blockedByNeighbours)
    }

    @Test func sweepConvergesAndNamesResiduals() throws {
        // Two repairable violations (spacing + width) and one that is not
        // (a short between declared nets).
        let netA = UUID()
        let netB = UUID()
        var shapes: [LayoutShape] = [
            LayoutShape(
                layer: Self.m1,
                netID: netA,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.4)))
            ),
            LayoutShape(
                layer: Self.m1,
                netID: netB,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 1.1, y: 0),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ),
            LayoutShape(
                layer: Self.m1,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: 5),
                    size: LayoutSize(width: 0.1, height: 1)
                ))
            ),
        ]
        // The short: two overlapping shapes on different nets, far from
        // the rest. It is now repairable by verified displacement.
        shapes.append(LayoutShape(
            layer: Self.m1,
            netID: netA,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 10, y: 10),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        ))
        shapes.append(LayoutShape(
            layer: Self.m1,
            netID: netB,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 10.5, y: 10),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        ))
        let openNet = UUID()
        shapes.append(LayoutShape(
            layer: Self.m1,
            netID: openNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 20, y: 20),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        ))
        shapes.append(LayoutShape(
            layer: Self.m1,
            netID: openNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 25, y: 20),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        ))
        let cell = LayoutCell(name: "TOP", shapes: shapes)
        let document = LayoutDocument(name: "sweep", cells: [cell], topCellID: cell.id)
        let tech = Self.makeTech()

        let engine = LayoutRepairEngine(document: document, tech: tech, cellID: cell.id)
        let (repairs, sweep) = try engine.sweep()

        #expect(sweep.reachedFixedPoint)
        #expect(repairs.count >= 3, "spacing, width, and short must be repaired")
        #expect(!sweep.residuals.isEmpty, "the open must remain, with a reason")
        #expect(sweep.residuals.allSatisfy { violation, reason in
            if case .unsupportedKind = reason {
                return violation.kind == .disconnectedOpen
            }
            return false
        })
    }

    // MARK: - Editor integration

    @MainActor
    @Test func editorAppliesRepairThroughTheEditStreamAndUndoRestores() throws {
        let netA = UUID()
        let netB = UUID()
        let left = LayoutShape(
            layer: Self.m1,
            netID: netA,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.4)))
        )
        let right = LayoutShape(
            layer: Self.m1,
            netID: netB,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.1, y: 0),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [left, right])
        let document = LayoutDocument(name: "fix", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: Self.makeTech())
        let violation = try #require(viewModel.violations.first { $0.kind == .minSpacing })

        let outcome = try #require(viewModel.repairOutcome(for: violation))
        guard case .repair(let repair) = outcome else {
            Issue.record("expected a computed repair")
            return
        }
        viewModel.applyRepair(repair)

        #expect(viewModel.violations.isEmpty, "live DRC must reflect the repair immediately")
        viewModel.undo()
        #expect(viewModel.violations.count == 1, "one repair is one undo unit")
    }

    @MainActor
    @Test func editorFixAllConvergesAndReportsResiduals() throws {
        let netA = UUID()
        let netB = UUID()
        let shapes = [
            LayoutShape(
                layer: Self.m1,
                netID: netA,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.4)))
            ),
            LayoutShape(
                layer: Self.m1,
                netID: netB,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 1.1, y: 0),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ),
            LayoutShape(
                layer: Self.m1,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: 5),
                    size: LayoutSize(width: 0.1, height: 1)
                ))
            ),
        ]
        let cell = LayoutCell(name: "TOP", shapes: shapes)
        let document = LayoutDocument(name: "sweep", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: Self.makeTech())
        #expect(viewModel.violations.count >= 2)

        let sweep = try #require(viewModel.fixAllViolations())

        #expect(sweep.reachedFixedPoint)
        #expect(sweep.residuals.isEmpty)
        #expect(viewModel.violations.isEmpty, "every repairable violation must be gone")
    }

    @MainActor
    @Test func focusCyclingFramesEachViolation() {
        let shapes = [
            LayoutShape(
                layer: Self.m1,
                geometry: .rect(LayoutRect(
                    origin: .zero,
                    size: LayoutSize(width: 0.1, height: 1)
                ))
            ),
            LayoutShape(
                layer: Self.m1,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 10, y: 10),
                    size: LayoutSize(width: 0.1, height: 1)
                ))
            ),
        ]
        let cell = LayoutCell(name: "TOP", shapes: shapes)
        let document = LayoutDocument(name: "focus", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: Self.makeTech())
        viewModel.canvasSize = CGSize(width: 800, height: 600)
        let count = viewModel.violations.count
        #expect(count >= 2)

        viewModel.focusNextViolation()
        let first = viewModel.focusedViolationID
        #expect(first != nil)
        let zoomAfterFirst = viewModel.zoom
        #expect(zoomAfterFirst > 0)

        viewModel.focusNextViolation()
        #expect(viewModel.focusedViolationID != first)

        // Full cycle returns to the first focus.
        for _ in 0..<(count - 1) {
            viewModel.focusNextViolation()
        }
        #expect(viewModel.focusedViolationID == first)
    }

    // MARK: - Helpers

    private static func makeTech() -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: m1,
                    displayName: "M1",
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
                )
            ],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1,
                    minWidth: 0.2,
                    minSpacing: 0.2,
                    minArea: 0.01,
                    minDensity: 0,
                    maxDensity: 1
                )
            ]
        )
    }

    private static func makeMinimumCutTech() -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                layerDefinition(Self.m1),
                layerDefinition(Self.m2),
                layerDefinition(Self.via1),
            ],
            vias: [
                LayoutViaDefinition(
                    id: "VIA1",
                    cutLayer: Self.via1,
                    topLayer: Self.m2,
                    bottomLayer: Self.m1,
                    cutSize: LayoutSize(width: 0.1, height: 0.1),
                    enclosure: LayoutViaEnclosure(top: 0, bottom: 0),
                    cutSpacing: 0.1
                )
            ],
            layerRules: [
                layerRule(Self.m1),
                layerRule(Self.m2),
                layerRule(Self.via1),
            ],
            minimumCutRules: [
                LayoutMinimumCutRule(
                    id: "mincut.VIA1",
                    cutLayer: Self.via1,
                    bottomLayer: Self.m1,
                    topLayer: Self.m2,
                    minimumCount: 1
                )
            ]
        )
    }

    private static func layerDefinition(_ id: LayoutLayerID) -> LayoutLayerDefinition {
        LayoutLayerDefinition(
            id: id,
            displayName: id.name,
            gdsLayer: 1,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
        )
    }

    private static func layerRule(_ id: LayoutLayerID) -> LayoutLayerRuleSet {
        LayoutLayerRuleSet(
            layerID: id,
            minWidth: 0,
            minSpacing: 0,
            minArea: 0,
            minDensity: 0,
            maxDensity: 1
        )
    }

    private static func apply(_ delta: LayoutEditDelta, to document: inout LayoutDocument, cellID: UUID) {
        guard var cell = document.cell(withID: cellID) else { return }
        for shape in delta.updatedShapes {
            if let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) {
                cell.shapes[index] = shape
            }
        }
        let removed = Set(delta.removedShapeIDs)
        if !removed.isEmpty {
            cell.shapes.removeAll { removed.contains($0.id) }
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
        cell.vias.append(contentsOf: delta.addedVias)
        document.updateCell(cell)
    }
}
