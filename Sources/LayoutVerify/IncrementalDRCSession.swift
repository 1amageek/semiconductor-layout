import Foundation
import LayoutCore
import LayoutTech

/// Incremental DRC over geometry edits to one cell.
///
/// The session keeps the flattened design plus the full violation set
/// bucketed by independent check units, and re-verifies only the units an
/// edit can influence:
///
/// - width / area / spacing: per halo-closed cluster of merged-geometry
///   components within a layer; a layer with non-Manhattan geometry
///   degrades to one whole-layer cluster
/// - rect-only / angle rules: per layer
/// - rule coverage: per layer
/// - forbidden marker layers: full exact recompute when marker policy exists
/// - layer-pair spacing rules: exact recompute when pair spacing policy exists
/// - enclosure rules: per layer-pair rule
/// - via enclosure: per via (halo intersection with edited geometry)
/// - minimum-cut rules: full exact recompute when cut policy exists
/// - exact-overlap rules: full exact recompute when layer-pair policy exists
/// - shorts: per shape pair involving an edited shape
/// - opens: per net of an edited element
/// - density: per (layer, window) over a per-shape clipped-area cache;
///   every window when the design bounding box moves
///
/// Each unit is a pure function of its own inputs, so recomputing exactly
/// the units whose inputs changed reproduces the full
/// ``LayoutDRCService/run(document:tech:cellID:)`` violation multiset.
/// The antenna check couples every layer through staged connectivity and
/// is deferred: ``apply(_:)`` carries the last antenna result and reports
/// it via ``IncrementalDRCUpdate/staleKinds``; ``commit()`` re-verifies it.
///
/// Structural changes (pins, instances, child cells, technology) are not
/// expressible as deltas; call ``rebuild(document:cellID:)``.
///
/// The session is single-owner mutable state and is not thread-safe.
public final class IncrementalDRCSession {
    let service = LayoutDRCService()
    let tech: LayoutTechDatabase
    var sourceDocument = LayoutDocument(name: "")
    var sourceCellID: UUID?

    // Flattened design. The target cell's own elements come first in
    // flatten order and are the editable region; contributions from
    // instantiated child cells are constant across deltas.
    var topShapes: [LayoutShape] = []
    var topVias: [LayoutVia] = []
    var topPins: [LayoutPin] = []
    var childShapes: [LayoutShape] = []
    var childVias: [LayoutVia] = []
    var childPins: [LayoutPin] = []
    var childShapeIDs: Set<UUID> = []
    var childViaIDs: Set<UUID> = []

    // Editable element positions, maintained across deltas so apply()
    // does not rebuild ID dictionaries on every edit. Updates keep
    // positions, adds append, and removals rebuild the shifted index.
    var shapeIndexByID: [UUID: Int] = [:]
    var viaIndexByID: [UUID: Int] = [:]

    // Violation buckets, keyed by check unit.
    var terminalConflictViolations: [LayoutViolation] = []
    var coverageByLayer: [LayoutLayerID: [LayoutViolation]] = [:]
    var forbiddenLayerViolations: [LayoutViolation] = []
    var rectOnlyByLayer: [LayoutLayerID: [LayoutViolation]] = [:]
    var angleByLayer: [LayoutLayerID: [LayoutViolation]] = [:]
    var clusterStateByLayer: [LayoutLayerID: LayerClusterState] = [:]
    var spacingByRuleID: [String: [LayoutViolation]] = [:]
    var enclosureByRuleID: [String: [LayoutViolation]] = [:]
    var viaEnclosureViolations: [LayoutViolation] = []
    var minimumCutViolations: [LayoutViolation] = []
    var exactOverlapViolations: [LayoutViolation] = []
    var densityStateByLayer: [LayoutLayerID: LayerDensityState] = [:]
    var shortViolations: [LayoutViolation] = []
    var openByNet: [UUID: [LayoutViolation]] = [:]
    var antennaViolations: [LayoutViolation] = []
    var antennaIsStale = false

    // Current flattened shape occurrences, fully incremental: the shape
    // table, per-layer key sets, per-layer spatial grids, and the per-layer
    // non-Manhattan census are all maintained per delta so apply() never
    // rescans the whole design. Per-layer pair ARRAYS (flatten order) are
    // materialized on demand only for the rare paths that need them.
    var shapeByKey: [FlatShapeKey: LayoutShape] = [:]
    var shapeKeysByLayer: [LayoutLayerID: Set<FlatShapeKey>] = [:]
    var shapeGridByLayer: [LayoutLayerID: MutableFlatShapeGridIndex] = [:]
    var shapeKeysByNet: [UUID: Set<FlatShapeKey>] = [:]
    var nonManhattanKeys: Set<FlatShapeKey> = []
    var nonManhattanCountByLayer: [LayoutLayerID: Int] = [:]
    var viaByKey: [FlatViaKey: LayoutVia] = [:]
    var viaKeysByID: [UUID: Set<FlatViaKey>] = [:]
    var viaKeysByNet: [UUID: Set<FlatViaKey>] = [:]
    var viaHaloGridByLayer: [LayoutLayerID: MutableFlatViaGridIndex] = [:]
    var viaHaloByLayer: [LayoutLayerID: [FlatViaKey: LayoutRect]] = [:]

    /// Whether any layer rule set actually constrains density. When false,
    /// density windows can never produce a violation, so the per-apply
    /// overall-bounding-box scan and window bookkeeping are skipped — the
    /// verdict is identical either way.
    var densityIsTracked = false

    /// Bounding box of all flattened shapes; density windows depend on it,
    /// so a change forces density re-evaluation on every layer.
    var overallBoundingBox: LayoutRect?

    public init(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) throws {
        self.tech = tech
        try configure(document: document, cellID: cellID)
    }

    /// Current violation snapshot. Kinds in ``staleKinds`` are carried
    /// from the last full evaluation, everything else is exact.
    public var currentResult: LayoutDRCResult {
        assembleResult()
    }

    /// Kinds whose violations in ``currentResult`` have not been
    /// re-verified since the last edit; ``commit()`` clears this.
    public var staleKinds: Set<LayoutViolationKind> {
        antennaIsStale ? [.antenna] : []
    }

    /// Re-verifies the deferred checks and returns the exact full result.
    public func commit() -> LayoutDRCResult {
        if antennaIsStale {
            do {
                antennaViolations = try service.checkAntenna(
                    shapes: topShapes + childShapes,
                    vias: topVias + childVias,
                    pins: topPins + childPins,
                    tech: tech
                )
            } catch {
                var result = assembleResult()
                result.diagnostics.append(service.geometryOperationDiagnostic(error))
                return result
            }
            antennaIsStale = false
        }
        return assembleResult()
    }

    /// Full re-verification from a fresh document — the explicit path for
    /// structural changes a delta cannot express (pins, instances, child
    /// cells). The technology database stays fixed for the session.
    public func rebuild(document: LayoutDocument, cellID: UUID? = nil) throws -> LayoutDRCResult {
        try configure(document: document, cellID: cellID)
        return assembleResult()
    }

}

enum OpenContactKey: Hashable {
    case shape(FlatShapeKey)
    case via(FlatViaKey)
}
