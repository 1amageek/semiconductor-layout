import SwiftUI
import LayoutAutoGen
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutIO
import LayoutIR
import MaskGeometry

@Observable
@MainActor
public final class LayoutEditorViewModel {
    public var editor: LayoutDocumentEditor
    public var tech: LayoutTechDatabase
    public var tool: LayoutTool = .select
    public var activeCellID: UUID?
    public var activeLayer: LayoutLayerID {
        didSet {
            guard oldValue != activeLayer else { return }
            routeFollowActiveLayer()
        }
    }
    public var activeViaID: String
    public var zoom: CGFloat = 1.0
    public var offset: CGPoint = .zero
    public var canvasSize: CGSize = .zero {
        didSet {
            guard pendingFitAll, canvasSize.width > 0, canvasSize.height > 0 else { return }
            pendingFitAll = false
            fitAll()
        }
    }

    /// Set when ``fitAll()`` is requested before the canvas has been laid out
    /// (e.g. layout generated while the editor view is off screen). The fit is
    /// applied as soon as the canvas reports a non-zero size.
    @ObservationIgnored
    var pendingFitAll = false
    public var gridSize: Double
    public var selectedShapeIDs: Set<UUID> = []
    public var selectedInstanceID: UUID?
    public var highlightedInstanceIDs: Set<UUID> = []
    public var violations: [LayoutViolation] = []
    public var lastError: String?
    public var hiddenLayers: Set<LayoutLayerID> = []
    public var cellNavigationPath: [UUID] = []

    /// Pointer position in layout space while the cursor is over the
    /// canvas, `nil` when it leaves — drives the coordinate readout.
    public var cursorPosition: LayoutPoint?

    // MARK: - Live DRC (DRD)

    /// Design-rule-driven editing mode. In `observe` and `enforce` every
    /// edit re-verifies incrementally and ``violations`` stays live; in
    /// `enforce` interactive drags additionally stick at legal positions.
    public var drdMode: DRDMode = .observe {
        didSet {
            guard drdMode != oldValue else { return }
            if drdMode == .off {
                liveDRC = nil
                staleViolationKinds = []
            } else {
                resyncLiveDRC()
            }
        }
    }

    /// Violation kinds in ``violations`` not re-verified since the last
    /// edit (the live session's deferred tier, or everything when live
    /// verification is unavailable).
    public internal(set) var staleViolationKinds: Set<LayoutViolationKind> = []

    /// How the last design-rule-driven drag proposal resolved, for canvas
    /// feedback while a drag is active.
    public internal(set) var dragOutcome: DRDDragOutcome?

    var liveDRC: IncrementalDRCSession?
    var dragSession: DRDDragSession?
    var dragOriginShapes: [LayoutShape]?
    /// Whether the active drag moves freshly added copies (Option-drag
    /// duplicate); cancel then removes the copies instead of restoring
    /// their positions.
    var dragIsDuplicating = false

    // MARK: - Handle Editing State

    /// The handle currently being dragged, with the shape it belongs to,
    /// for canvas feedback. Non-nil exactly while a handle drag is active.
    public internal(set) var activeHandleDrag: (shapeID: UUID, handle: LayoutShapeHandle)?
    var handleOriginShape: LayoutShape?

    // MARK: - Live Connectivity

    /// Exact connectivity of the active cell, maintained incrementally
    /// across every edit. `nil` means live connectivity is unavailable
    /// (disabled, or the session failed and could not be rebuilt) — the
    /// editor never shows a stale analysis as if it were current.
    public private(set) var connectivityAnalysis: ConnectivityAnalysis?

    /// Live connectivity extraction; independent of ``drdMode`` because
    /// nets/shorts/opens are a different verdict channel than design
    /// rules.
    public var liveConnectivityEnabled: Bool = true {
        didSet {
            guard liveConnectivityEnabled != oldValue else { return }
            if liveConnectivityEnabled {
                resyncLiveConnectivity()
            } else {
                liveConnectivity = nil
                connectivityAnalysis = nil
            }
        }
    }

    /// Flylines of every open net — the unrouted-connection guides the
    /// canvas draws live while editing.
    public var flylines: [Flyline] { connectivityAnalysis?.flylines ?? [] }

    /// The extracted net the highlight anchor currently belongs to,
    /// re-resolved against the live analysis so the highlight follows the
    /// conductor through edits.
    public var highlightedNet: ConnectivityNet? {
        guard let anchor = netHighlightAnchor, let analysis = connectivityAnalysis else { return nil }
        switch anchor {
        case .shape(let id): return analysis.nets.first { $0.shapeIDs.contains(id) }
        case .via(let id): return analysis.nets.first { $0.viaIDs.contains(id) }
        }
    }

    private enum NetHighlightAnchor {
        case shape(UUID)
        case via(UUID)
    }

    private var liveConnectivity: LiveConnectivitySession?
    private var netHighlightAnchor: NetHighlightAnchor?

    // MARK: - Live Constraints

    /// Broken design-intent constraints (symmetry, matching, alignment,
    /// common centroid, interdigitation) of the active cell, re-evaluated
    /// on every edit — a third verdict channel beside design rules and
    /// connectivity.
    public private(set) var constraintViolations: [LayoutConstraintViolation] = []
    private var liveConstraints: LiveConstraintSession?

    // MARK: - Live LVS

    public private(set) var lvsExtraction: DeviceExtractionResult?
    public private(set) var lvsComparison: NetlistComparison?

    var lvsReference: ComparisonNetlist?
    private var liveLVS: LiveLVSSession?

    // MARK: - Scale Rendering

    /// Spatial index over the active cell's flattened geometry, kept in
    /// lockstep with every edit so ``currentRenderPlan()`` answers in
    /// time proportional to the visible set, never the whole database.
    /// `nil` only when there is no active cell.
    private var renderIndex: LayoutRenderIndex?

    // MARK: - Tool Options

    /// Path width for the path tool. Defaults to minimum width of active layer or tech grid.
    public var pathWidth: Double = 0.1
    /// Path end-cap style.
    public var pathEndCap: LayoutPathEndCap = .extend
    /// Angle constraint mode for drawing operations.
    public var angleConstraint: LayoutAngleConstraint = .manhattan

    // MARK: - Rulers

    public var rulers: [LayoutRuler] = []
    var cellBackStack: [CellNavigationState] = []

    struct CellNavigationState {
        var activeCellID: UUID?
        var path: [UUID]
    }

    public init(tech: LayoutTechDatabase = .standard()) {
        let cell = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "Layout", cells: [cell], topCellID: cell.id)
        self.editor = LayoutDocumentEditor(document: document)
        self.activeCellID = cell.id
        self.tech = tech
        self.gridSize = tech.grid
        self.activeLayer = tech.layers.first?.id ?? LayoutLayerID(name: "M1", purpose: "drawing")
        self.activeViaID = tech.vias.first?.id ?? "VIA1"
        self.pathWidth = defaultPathWidth(for: tech)
        self.cellNavigationPath = [cell.id]
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }

    public init(document: LayoutDocument, tech: LayoutTechDatabase) {
        self.editor = LayoutDocumentEditor(document: document)
        self.activeCellID = document.topCellID ?? document.cells.first?.id
        self.tech = tech
        self.gridSize = tech.grid
        self.activeLayer = tech.layers.first?.id ?? LayoutLayerID(name: "M1", purpose: "drawing")
        self.activeViaID = tech.vias.first?.id ?? "VIA1"
        self.pathWidth = defaultPathWidth(for: tech)
        self.cellNavigationPath = Self.initialNavigationPath(document: document, activeCellID: self.activeCellID)
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        rebuildRenderIndex()
    }

    /// Full verification on demand: re-verifies the live session's
    /// deferred tier when one is active, or runs the batch checker.
    public func runDRC() {
        if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        } else {
            let service = LayoutDRCService()
            violations = service.run(document: editor.document, tech: tech, cellID: activeCellID).violations
            staleViolationKinds = []
        }
    }

    // MARK: - Live DRC Plumbing

    /// (Re)builds the live session from the current document and active
    /// cell. On failure the error is surfaced and every violation kind is
    /// declared stale rather than pretending the snapshot is current.
    func resyncLiveDRC() {
        guard drdMode != .off, let cellID = activeCellID else {
            liveDRC = nil
            return
        }
        do {
            let result: LayoutDRCResult
            if let liveDRC {
                result = try liveDRC.rebuild(document: editor.document, cellID: cellID)
            } else {
                let session = try IncrementalDRCSession(
                    document: editor.document,
                    tech: tech,
                    cellID: cellID
                )
                liveDRC = session
                result = session.currentResult
            }
            violations = result.violations
            staleViolationKinds = []
        } catch {
            liveDRC = nil
            staleViolationKinds = Set(LayoutViolationKind.allCases)
            handleError(error)
        }
    }

    /// Tears down and rebuilds the live session — required when the
    /// technology database changes, which a session cannot absorb.
    func restartLiveDRC() {
        liveDRC = nil
        resyncLiveDRC()
    }

    // MARK: - Live Connectivity Plumbing

    /// (Re)builds the connectivity session from the current document and
    /// active cell. On failure the error is surfaced and the analysis
    /// becomes `nil` — unavailable, never silently stale.
    func resyncLiveConnectivity() {
        guard liveConnectivityEnabled, let cellID = activeCellID else {
            liveConnectivity = nil
            connectivityAnalysis = nil
            return
        }
        do {
            if let liveConnectivity {
                connectivityAnalysis = try liveConnectivity.rebuild(
                    document: editor.document,
                    cellID: cellID
                )
            } else {
                let session = try LiveConnectivitySession(
                    document: editor.document,
                    tech: tech,
                    cellID: cellID
                )
                liveConnectivity = session
                connectivityAnalysis = session.currentAnalysis
            }
        } catch {
            liveConnectivity = nil
            connectivityAnalysis = nil
            handleError(error)
        }
    }

    /// Tears down and rebuilds the connectivity session — required when
    /// the technology database changes, which a session cannot absorb.
    func restartLiveConnectivity() {
        liveConnectivity = nil
        resyncLiveConnectivity()
    }

    /// Applies a document delta to the connectivity session in lockstep.
    /// A rejected delta is a programming error in delta construction:
    /// surface it and rebuild so the analysis stays truthful.
    func applyConnectivityDelta(_ delta: LayoutEditDelta) {
        guard let liveConnectivity else { return }
        do {
            connectivityAnalysis = try liveConnectivity.apply(delta).analysis
        } catch {
            handleError(error)
            resyncLiveConnectivity()
        }
    }

    // MARK: - Constraint Plumbing

    /// The active cell's persisted design-intent constraints.
    public var activeCellConstraints: [LayoutConstraint] {
        activeCell?.constraints ?? []
    }

    /// Rebuilds the live constraint session after structural changes such
    /// as constraint CRUD, cell navigation, undo/redo, or document loads.
    func refreshConstraintViolations() {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID),
              !cell.constraints.isEmpty else {
            liveConstraints = nil
            constraintViolations = []
            return
        }
        do {
            if let liveConstraints {
                constraintViolations = try liveConstraints.rebuild(
                    document: editor.document,
                    cellID: cellID
                )
            } else {
                let session = try LiveConstraintSession(
                    document: editor.document,
                    cellID: cellID
                )
                liveConstraints = session
                constraintViolations = session.currentViolations
            }
        } catch {
            // Only reachable if the active cell vanished mid-call; surface
            // it and report no verdict rather than a stale one.
            liveConstraints = nil
            handleError(error)
            constraintViolations = []
        }
    }

    /// Applies a geometry delta to the live constraint session. A rejected
    /// delta is treated like the other live-session failures: surface it and
    /// rebuild from the document so the displayed verdict remains truthful.
    func applyConstraintDelta(_ delta: LayoutEditDelta) {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID),
              !cell.constraints.isEmpty else {
            liveConstraints = nil
            constraintViolations = []
            return
        }
        guard let liveConstraints else {
            refreshConstraintViolations()
            return
        }
        do {
            constraintViolations = try liveConstraints.apply(delta).violations
        } catch {
            handleError(error)
            refreshConstraintViolations()
        }
    }

    // MARK: - LVS Plumbing

    public var liveLVSPassed: Bool? {
        guard let extraction = lvsExtraction, let comparison = lvsComparison else { return nil }
        return extraction.issues.isEmpty && comparison.passed
    }

    public func setLVSReference(_ reference: ComparisonNetlist?) {
        lvsReference = reference
        liveLVS = nil
        resyncLiveLVS()
    }

    /// Loads the LVS reference from SPICE `.subckt` text. Parse failures
    /// are surfaced and leave the previous reference untouched.
    public func loadLVSReference(fromSubckt text: String, subcircuit: String? = nil) {
        do {
            setLVSReference(try SPICESubcktReader().read(text, subcircuit: subcircuit))
        } catch {
            handleError(error)
        }
    }

    func resyncLiveLVS() {
        guard let reference = lvsReference, let cellID = activeCellID else {
            liveLVS = nil
            lvsExtraction = nil
            lvsComparison = nil
            return
        }
        do {
            if let liveLVS {
                let update = try liveLVS.rebuild(document: editor.document, cellID: cellID)
                lvsExtraction = update.extraction
                lvsComparison = update.comparison
            } else {
                let session = try LiveLVSSession(
                    document: editor.document,
                    tech: tech,
                    reference: reference,
                    cellID: cellID
                )
                liveLVS = session
                lvsExtraction = session.currentExtraction
                lvsComparison = session.currentComparison
            }
        } catch {
            liveLVS = nil
            lvsExtraction = nil
            lvsComparison = nil
            handleError(error)
        }
    }

    func applyLVSDelta(_ delta: LayoutEditDelta) {
        guard let liveLVS else { return }
        do {
            let update = try liveLVS.apply(delta)
            lvsExtraction = update.extraction
            lvsComparison = update.comparison
        } catch {
            handleError(error)
            resyncLiveLVS()
        }
    }

    // MARK: - Goal commands (N5)

    /// Executed goal-command log. This is the headless command stream
    /// external agents can replay to reproduce intent-level edits.
    public internal(set) var goalLog: [LayoutGoalRecord] = []

    // MARK: - SDL Intent State

    /// Device currently armed for placement from schematic/SDL intent.
    public internal(set) var pendingIntentDevice: ComparisonNetlist.Device?

    // MARK: - Focus State

    /// The violation currently focused by n/N cycling, highlighted on
    /// the canvas.
    public internal(set) var focusedViolationID: UUID?

    // MARK: - In-Place Editing State

    /// Instance path from the viewed active cell down to the in-place edit target.
    public internal(set) var inPlaceInstancePath: [UUID] = []

    /// True while an in-place gesture has redrawn the canvas and verification is pending.
    public internal(set) var inPlaceVerificationPending = false

    // MARK: - Interactive Routing

    /// DRC-enforced route drawing on the active layer. The session previews
    /// against its own incremental-DRC mirror; the document is untouched
    /// until ``commitRoute()`` pushes the legal shapes through the single
    /// edit stream.
    var routeSession: InteractiveRouteSession?

    /// When enabled, a blocked route tick pushes same-layer neighbours
    /// out of the way (bounded, atomic) instead of stopping short.
    public var routeShoveEnabled = false

    /// Last route tick, for the canvas preview: legal geometry, the legal
    /// end, and the stop reason when the requested point was blocked.
    public private(set) var routePreview: RoutePreview?

    public var isRouting: Bool { routeSession != nil }

    /// Starts a route at `point` on the active layer. The net comes from
    /// `netID` when given (intent-driven flows know their net even when
    /// the anchor geometry carries none), else from the topmost shape
    /// under the start point.
    public func beginRoute(at point: LayoutPoint, netID: UUID? = nil) {
        guard let cellID = activeCellID else { return }
        guard !isEditingInPlace else {
            handleError(LayoutEditorError.routingUnavailableInPlace)
            return
        }
        cancelRoute()
        do {
            routeSession = try InteractiveRouteSession(
                document: editor.document,
                cellID: cellID,
                tech: tech,
                start: RouteAnchor(
                    point: snapToGrid(point),
                    layer: activeLayer,
                    netID: netID ?? self.netID(at: point, on: activeLayer)
                ),
                mode: routeShoveEnabled ? .shove : .manual,
                width: pathWidth > 0 ? pathWidth : nil
            )
            routePreview = nil
        } catch {
            handleError(error)
        }
    }

    /// Completes the current route to `target` with a window-local path
    /// search. The search is confined to the bounding window of the route
    /// anchor and the target (plus a margin); no path inside that window
    /// is an explicit error, never a silent detour. `targetRegion` widens
    /// the goal from the exact point to anywhere on the target island.
    /// `step` overrides the lattice pitch — callers widening the window
    /// coarsen the lattice to keep the search bounded; the committed
    /// route is still judged by exact DRC in `proposePath`.
    public func completeRoute(
        to target: LayoutPoint,
        windowMargin: Double = 2.0,
        targetRegion: [LayoutRect] = [],
        step: Double? = nil,
        allowBlockedRegionGoal: Bool = true
    ) {
        guard let session = routeSession else { return }
        let anchor = session.currentAnchor
        let snappedTarget = snapToGrid(target)
        let width = pathWidth > 0 ? pathWidth : (tech.ruleSet(for: anchor.layer)?.minWidth ?? 0.1)
        let spacing = tech.ruleSet(for: anchor.layer)?.minSpacing ?? 0
        let window = LayoutRect(
            origin: LayoutPoint(
                x: min(anchor.point.x, snappedTarget.x) - windowMargin,
                y: min(anchor.point.y, snappedTarget.y) - windowMargin
            ),
            size: LayoutSize(
                width: abs(anchor.point.x - snappedTarget.x) + 2 * windowMargin,
                height: abs(anchor.point.y - snappedTarget.y) + 2 * windowMargin
            )
        )
        // Obstacles come from the connectivity analysis, whose member
        // footprints are occurrence-exact — id-based filtering would
        // alias reused child shapes across instances, hiding a foreign
        // occurrence or walling off an own-net one. Conductor pieces
        // carrying the route's net are legal landing places, all others
        // block. The BFS is only a guide; `proposePath` re-judges the
        // result against exact DRC either way.
        let obstacles = (connectivityAnalysis?.nets ?? [])
            .filter { net in
                guard let netID = anchor.netID else { return true }
                return !net.declaredNetIDs.contains(netID)
            }
            .flatMap(\.memberFootprints)
            .filter { $0.layer == anchor.layer }
            .map(\.boundingBox)
            .filter { $0.intersects(window) }
        let path = RouteAutoCompleter().findPath(RouteAutoCompleter.Request(
            start: anchor.point,
            target: snappedTarget,
            window: window,
            obstacles: obstacles,
            clearance: width / 2 + spacing,
            step: max(step ?? gridSize, 0.01),
            targetRegion: targetRegion,
            allowBlockedRegionGoal: allowBlockedRegionGoal
        ))
        guard let path else {
            handleError(LayoutEditorError.routeWindowMiss)
            return
        }
        do {
            routePreview = try routeSession?.proposePath(Array(path.dropFirst()))
        } catch {
            handleError(error)
        }
    }

    /// Keeps the route session's layer in lockstep with the palette: a
    /// layer change during routing freezes the current leg and drops a
    /// via at its legal end. A failed switch (no via, blocked landing)
    /// is surfaced and the route stays on the previous layer.
    private func routeFollowActiveLayer() {
        guard routeSession != nil,
              routeSession?.currentAnchor.layer != activeLayer else { return }
        do {
            routePreview = try routeSession?.switchLayer(to: activeLayer)
        } catch {
            handleError(error)
        }
    }

    public func updateRoute(to point: LayoutPoint) {
        guard routeSession != nil else { return }
        do {
            routePreview = try routeSession?.tick(to: point)
        } catch {
            handleError(error)
            cancelRoute()
        }
    }

    /// Commits the legal part of the current route through `commitDelta`
    /// (one undo unit, all live systems follow) and ends the session.
    /// Returns the committed route's legal end so callers can chain the
    /// next segment from there.
    @discardableResult
    public func commitRoute() -> LayoutPoint? {
        guard routeSession != nil else { return nil }
        let legalEnd = routePreview?.legalEnd
        let delta = routeSession?.commit() ?? LayoutEditDelta()
        routeSession = nil
        routePreview = nil
        guard !delta.isEmpty else { return nil }
        commitDelta(delta)
        return legalEnd
    }

    public func cancelRoute() {
        guard routeSession != nil else { return }
        // The session only mutates its own DRC mirror, so a failed cancel
        // cannot corrupt the document; dropping the session is safe either
        // way, but the error is still surfaced.
        do {
            try routeSession?.cancel()
        } catch {
            handleError(error)
        }
        routeSession = nil
        routePreview = nil
    }

    private func netID(at point: LayoutPoint, on layer: LayoutLayerID) -> UUID? {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else { return nil }
        for shape in cell.shapes.reversed() where shape.layer == layer {
            if LayoutGeometryAnalysis.contains(point, in: shape.geometry) {
                return shape.netID
            }
        }
        return nil
    }

    /// Adds a persisted constraint to the active cell (undoable) and
    /// re-evaluates immediately.
    public func addConstraint(_ constraint: LayoutConstraint) {
        guard let cellID = activeCellID else { return }
        do {
            try editor.perform { doc in
                guard var cell = doc.cell(withID: cellID) else {
                    throw LayoutCoreError.cellNotFound(cellID)
                }
                cell.constraints.append(constraint)
                doc.updateCell(cell)
            }
        } catch {
            handleError(error)
            return
        }
        refreshConstraintViolations()
    }

    /// Removes the active cell's constraint at `index` (undoable) and
    /// re-evaluates immediately.
    public func removeConstraint(at index: Int) {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID),
              cell.constraints.indices.contains(index) else { return }
        do {
            try editor.perform { doc in
                guard var cell = doc.cell(withID: cellID) else {
                    throw LayoutCoreError.cellNotFound(cellID)
                }
                cell.constraints.remove(at: index)
                doc.updateCell(cell)
            }
        } catch {
            handleError(error)
            return
        }
        refreshConstraintViolations()
    }

    // MARK: - Render Plumbing

    /// (Re)builds the render index from the flattened active cell.
    /// Structural changes (instances, cell navigation, undo/redo,
    /// document loads) land here; geometry deltas instead go through
    /// `LayoutRenderIndex.apply` in lockstep with the document.
    ///
    /// The active-element index shares exactly these boundaries, so it is
    /// rebuilt here too: both are derived state over the active cell that
    /// follows geometry deltas in O(delta) between structural rebuilds.
    func rebuildRenderIndex() {
        rebuildActiveElementIndex()
        guard activeCellID != nil else {
            renderIndex = nil
            return
        }
        renderIndex = LayoutRenderIndex(shapes: flattenedDocumentShapes())
    }

    /// Routes a geometry delta into the render index. An index built over
    /// an empty document has a placeholder grid with no real scale, so the
    /// first content rebuilds instead — deriving the grid from the actual
    /// extent — and every later delta applies incrementally as usual.
    func applyRenderIndexDelta(_ delta: LayoutEditDelta) {
        guard renderIndex != nil else { return }
        if renderIndex?.count == 0,
           !(delta.addedShapes.isEmpty && delta.updatedShapes.isEmpty) {
            rebuildRenderIndex()
        } else {
            renderIndex?.apply(delta)
        }
    }

    // MARK: - Active-Element Index

    /// Current top-level shapes of the active cell by ID plus the array
    /// positions of shapes and vias, maintained O(delta) through the two
    /// document-mutation funnels (`commitDelta` and the mirror-drag path).
    /// Per-tick verbs and delta application never rescan the cell.
    var activeShapesByID: [UUID: LayoutShape] = [:]
    var activeShapeIndexByID: [UUID: Int] = [:]
    var activeViaIndexByID: [UUID: Int] = [:]
    var activeShapeCount = 0
    var activeViaCount = 0

    func rebuildActiveElementIndex() {
        // A structural change (undo, navigation, load) can invalidate the
        // entered in-place path; dropping it is the truthful reaction, not
        // editing through a dangling context.
        if !inPlaceInstancePath.isEmpty, resolveInPlacePath() == nil {
            inPlaceInstancePath = []
            inPlaceVerificationPending = false
            selectedShapeIDs.removeAll()
        }
        activeShapesByID = [:]
        activeShapeIndexByID = [:]
        activeViaIndexByID = [:]
        activeShapeCount = 0
        activeViaCount = 0
        guard let cellID = editTargetCellID,
              let cell = editor.document.cell(withID: cellID) else { return }
        activeShapeCount = cell.shapes.count
        activeViaCount = cell.vias.count
        activeShapesByID.reserveCapacity(cell.shapes.count)
        activeShapeIndexByID.reserveCapacity(cell.shapes.count)
        for (index, shape) in cell.shapes.enumerated() {
            activeShapesByID[shape.id] = shape
            activeShapeIndexByID[shape.id] = index
        }
        for (index, via) in cell.vias.enumerated() {
            activeViaIndexByID[via.id] = index
        }
    }

    /// Applies the delta to the document and keeps the active-element
    /// index in lockstep. Every document mutation that is expressible as
    /// a delta must go through here.
    func mutateDocument(_ delta: LayoutEditDelta, transient: Bool) throws {
        guard let cellID = editTargetCellID else { return }
        try validateDeltaAgainstActiveElements(delta)
        if transient {
            try editor.performTransient { doc in
                if isCellElementUpdateOnly(delta) {
                    try applyUpdateOnlyDelta(delta, to: &doc, cellID: cellID)
                } else {
                    try applyDelta(delta, to: &doc, cellID: cellID)
                }
            }
        } else if isCellElementUpdateOnly(delta),
                  let before = cellElementUpdateBeforeValues(delta, cellID: cellID) {
            editor.recordCellElementUpdate(
                cellID: cellID,
                beforeShapes: before.shapes,
                afterShapes: delta.updatedShapes,
                beforeVias: before.vias,
                afterVias: delta.updatedVias
            )
            try editor.performTransient { doc in
                try applyUpdateOnlyDelta(delta, to: &doc, cellID: cellID)
            }
        } else {
            try editor.perform { doc in
                try applyDelta(delta, to: &doc, cellID: cellID)
            }
        }
        for shape in delta.updatedShapes {
            activeShapesByID[shape.id] = shape
        }
        if delta.removedShapeIDs.isEmpty && delta.removedViaIDs.isEmpty {
            for (offset, shape) in delta.addedShapes.enumerated() {
                activeShapesByID[shape.id] = shape
                activeShapeIndexByID[shape.id] = activeShapeCount + offset
            }
            activeShapeCount += delta.addedShapes.count
            for (offset, via) in delta.addedVias.enumerated() {
                activeViaIndexByID[via.id] = activeViaCount + offset
            }
            activeViaCount += delta.addedVias.count
        } else {
            // Removals shift later array positions; rebuild the index in
            // one pass instead of tracking the shifts.
            rebuildActiveElementIndex()
        }
    }

    private func validateDeltaAgainstActiveElements(_ delta: LayoutEditDelta) throws {
        try delta.validateAgainstKnownElements(
            shapeIDs: Set(activeShapeIndexByID.keys),
            viaIDs: Set(activeViaIndexByID.keys)
        )
    }

    private func isCellElementUpdateOnly(_ delta: LayoutEditDelta) -> Bool {
        !delta.isEmpty
            && delta.addedShapes.isEmpty
            && delta.removedShapeIDs.isEmpty
            && delta.addedVias.isEmpty
            && delta.removedViaIDs.isEmpty
    }

    private func cellElementUpdateBeforeValues(
        _ delta: LayoutEditDelta,
        cellID: UUID
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        var beforeShapes: [LayoutShape] = []
        beforeShapes.reserveCapacity(delta.updatedShapes.count)
        for shape in delta.updatedShapes {
            guard let before = activeShapesByID[shape.id] else { return nil }
            beforeShapes.append(before)
        }

        var beforeVias: [LayoutVia] = []
        beforeVias.reserveCapacity(delta.updatedVias.count)
        if !delta.updatedVias.isEmpty {
            guard let cell = editor.document.cell(withID: cellID) else { return nil }
            for via in delta.updatedVias {
                guard let index = activeViaIndexByID[via.id],
                      cell.vias.indices.contains(index),
                      cell.vias[index].id == via.id else {
                    return nil
                }
                beforeVias.append(cell.vias[index])
            }
        }

        return (beforeShapes, beforeVias)
    }

    private func applyUpdateOnlyDelta(
        _ delta: LayoutEditDelta,
        to doc: inout LayoutDocument,
        cellID: UUID
    ) throws {
        guard let cellIndex = doc.cells.firstIndex(where: { $0.id == cellID }) else {
            throw LayoutCoreError.cellNotFound(cellID)
        }
        for shape in delta.updatedShapes {
            guard let index = activeShapeIndexByID[shape.id],
                  doc.cells[cellIndex].shapes.indices.contains(index),
                  doc.cells[cellIndex].shapes[index].id == shape.id else {
                throw LayoutCoreError.shapeNotFound(shape.id)
            }
            doc.cells[cellIndex].shapes[index] = shape
        }
        for via in delta.updatedVias {
            guard let index = activeViaIndexByID[via.id],
                  doc.cells[cellIndex].vias.indices.contains(index),
                  doc.cells[cellIndex].vias[index].id == via.id else {
                throw LayoutCoreError.viaNotFound(via.id)
            }
            doc.cells[cellIndex].vias[index] = via
        }
    }

    /// The level-of-detail draw plan for the current viewport, or `nil`
    /// when there is nothing to plan against — no active cell, or the
    /// canvas has not been laid out yet (zero size draws nothing, so
    /// `nil` is the truthful answer, not a fallback).
    public func currentRenderPlan(
        options: LayoutRenderPlan.Options = LayoutRenderPlan.Options()
    ) -> LayoutRenderPlan? {
        guard let renderIndex, zoom > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let viewport = LayoutRect(
            origin: LayoutPoint(
                x: Double(-offset.x / zoom),
                y: Double(-offset.y / zoom)
            ),
            size: LayoutSize(
                width: Double(canvasSize.width / zoom),
                height: Double(canvasSize.height / zoom)
            )
        )
        return renderIndex.plan(
            viewport: viewport,
            pixelsPerMicron: Double(zoom),
            options: options
        )
    }

    /// The draw plan for an arbitrary viewport and scale — the overview
    /// minimap plans at its own zoom through this.
    public func renderPlan(
        viewport: LayoutRect,
        pixelsPerMicron: Double,
        options: LayoutRenderPlan.Options = LayoutRenderPlan.Options()
    ) -> LayoutRenderPlan? {
        renderIndex?.plan(
            viewport: viewport,
            pixelsPerMicron: pixelsPerMicron,
            options: options
        )
    }

    /// Cheap content extent for overview framing: the render index's
    /// occupied-cell bounds, an over-approximation by at most one grid
    /// cell per side that never shrinks on removal until the next
    /// structural rebuild. Exact framing (``fitAll()``) keeps using
    /// ``contentBounds()``.
    public var renderContentBounds: LayoutRect? {
        renderIndex?.occupiedBounds
    }

    /// Anchors the net highlight to a shape; the highlighted net follows
    /// the conductor that shape belongs to as the layout changes.
    public func highlightNet(ofShape id: UUID) {
        netHighlightAnchor = .shape(id)
    }

    /// Anchors the net highlight to a via.
    public func highlightNet(ofVia id: UUID) {
        netHighlightAnchor = .via(id)
    }

    public func clearNetHighlight() {
        netHighlightAnchor = nil
    }

    /// Single choke point for geometry edits: applies the delta to the
    /// document and the live session with identical ordering semantics,
    /// keeping ``violations`` exact. Discrete edits re-verify the deferred
    /// antenna tier immediately; transient (gesture) edits defer it and
    /// report it via ``staleViolationKinds``.
    func commitDelta(_ delta: LayoutEditDelta, transient: Bool = false) {
        guard editTargetCellID != nil else { return }
        do {
            try mutateDocument(delta, transient: transient)
        } catch {
            handleError(error)
            return
        }

        if isEditingInPlace {
            // Child-space deltas cannot feed the top-context sessions.
            // Discrete edits re-verify exactly (full resync, fan-out to
            // all occurrences included); gesture ticks redraw immediately
            // and declare the verdicts stale until the gesture ends.
            if transient {
                inPlaceVerificationPending = true
                rebuildRenderIndex()
            } else {
                resyncAfterInPlaceEdit()
            }
            return
        }

        if let liveDRC {
            do {
                let update = try liveDRC.apply(delta)
                if transient {
                    violations = update.result.violations
                    staleViolationKinds = update.staleKinds
                } else if update.staleKinds.isEmpty {
                    violations = update.result.violations
                    staleViolationKinds = []
                } else {
                    violations = liveDRC.commit().violations
                    staleViolationKinds = []
                }
            } catch {
                // The document mutation succeeded but the session rejected
                // the delta — a programming error in delta construction.
                // Surface it and rebuild the session from the document so
                // the live snapshot stays truthful.
                handleError(error)
                resyncLiveDRC()
            }
        }
        applyConnectivityDelta(delta)
        applyConstraintDelta(delta)
        applyLVSDelta(delta)
        applyRenderIndexDelta(delta)
    }

    /// Applies a delta to the cell with the session's ordering semantics:
    /// updated elements keep their position, removed elements drop out,
    /// added elements append in delta order. Positions resolve through
    /// the active-element index — O(delta), no cell rescans.
    func applyDelta(
        _ delta: LayoutEditDelta,
        to doc: inout LayoutDocument,
        cellID: UUID
    ) throws {
        guard var cell = doc.cell(withID: cellID) else {
            throw LayoutCoreError.cellNotFound(cellID)
        }
        try applyShapeDelta(delta, to: &cell)
        try applyViaDelta(delta, to: &cell)
        doc.updateCell(cell)
    }

    private func applyShapeDelta(
        _ delta: LayoutEditDelta,
        to cell: inout LayoutCell
    ) throws {
        for shape in delta.updatedShapes {
            guard let index = activeShapeIndexByID[shape.id],
                  cell.shapes.indices.contains(index),
                  cell.shapes[index].id == shape.id else {
                throw LayoutCoreError.shapeNotFound(shape.id)
            }
            cell.shapes[index] = shape
        }
        if !delta.removedShapeIDs.isEmpty {
            for id in delta.removedShapeIDs {
                guard activeShapeIndexByID[id] != nil else {
                    throw LayoutCoreError.shapeNotFound(id)
                }
            }
            let removed = Set(delta.removedShapeIDs)
            cell.shapes.removeAll { removed.contains($0.id) }
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
    }

    private func applyViaDelta(
        _ delta: LayoutEditDelta,
        to cell: inout LayoutCell
    ) throws {
        for via in delta.updatedVias {
            guard let index = activeViaIndexByID[via.id],
                  cell.vias.indices.contains(index),
                  cell.vias[index].id == via.id else {
                throw LayoutCoreError.viaNotFound(via.id)
            }
            cell.vias[index] = via
        }
        if !delta.removedViaIDs.isEmpty {
            for id in delta.removedViaIDs {
                guard activeViaIndexByID[id] != nil else {
                    throw LayoutCoreError.viaNotFound(id)
                }
            }
            let removed = Set(delta.removedViaIDs)
            cell.vias.removeAll { removed.contains($0.id) }
        }
        cell.vias.append(contentsOf: delta.addedVias)
    }

    // MARK: - Undo / Redo

    public var canUndo: Bool { editor.canUndo }
    public var canRedo: Bool { editor.canRedo }

    public func undo() {
        editor.undo()
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }

    public func redo() {
        editor.redo()
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }

    // MARK: - Shape Creation

    public func addRectangle(from start: LayoutPoint, to end: LayoutPoint) {
        let start = editPoint(start)
        let end = editPoint(end)
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        let rect = LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
        let shape = LayoutShape(layer: activeLayer, geometry: .rect(rect))
        commitDelta(LayoutEditDelta(addedShapes: [shape]))
    }

    public func addPolygon(points: [LayoutPoint]) {
        let points = points.map(editPoint)
        let polygon = LayoutPolygon(points: points)
        guard polygon.isValid else { return }
        let shape = LayoutShape(layer: activeLayer, geometry: .polygon(polygon))
        commitDelta(LayoutEditDelta(addedShapes: [shape]))
    }

    public func addPath(points: [LayoutPoint]) {
        let points = points.map(editPoint)
        let path = LayoutPath(points: points, width: pathWidth, endCap: pathEndCap)
        guard path.isValid else { return }
        let shape = LayoutShape(layer: activeLayer, geometry: .path(path))
        commitDelta(LayoutEditDelta(addedShapes: [shape]))
    }

    public func addVia(at point: LayoutPoint) {
        let via = LayoutVia(viaDefinitionID: activeViaID, position: editPoint(point))
        commitDelta(LayoutEditDelta(addedVias: [via]))
    }

    public func addLabel(text: String, at point: LayoutPoint) {
        guard let cellID = editTargetCellID else { return }
        let label = LayoutLabel(text: text, position: editPoint(point), layer: activeLayer)
        do {
            try editor.addLabel(label, to: cellID)
        } catch {
            handleError(error)
            return
        }
        // Labels are structural annotations for extraction: LVS uses them
        // as island names, and live sessions cannot absorb them as a
        // geometry delta.
        resyncAfterAnnotationEdit()
    }

    public func addPin(name: String, at point: LayoutPoint, size: LayoutSize) {
        guard let cellID = editTargetCellID else { return }
        let pin = LayoutPin(name: name, position: editPoint(point), size: size, layer: activeLayer)
        do {
            try editor.addPin(pin, to: cellID)
        } catch {
            handleError(error)
            return
        }
        // Pins participate in connectivity checks but are structural for
        // the live sessions, so they require a rebuild rather than a delta.
        resyncAfterAnnotationEdit()
    }

    private func resyncAfterAnnotationEdit() {
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }
    // MARK: - Private Helpers

    public func clearError() {
        lastError = nil
    }

    func handleError(_ error: Error) {
        lastError = error.localizedDescription
    }


}
