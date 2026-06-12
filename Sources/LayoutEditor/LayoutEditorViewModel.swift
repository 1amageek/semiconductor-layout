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
    private var pendingFitAll = false
    public var gridSize: Double
    public var selectedShapeIDs: Set<UUID> = []
    public var selectedInstanceID: UUID?
    public var highlightedInstanceIDs: Set<UUID> = []
    public var violations: [LayoutViolation] = []
    public var lastError: String?
    public var hiddenLayers: Set<LayoutLayerID> = []
    public var cellNavigationPath: [UUID] = []

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
    public private(set) var staleViolationKinds: Set<LayoutViolationKind> = []

    /// How the last design-rule-driven drag proposal resolved, for canvas
    /// feedback while a drag is active.
    public private(set) var dragOutcome: DRDDragOutcome?

    private var liveDRC: IncrementalDRCSession?
    private var dragSession: DRDDragSession?
    private var dragOriginShapes: [LayoutShape]?
    /// Whether the active drag moves freshly added copies (Option-drag
    /// duplicate); cancel then removes the copies instead of restoring
    /// their positions.
    private var dragIsDuplicating = false

    // MARK: - Handle Editing State

    /// The handle currently being dragged, with the shape it belongs to,
    /// for canvas feedback. Non-nil exactly while a handle drag is active.
    public private(set) var activeHandleDrag: (shapeID: UUID, handle: LayoutShapeHandle)?
    private var handleOriginShape: LayoutShape?

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

    private var lvsReference: ComparisonNetlist?
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
    private var cellBackStack: [CellNavigationState] = []

    private struct CellNavigationState {
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
    private func resyncLiveDRC() {
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
    private func restartLiveDRC() {
        liveDRC = nil
        resyncLiveDRC()
    }

    // MARK: - Live Connectivity Plumbing

    /// (Re)builds the connectivity session from the current document and
    /// active cell. On failure the error is surfaced and the analysis
    /// becomes `nil` — unavailable, never silently stale.
    private func resyncLiveConnectivity() {
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
    private func restartLiveConnectivity() {
        liveConnectivity = nil
        resyncLiveConnectivity()
    }

    /// Applies a document delta to the connectivity session in lockstep.
    /// A rejected delta is a programming error in delta construction:
    /// surface it and rebuild so the analysis stays truthful.
    private func applyConnectivityDelta(_ delta: LayoutEditDelta) {
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
    private func refreshConstraintViolations() {
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
    private func applyConstraintDelta(_ delta: LayoutEditDelta) {
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

    private func resyncLiveLVS() {
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

    private func applyLVSDelta(_ delta: LayoutEditDelta) {
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

    // MARK: - Electrical (N4)

    /// Lumped R/C/tau estimate for a declared net's top-level geometry.
    /// nil when the net has no geometry; unavailable quantities inside
    /// the estimate stay nil (never zero).
    public func electricalEstimate(forNet netID: UUID) -> LayoutElectricalEstimate? {
        guard let cellID = editTargetCellID,
              let cell = editor.document.cell(withID: cellID) else { return nil }
        let shapes = cell.shapes.filter { $0.netID == netID }
        let vias = cell.vias.filter { $0.netID == netID }
        guard !shapes.isEmpty || !vias.isEmpty else { return nil }
        return LayoutElectricalEstimator(tech: tech).estimate(shapes: shapes, vias: vias)
    }

    /// Electromigration advisories: nets with a declared current spec
    /// whose narrowest modeled wire is under the layer's EM width
    /// requirement.
    public var electricalAdvisories: [String] {
        guard let cellID = editTargetCellID,
              let cell = editor.document.cell(withID: cellID) else { return [] }
        let estimator = LayoutElectricalEstimator(tech: tech)
        var advisories: [String] = []
        for net in cell.nets.sorted(by: { $0.name < $1.name }) {
            guard let current = net.currentSpec else { continue }
            let shapes = cell.shapes.filter { $0.netID == net.id }
            guard !shapes.isEmpty else { continue }
            let estimate = estimator.estimate(shapes: shapes, vias: [])
            guard let minimumWidth = estimate.minimumWireWidth else { continue }
            for layer in Set(shapes.map(\.layer)).sorted(by: { $0.name < $1.name }) {
                if let required = estimator.requiredWidth(forCurrent: current, layer: layer),
                   minimumWidth < required {
                    advisories.append(String(
                        format: "Net %@: %.3f um wire under the %.3f um EM width for %.1f mA on %@",
                        net.name, minimumWidth, required, current, layer.name
                    ))
                    break
                }
            }
        }
        return advisories
    }

    /// Live estimate of the route being drawn: the preview geometry plus
    /// the anchor net's existing conductors. nil when not routing or the
    /// tech models nothing.
    public func routeElectricalEstimate() -> LayoutElectricalEstimate? {
        guard techModelsElectrical,
              let preview = routePreview,
              !preview.delta.addedShapes.isEmpty else { return nil }
        var shapes = preview.delta.addedShapes
        var vias = preview.delta.addedVias
        if let netID = routeSession?.currentAnchor.netID,
           let cellID = editTargetCellID,
           let cell = editor.document.cell(withID: cellID) {
            shapes += cell.shapes.filter { $0.netID == netID }
            vias += cell.vias.filter { $0.netID == netID }
        }
        return LayoutElectricalEstimator(tech: tech).estimate(shapes: shapes, vias: vias)
    }

    /// Whether the technology models any electrical constants at all.
    private var techModelsElectrical: Bool {
        tech.layers.contains {
            $0.sheetResistance != nil || $0.areaCapacitance != nil
                || $0.fringeCapacitance != nil || $0.maxCurrentDensity != nil
        }
    }

    // MARK: - Trust report (N6)

    /// The live whole-picture verdict: per axis, clean / findings /
    /// explicitly unavailable — absence of verification is stated, never
    /// implied as clean.
    public var trustReport: LayoutTrustReport {
        let drc: LayoutTrustReport.AxisVerdict =
            violations.isEmpty ? .clean : .findings(violations.count)

        let connectivity: LayoutTrustReport.AxisVerdict
        if let analysis = connectivityAnalysis {
            let count = analysis.shorts.count + analysis.opens.count
            connectivity = count == 0 ? .clean : .findings(count)
        } else {
            connectivity = .unavailable("live connectivity is off")
        }

        let constraints: LayoutTrustReport.AxisVerdict
        if activeCellConstraints.isEmpty {
            constraints = .unavailable("no constraints declared")
        } else {
            constraints = constraintViolations.isEmpty
                ? .clean
                : .findings(constraintViolations.count)
        }

        let lvs: LayoutTrustReport.AxisVerdict
        if let comparison = lvsComparison {
            let count = comparison.unmatchedExtractedDevices.count
                + comparison.unmatchedReferenceDevices.count
                + comparison.parameterMismatches.count
                + (lvsExtraction?.issues.count ?? 0)
            lvs = count == 0 ? .clean : .findings(count)
        } else {
            lvs = .unavailable("no reference netlist loaded")
        }

        let electrical: LayoutTrustReport.AxisVerdict
        if techModelsElectrical {
            let advisories = electricalAdvisories
            electrical = advisories.isEmpty ? .clean : .findings(advisories.count)
        } else {
            electrical = .unavailable("no electrical constants in tech")
        }

        return LayoutTrustReport(
            drc: drc,
            staleDRCKinds: staleViolationKinds.map(\.rawValue).sorted(),
            connectivity: connectivity,
            constraints: constraints,
            lvs: lvs,
            electrical: electrical,
            verificationPending: inPlaceVerificationPending
        )
    }

    // MARK: - Goal commands (N5)

    /// Audit log of executed goal commands with their surrounding
    /// verdicts; replaying the same commands on the same document
    /// reproduces the same records.
    public private(set) var goalLog: [LayoutGoalRecord] = []

    /// Executes one goal command through the same implementations the
    /// keymap uses — the human/agent parity surface.
    @discardableResult
    public func execute(_ command: LayoutGoalCommand) -> Bool {
        let violationsBefore = violations.count
        let opensBefore = connectivityAnalysis?.opens.count ?? 0
        let lvsBefore = lvsComparison?.matchedReferenceDeviceCount ?? 0

        let succeeded: Bool
        switch command {
        case .fixAllViolations:
            let sweep = fixAllViolations()
            succeeded = sweep?.reachedFixedPoint ?? false
        case .finishNet(let netID):
            succeeded = finishNet(netID)
        case .finishAllNets:
            succeeded = finishAllNets() > 0 || connectivityAnalysis?.flylines.isEmpty == true
        case .annotateNetsFromLabels:
            succeeded = annotateNetsFromLabels() != nil
        case .placeIntentDevice(let deviceID, let point):
            if let device = unplacedIntentDevices.first(where: { $0.id == deviceID }) {
                armIntentPlacement(device)
                succeeded = placeArmedIntentDevice(at: point)
            } else {
                handleError(LayoutEditorError.intentDeviceNotFound(deviceID))
                succeeded = false
            }
        case .bindIntentTerminals:
            succeeded = (bindIntentTerminals() ?? 0) > 0
        case .setActiveLayer(let layer):
            activeLayer = layer
            succeeded = true
        }

        goalLog.append(LayoutGoalRecord(
            command: command,
            succeeded: succeeded,
            violationsBefore: violationsBefore,
            violationsAfter: violations.count,
            opensBefore: opensBefore,
            opensAfter: connectivityAnalysis?.opens.count ?? 0,
            lvsMatchedBefore: lvsBefore,
            lvsMatchedAfter: lvsComparison?.matchedReferenceDeviceCount ?? 0
        ))
        return succeeded
    }

    /// Replays a command sequence in order; stops at the first failure
    /// and reports whether every command succeeded.
    @discardableResult
    public func replay(_ commands: [LayoutGoalCommand]) -> Bool {
        for command in commands {
            guard execute(command) else { return false }
        }
        return true
    }

    // MARK: - SDL (N2)

    /// Outcome of the label→net annotation pass.
    public struct NetAnnotationSummary: Sendable, Equatable {
        public var netsCreated: Int
        public var shapesAnnotated: Int
        public var viasAnnotated: Int
        /// Instance terminals bound through `terminalNetIDs` because the
        /// labeled island lives inside an instance.
        public var terminalsBound: Int = 0
        /// Labels whose position touches no conductor on their layer.
        public var unmatchedLabels: [String]
        /// Child-occurrence conductors in annotated islands that a
        /// document edit cannot reach directly (their nets flow through
        /// the instance terminal binding instead).
        public var unreachableChildElements: Int
    }

    /// Derives net assignments from text labels — the bridge that makes
    /// an imported GDS (where every netID is nil) engage connectivity,
    /// opens/shorts and LVS. Each label names a net; the whole connected
    /// island under the label takes it. One undo unit.
    @discardableResult
    public func annotateNetsFromLabels() -> NetAnnotationSummary? {
        guard let cellID = editTargetCellID,
              let cell = editor.document.cell(withID: cellID) else { return nil }
        guard !cell.labels.isEmpty else {
            return NetAnnotationSummary(
                netsCreated: 0,
                shapesAnnotated: 0,
                viasAnnotated: 0,
                unmatchedLabels: [],
                unreachableChildElements: 0
            )
        }
        do {
            let analysis = try LayoutConnectivityExtractor().extract(
                document: editor.document,
                tech: tech,
                cellID: cellID
            )
            var summary = NetAnnotationSummary(
                netsCreated: 0,
                shapesAnnotated: 0,
                viasAnnotated: 0,
                unmatchedLabels: [],
                unreachableChildElements: 0
            )
            try editor.perform { doc in
                guard var cell = doc.cell(withID: cellID) else {
                    throw LayoutCoreError.cellNotFound(cellID)
                }
                var netIDByName = Dictionary(
                    cell.nets.map { ($0.name, $0.id) },
                    uniquingKeysWith: { first, _ in first }
                )
                let topShapeIDs = Set(cell.shapes.map(\.id))
                let topViaIDs = Set(cell.vias.map(\.id))

                // Labels may sit on FLATTENED geometry — a terminal bar
                // inside an instance — so candidates come from the same
                // flatten the connectivity analysis used. A child shape's
                // UUID repeats across occurrences; the label's position
                // against the island's bounding box disambiguates which
                // occurrence it names (far-apart occurrences in practice;
                // a genuinely ambiguous label is reported, not guessed).
                let flatShapes = try LayoutConnectivityExtractor()
                    .flattenedConductors(document: doc, tech: tech, cellID: cellID)
                    .shapes

                for label in cell.labels.sorted(by: { $0.text < $1.text }) {
                    let touchedIDs = Set(
                        flatShapes
                            .filter {
                                $0.layer == label.layer
                                    && LayoutGeometryAnalysis.contains(label.position, in: $0.geometry)
                            }
                            .map(\.id)
                    )
                    let candidates = analysis.nets.filter { net in
                        !touchedIDs.isDisjoint(with: net.shapeIDs)
                            && net.boundingBox.contains(label.position)
                    }
                    guard candidates.count == 1, let island = candidates.first else {
                        summary.unmatchedLabels.append(label.text)
                        continue
                    }
                    let netID: UUID
                    if let existing = netIDByName[label.text] {
                        netID = existing
                    } else {
                        let net = LayoutNet(name: label.text)
                        cell.nets.append(net)
                        netIDByName[label.text] = net.id
                        netID = net.id
                        summary.netsCreated += 1
                    }
                    var childShapeCount = 0
                    for shapeID in island.shapeIDs {
                        if topShapeIDs.contains(shapeID),
                           let index = cell.shapes.firstIndex(where: { $0.id == shapeID }) {
                            if cell.shapes[index].netID != netID {
                                cell.shapes[index].netID = netID
                                summary.shapesAnnotated += 1
                            }
                        } else {
                            childShapeCount += 1
                        }
                    }
                    for viaID in island.viaIDs {
                        if topViaIDs.contains(viaID),
                           let index = cell.vias.firstIndex(where: { $0.id == viaID }) {
                            if cell.vias[index].netID != netID {
                                cell.vias[index].netID = netID
                                summary.viasAnnotated += 1
                            }
                        } else {
                            childShapeCount += 1
                        }
                    }
                    // An island inside an instance has no editable shape;
                    // its net flows through the instance TERMINAL binding:
                    // every child pin sitting on the island gets bound, so
                    // flatten republishes the net on the pin and the
                    // connectivity tagging sees it. Child members count as
                    // unreachable only when no terminal carries their net.
                    var boundForIsland = 0
                    let islandShapeIDs = Set(island.shapeIDs)
                    for instanceIndex in cell.instances.indices {
                        let instance = cell.instances[instanceIndex]
                        guard let child = doc.cell(withID: instance.cellID) else { continue }
                        for occurrence in instance.occurrenceTransforms() {
                            for pin in child.pins {
                                let position = occurrence.apply(to: pin.position)
                                guard island.boundingBox.contains(position) else { continue }
                                let sitsOnIsland = flatShapes.contains { shape in
                                    islandShapeIDs.contains(shape.id)
                                        && shape.layer == pin.layer
                                        && LayoutGeometryAnalysis.contains(position, in: shape.geometry)
                                }
                                guard sitsOnIsland else { continue }
                                if cell.instances[instanceIndex].terminalNetIDs[pin.name] != netID {
                                    cell.instances[instanceIndex].terminalNetIDs[pin.name] = netID
                                    summary.terminalsBound += 1
                                }
                                boundForIsland += 1
                            }
                        }
                    }
                    if boundForIsland == 0 {
                        summary.unreachableChildElements += childShapeCount
                    }
                }
                doc.updateCell(cell)
            }
            resyncAfterInstanceEdit()
            return summary
        } catch {
            handleError(error)
            return nil
        }
    }

    /// The intent device armed for ghost placement; the next canvas click
    /// places it.
    public private(set) var pendingIntentDevice: ComparisonNetlist.Device?

    /// Reference devices the layout does not realize yet — the SDL
    /// "unplaced" list (empty when no reference is loaded).
    public var unplacedIntentDevices: [ComparisonNetlist.Device] {
        lvsComparison?.unmatchedReferenceDevices ?? []
    }

    public func armIntentPlacement(_ device: ComparisonNetlist.Device) {
        pendingIntentDevice = device
    }

    public func disarmIntentPlacement() {
        pendingIntentDevice = nil
    }

    /// Places the armed intent device at `point`: generates (or reuses) a
    /// parameter-exact device cell and instantiates it through the normal
    /// instance verb, so every live session follows. Returns whether the
    /// instance landed — intent MATCHING converges only once the device
    /// is wired, so placement success is judged here, not by the meter.
    @discardableResult
    public func placeArmedIntentDevice(at point: LayoutPoint) -> Bool {
        guard let device = pendingIntentDevice else { return false }
        pendingIntentDevice = nil
        do {
            let kindID: String
            switch device.kind {
            case .nmos: kindID = "nmos"
            case .pmos: kindID = "pmos"
            }
            let cellName = String(
                format: "%@_w%.3f_l%.3f_nf%d",
                kindID, device.parameters.width, device.parameters.length,
                device.parameters.multiplier
            )
            let deviceCellID: UUID
            if let existing = editor.document.cells.first(where: { $0.name == cellName }) {
                deviceCellID = existing.id
            } else {
                var generated = try MOSFETCellGenerator().generateCell(
                    deviceKindID: kindID,
                    instanceName: cellName,
                    parameters: [
                        "w": device.parameters.width,
                        "l": device.parameters.length,
                        "nf": Double(device.parameters.multiplier),
                    ],
                    tech: tech
                )
                generated.name = cellName
                let cell = generated
                editor.perform { doc in
                    doc.cells.append(cell)
                }
                deviceCellID = cell.id
            }
            let instanceCountBefore = editor.document
                .cell(withID: editTargetCellID ?? UUID())?.instances.count ?? 0
            placeInstance(cellID: deviceCellID, name: device.id, at: point)
            let instanceCountAfter = editor.document
                .cell(withID: editTargetCellID ?? UUID())?.instances.count ?? 0
            return instanceCountAfter == instanceCountBefore + 1
        } catch {
            handleError(error)
            return false
        }
    }

    /// Binds every placed intent instance's terminals to document nets
    /// named after the LVS reference — the label-less autonomy path: the
    /// reference already states which net each terminal belongs to, so
    /// an agent needs no text labels. Instances are matched to reference
    /// devices by name (placement names them after the device ID), pins
    /// to terminals by role. Nets are created or reused BY NAME, and the
    /// terminal map carries them through flatten into connectivity and
    /// LVS. Returns the number of newly bound terminals, or nil when no
    /// reference is loaded. One undo unit.
    @discardableResult
    public func bindIntentTerminals() -> Int? {
        guard let reference = lvsReference, let cellID = editTargetCellID else { return nil }
        var bound = 0
        editor.perform { doc in
            guard var cell = doc.cell(withID: cellID) else { return }
            var netIDByName = Dictionary(
                cell.nets.map { ($0.name, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            for device in reference.devices {
                for index in cell.instances.indices where cell.instances[index].name == device.id {
                    guard let child = doc.cell(withID: cell.instances[index].cellID) else { continue }
                    for pin in child.pins {
                        guard let role = ComparisonTerminalRole(rawValue: pin.role.rawValue),
                              let net = device.terminals[role],
                              net.rawValue.hasPrefix("pin:") else { continue }
                        let name = String(net.rawValue.dropFirst("pin:".count))
                        let netID: UUID
                        if let existing = netIDByName[name] {
                            netID = existing
                        } else {
                            let created = LayoutNet(name: name)
                            cell.nets.append(created)
                            netIDByName[name] = created.id
                            netID = created.id
                        }
                        if cell.instances[index].terminalNetIDs[pin.name] != netID {
                            cell.instances[index].terminalNetIDs[pin.name] = netID
                            bound += 1
                        }
                    }
                }
            }
            doc.updateCell(cell)
        }
        resyncAfterInstanceEdit()
        return bound
    }

    // MARK: - finish-net (N3)

    /// Completes one open of `netID` with the auto-route machinery,
    /// gated: the net's open count must shrink and DRC must not regress,
    /// else the commit is rolled back bit-exact. Surfaced errors carry
    /// the blocking reason; the document is never left half-routed.
    @discardableResult
    public func finishNet(_ netID: UUID) -> Bool {
        guard !isEditingInPlace else {
            handleError(LayoutEditorError.routingUnavailableInPlace)
            return false
        }
        guard let analysis = connectivityAnalysis,
              let open = analysis.opens.first(where: { $0.netID == netID }),
              let flyline = open.flylines.first else {
            handleError(LayoutEditorError.netAlreadyConnected(netID))
            return false
        }
        // The target is the ISLAND, not the flyline's corner point: the
        // nearest-point can sit inside foreign clearance while the rest
        // of the island is perfectly reachable. Footprints are occurrence
        // exact; resolving shapeIDs would alias reused child shapes onto
        // OTHER instances' geometry.
        var targetRegion: [LayoutRect] = []
        if open.islands.indices.contains(flyline.toIslandIndex) {
            targetRegion = open.islands[flyline.toIslandIndex].memberFootprints
                .filter { $0.layer == activeLayer }
                .map(\.boundingBox)
        }
        let flylinesBefore = analysis.flylines.count { $0.netID == netID }
        // DRC regression is judged by violation IDENTITY, not count: a
        // route that fixes two opens while creating one short would pass
        // a count check. The net's own residual open is exempt — its
        // member set changes with every leg, which would otherwise read
        // as a new violation on a multi-island net.
        let identitiesBefore = Set(violations.map(ViolationIdentity.init))

        // The goal-level route uses this layer's minimum legal width —
        // exactly, not the interactive default, which belongs to another
        // layer and can be thinner (illegal) or much fatter (its
        // clearance envelope walls off every landing).
        let savedPathWidth = pathWidth
        if let minWidth = tech.ruleSet(for: activeLayer)?.minWidth, minWidth > 0 {
            pathWidth = minWidth
        }
        defer { pathWidth = savedPathWidth }

        cancelRoute()
        beginRoute(at: flyline.start, netID: netID)
        guard isRouting else { return false }
        completeRoute(to: flyline.end, targetRegion: targetRegion)
        guard let preview = routePreview, preview.isLegal else {
            let reason: String
            if case .blockedByViolations(let blocking)? = routePreview?.stopReason,
               let first = blocking.first {
                reason = first.message
            } else {
                reason = "no clear path inside the search window"
            }
            cancelRoute()
            handleError(LayoutEditorError.finishNetBlocked(reason))
            return false
        }
        commitRoute()

        let flylinesAfter = connectivityAnalysis?.flylines.count { $0.netID == netID } ?? 0
        let regressed = violations.contains { violation in
            guard !identitiesBefore.contains(ViolationIdentity(of: violation)) else { return false }
            return !(violation.kind == .disconnectedOpen && violation.netIDs == [netID])
        }
        if flylinesAfter >= flylinesBefore || regressed {
            undo()
            handleError(LayoutEditorError.finishNetRegressed)
            return false
        }
        return true
    }

    /// Finishes every finishable open net to a fixed point. Nets that
    /// fail keep their surfaced reason and are skipped; the return value
    /// is the number of completed connections.
    @discardableResult
    public func finishAllNets(budget: Int = 64) -> Int {
        var completed = 0
        var failed: Set<UUID> = []
        for _ in 0..<budget {
            guard let flyline = connectivityAnalysis?.flylines.first(where: {
                !failed.contains($0.netID)
            }) else { break }
            if finishNet(flyline.netID) {
                completed += 1
            } else {
                failed.insert(flyline.netID)
            }
        }
        return completed
    }

    // MARK: - Repairs (N1)

    /// Computes a verified repair (or the typed reason none exists) for
    /// one current violation. Runs batch DRC mirrors internally — a
    /// user-initiated query, not a per-frame call.
    public func repairOutcome(for violation: LayoutViolation) -> LayoutRepairOutcome? {
        guard let cellID = editTargetCellID else { return nil }
        do {
            return try LayoutRepairEngine(
                document: editor.document,
                tech: tech,
                cellID: cellID
            ).repair(for: violation)
        } catch {
            handleError(error)
            return nil
        }
    }

    /// Applies a computed repair through the single edit stream (one undo
    /// unit; every live session follows).
    public func applyRepair(_ repair: LayoutRepair) {
        commitDelta(repair.delta)
    }

    /// Repairs every repairable violation to a fixed point and reports
    /// what was applied and what remains (with reasons). Each repair is
    /// one undo step, in application order.
    @discardableResult
    public func fixAllViolations(budget: Int = 64) -> LayoutRepairSweep? {
        guard let cellID = editTargetCellID else { return nil }
        do {
            let engine = LayoutRepairEngine(
                document: editor.document,
                tech: tech,
                cellID: cellID
            )
            let (repairs, sweep) = try engine.sweep(budget: budget)
            for repair in repairs {
                commitDelta(repair.delta)
            }
            return sweep
        } catch {
            handleError(error)
            return nil
        }
    }

    // MARK: - Focus / Navigation (N1 surfacing)

    /// Frames a micron-space rect in the canvas with padding.
    public func zoom(to rect: LayoutRect, padding: Double = 1.0) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let width = rect.size.width + 2 * padding
        let height = rect.size.height + 2 * padding
        guard width > 0, height > 0 else { return }
        let scale = min(
            Double(canvasSize.width) / width,
            Double(canvasSize.height) / height
        )
        zoom = CGFloat(min(max(scale, 0.01), 10_000))
        offset = CGPoint(
            x: -CGFloat(rect.minX - padding) * zoom
                + (canvasSize.width - CGFloat(width) * zoom) / 2,
            y: -CGFloat(rect.minY - padding) * zoom
                + (canvasSize.height - CGFloat(height) * zoom) / 2
        )
    }

    /// The violation currently focused by n/N cycling, highlighted on
    /// the canvas.
    public private(set) var focusedViolationID: UUID?

    /// Cycles canvas focus through the current violations (forward or
    /// backward), zooming to each — the triage loop.
    public func focusNextViolation(forward: Bool = true) {
        let all = violations
        guard !all.isEmpty else {
            focusedViolationID = nil
            return
        }
        let currentIndex = focusedViolationID.flatMap { id in
            all.firstIndex(where: { $0.id == id })
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + (forward ? 1 : all.count - 1)) % all.count
        } else {
            nextIndex = forward ? 0 : all.count - 1
        }
        let target = all[nextIndex]
        focusedViolationID = target.id
        zoom(to: target.region)
    }

    public func focusViolation(_ violation: LayoutViolation) {
        focusedViolationID = violation.id
        zoom(to: violation.region)
    }

    // MARK: - Interactive Routing

    /// DRC-enforced route drawing on the active layer. The session previews
    /// against its own incremental-DRC mirror; the document is untouched
    /// until ``commitRoute()`` pushes the legal shapes through the single
    /// edit stream.
    private var routeSession: InteractiveRouteSession?

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
    public func completeRoute(
        to target: LayoutPoint,
        windowMargin: Double = 2.0,
        targetRegion: [LayoutRect] = []
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
            step: max(gridSize, 0.01),
            targetRegion: targetRegion
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
    private func rebuildRenderIndex() {
        rebuildActiveElementIndex()
        guard activeCellID != nil else {
            renderIndex = nil
            return
        }
        renderIndex = LayoutRenderIndex(shapes: flattenedDocumentShapes())
    }

    // MARK: - Active-Element Index

    /// Current top-level shapes of the active cell by ID plus the array
    /// positions of shapes and vias, maintained O(delta) through the two
    /// document-mutation funnels (`commitDelta` and the mirror-drag path).
    /// Per-tick verbs and delta application never rescan the cell.
    private var activeShapesByID: [UUID: LayoutShape] = [:]
    private var activeShapeIndexByID: [UUID: Int] = [:]
    private var activeViaIndexByID: [UUID: Int] = [:]
    private var activeShapeCount = 0
    private var activeViaCount = 0

    private func rebuildActiveElementIndex() {
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
    private func mutateDocument(_ delta: LayoutEditDelta, transient: Bool) throws {
        guard let cellID = editTargetCellID else { return }
        if transient {
            try editor.performTransient { doc in
                try applyDelta(delta, to: &doc, cellID: cellID)
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
    private func commitDelta(_ delta: LayoutEditDelta, transient: Bool = false) {
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
        renderIndex?.apply(delta)
    }

    /// Applies a delta to the cell with the session's ordering semantics:
    /// updated elements keep their position, removed elements drop out,
    /// added elements append in delta order. Positions resolve through
    /// the active-element index — O(delta), no cell rescans.
    private func applyDelta(
        _ delta: LayoutEditDelta,
        to doc: inout LayoutDocument,
        cellID: UUID
    ) throws {
        guard var cell = doc.cell(withID: cellID) else {
            throw LayoutCoreError.cellNotFound(cellID)
        }
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
        doc.updateCell(cell)
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

    // MARK: - Cell Navigation

    public var activeCell: LayoutCell? {
        guard let activeCellID else { return nil }
        return editor.document.cell(withID: activeCellID)
    }

    public var breadcrumbCells: [LayoutCell] {
        let doc = editor.document
        return cellNavigationPath.compactMap { doc.cell(withID: $0) }
    }

    public var allCells: [LayoutCell] {
        editor.document.cells.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var canNavigateBack: Bool {
        !cellBackStack.isEmpty
    }

    public var canOpenSelectedInstanceCell: Bool {
        selectedInstanceTargetCellID() != nil
    }

    public func openCell(_ cellID: UUID) {
        navigate(to: cellID, path: bestPath(to: cellID), recordBack: true)
    }

    public func openSelectedInstanceCell() {
        guard let selectedTargetCellID = selectedInstanceTargetCellID() else { return }
        let nextPath: [UUID]
        if cellNavigationPath.last == activeCellID {
            nextPath = cellNavigationPath + [selectedTargetCellID]
        } else {
            nextPath = bestPath(to: selectedTargetCellID)
        }
        navigate(to: selectedTargetCellID, path: nextPath, recordBack: true)
    }

    public func placeInstance(cellID childCellID: UUID, name: String, at point: LayoutPoint) {
        guard let parentCellID = editTargetCellID else { return }
        guard canPlaceInstance(childCellID: childCellID, in: parentCellID) else {
            handleError(LayoutCoreError.instanceCycle(
                parentCellID: parentCellID,
                childCellID: childCellID
            ))
            return
        }
        let instance = LayoutInstance(
            cellID: childCellID,
            name: name,
            transform: LayoutTransform(
                translation: isEditingInPlace ? editPoint(point) : snapToGrid(point)
            )
        )
        do {
            try editor.addInstance(instance, to: parentCellID)
            selectedInstanceID = instance.id
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    public func moveSelectedInstance(by delta: LayoutPoint) {
        let delta = editVector(delta)
        transformSelectedInstance { transform in
            transform.translation = transform.translation.translated(by: snapToGrid(delta))
        }
    }

    public func rotateSelectedInstance(by degrees: Double = 90) {
        transformSelectedInstance { transform in
            transform.rotationDegrees += degrees
        }
    }

    public func mirrorSelectedInstance(x: Bool = true, y: Bool = false) {
        transformSelectedInstance { transform in
            if x { transform.mirrorX.toggle() }
            if y { transform.mirrorY.toggle() }
        }
    }

    public func explodeSelectedInstanceArray() {
        guard let hostCellID = editTargetCellID,
              let selectedInstanceID else { return }
        do {
            try editor.perform { doc in
                guard var cell = doc.cell(withID: hostCellID) else {
                    throw LayoutCoreError.cellNotFound(hostCellID)
                }
                guard let index = cell.instances.firstIndex(where: { $0.id == selectedInstanceID }) else {
                    throw LayoutCoreError.instanceNotFound(selectedInstanceID)
                }
                let instance = cell.instances[index]
                guard instance.repetition != nil else { return }
                let exploded = instance.occurrenceTransforms().enumerated().map { offset, transform in
                    LayoutInstance(
                        cellID: instance.cellID,
                        name: "\(instance.name)_\(offset)",
                        transform: transform,
                        terminalNetIDs: instance.terminalNetIDs
                    )
                }
                cell.instances.remove(at: index)
                cell.instances.insert(contentsOf: exploded, at: index)
                doc.updateCell(cell)
            }
            self.selectedInstanceID = nil
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    /// Materializes the selected instance into its host cell: the
    /// instance's entire subtree (shapes, vias, labels, pins; arrays
    /// expanded) lands as plain host content with FRESH identities —
    /// multi-instanced children share UUIDs that would collide once
    /// materialized side by side, so minting new IDs is explicit policy.
    /// One undo unit; the flattened document geometry is unchanged.
    public func flattenSelectedInstance() {
        guard let hostCellID = editTargetCellID, let selectedInstanceID else { return }
        do {
            try editor.perform { doc in
                guard var host = doc.cell(withID: hostCellID) else {
                    throw LayoutCoreError.cellNotFound(hostCellID)
                }
                guard let index = host.instances.firstIndex(where: { $0.id == selectedInstanceID }) else {
                    throw LayoutCoreError.instanceNotFound(selectedInstanceID)
                }
                let instance = host.instances[index]
                guard let child = doc.cell(withID: instance.cellID) else {
                    throw LayoutCoreError.cellNotFound(instance.cellID)
                }
                var content = FlattenedContent()
                for transform in instance.occurrenceTransforms() {
                    Self.collectFlattenedContent(
                        of: child,
                        in: doc,
                        transforms: [transform],
                        depth: 0,
                        into: &content
                    )
                }
                host.shapes.append(contentsOf: content.shapes)
                host.vias.append(contentsOf: content.vias)
                host.labels.append(contentsOf: content.labels)
                host.pins.append(contentsOf: content.pins)
                host.instances.remove(at: index)
                doc.updateCell(host)
            }
            self.selectedInstanceID = nil
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    /// Replaces the selected shapes with a new cell plus an
    /// identity-transform instance of it — the inverse of flatten for a
    /// same-cell selection. The shapes keep their geometry and identities
    /// inside the new cell, so the flattened document is unchanged.
    @discardableResult
    public func makeCellFromSelection(name: String) -> UUID? {
        guard let hostCellID = editTargetCellID else { return nil }
        let shapes = selectedShapes()
        guard !shapes.isEmpty else { return nil }
        var newInstanceID: UUID?
        var newCellID: UUID?
        do {
            try editor.perform { doc in
                guard var host = doc.cell(withID: hostCellID) else {
                    throw LayoutCoreError.cellNotFound(hostCellID)
                }
                let ids = Set(shapes.map(\.id))
                let newCell = LayoutCell(name: name, shapes: shapes)
                let instance = LayoutInstance(cellID: newCell.id, name: name)
                host.shapes.removeAll { ids.contains($0.id) }
                host.instances.append(instance)
                doc.cells.append(newCell)
                doc.updateCell(host)
                newInstanceID = instance.id
                newCellID = newCell.id
            }
        } catch {
            handleError(error)
            return nil
        }
        selectedShapeIDs.removeAll()
        selectedInstanceID = newInstanceID
        resyncAfterInstanceEdit()
        return newCellID
    }

    private struct FlattenedContent {
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var labels: [LayoutLabel] = []
        var pins: [LayoutPin] = []
    }

    /// Deep flatten of one cell subtree with fresh identities. Transform
    /// composition matches the verification flatten: geometry through the
    /// chain innermost-first; via/label/pin positions point-transformed
    /// (a via's cut is its definition's, so only its anchor moves — the
    /// same convention every verification flatten in this package uses).
    private static func collectFlattenedContent(
        of cell: LayoutCell,
        in document: LayoutDocument,
        transforms: [LayoutTransform],
        terminalNetIDs: [String: UUID] = [:],
        depth: Int,
        into content: inout FlattenedContent
    ) {
        guard depth < 10 else { return }
        func mapPoint(_ point: LayoutPoint) -> LayoutPoint {
            var mapped = point
            for transform in transforms.reversed() {
                mapped = transform.apply(to: mapped)
            }
            return mapped
        }
        for shape in cell.shapes {
            var geometry = shape.geometry
            for transform in transforms.reversed() {
                geometry = geometry.transformed(by: transform)
            }
            content.shapes.append(LayoutShape(
                layer: shape.layer,
                netID: shape.netID,
                geometry: geometry,
                properties: shape.properties
            ))
        }
        for via in cell.vias {
            content.vias.append(LayoutVia(
                viaDefinitionID: via.viaDefinitionID,
                position: mapPoint(via.position),
                netID: via.netID
            ))
        }
        for label in cell.labels {
            content.labels.append(LayoutLabel(
                text: label.text,
                position: mapPoint(label.position),
                layer: label.layer
            ))
        }
        for pin in cell.pins {
            content.pins.append(LayoutPin(
                name: pin.name,
                position: mapPoint(pin.position),
                size: pin.size,
                layer: pin.layer,
                // The instance terminal binding overrides the child
                // pin's own net at this occurrence — same semantics as
                // the connectivity flatten.
                netID: terminalNetIDs[pin.name] ?? pin.netID,
                role: pin.role
            ))
        }
        for instance in cell.instances {
            guard let child = document.cell(withID: instance.cellID) else { continue }
            for occurrence in instance.occurrenceTransforms() {
                collectFlattenedContent(
                    of: child,
                    in: document,
                    transforms: transforms + [occurrence],
                    terminalNetIDs: instance.terminalNetIDs,
                    depth: depth + 1,
                    into: &content
                )
            }
        }
    }

    public func navigateToBreadcrumb(index: Int) {
        guard index >= 0, index < cellNavigationPath.count else { return }
        let nextPath = Array(cellNavigationPath.prefix(index + 1))
        guard let targetCellID = nextPath.last else { return }
        navigate(to: targetCellID, path: nextPath, recordBack: true)
    }

    public func navigateBack() {
        guard let previous = cellBackStack.popLast() else { return }
        restoreNavigationState(previous)
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
        }
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
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        rebuildRenderIndex()
    }

    // MARK: - Rulers

    public func addRuler(from start: LayoutPoint, to end: LayoutPoint) {
        rulers.append(LayoutRuler(start: start, end: end))
    }

    public func clearAllRulers() {
        rulers.removeAll()
    }

    // MARK: - Edit In Place

    /// Instance path from the viewed (active) cell down to the in-place
    /// edit target; empty when editing the active cell itself. Editing
    /// verbs target the resolved child cell while the canvas keeps the
    /// parent context on screen.
    public private(set) var inPlaceInstancePath: [UUID] = []

    public var isEditingInPlace: Bool { !inPlaceInstancePath.isEmpty }

    /// True while an in-place gesture has redrawn the canvas but the
    /// verification verdicts on screen still describe the pre-gesture
    /// geometry. Cleared by the full resync at gesture end.
    public private(set) var inPlaceVerificationPending = false

    /// The cell that editing verbs and selection operate on: the in-place
    /// child when a context is entered, otherwise the active cell.
    public var editTargetCellID: UUID? {
        resolveInPlacePath()?.targetCellID ?? activeCellID
    }

    private struct InPlaceResolution {
        var targetCellID: UUID
        /// Outermost-first transforms of the entered occurrence chain.
        var transforms: [LayoutTransform]
    }

    private func resolveInPlacePath() -> InPlaceResolution? {
        guard !inPlaceInstancePath.isEmpty, var cellID = activeCellID else { return nil }
        var transforms: [LayoutTransform] = []
        for instanceID in inPlaceInstancePath {
            guard let cell = editor.document.cell(withID: cellID),
                  let instance = cell.instances.first(where: { $0.id == instanceID }) else {
                return nil
            }
            transforms.append(instance.transform)
            cellID = instance.cellID
        }
        return InPlaceResolution(targetCellID: cellID, transforms: transforms)
    }

    /// Descends the edit context into one instance of the current edit
    /// target. The viewed cell stays on screen; pointer input is mapped
    /// through the occurrence chain into the child's coordinate space.
    public func enterInPlaceEdit(instanceID: UUID) {
        guard let hostCellID = editTargetCellID,
              let host = editor.document.cell(withID: hostCellID),
              let instance = host.instances.first(where: { $0.id == instanceID }) else {
            handleError(LayoutCoreError.instanceNotFound(instanceID))
            return
        }
        guard instance.repetition == nil else {
            handleError(LayoutEditorError.arrayedInstanceEditInPlace(instanceID))
            return
        }
        guard instance.transform.magnification != 0 else {
            handleError(LayoutEditorError.degenerateInstanceTransform(instanceID))
            return
        }
        cancelRoute()
        inPlaceInstancePath.append(instanceID)
        clearSelection()
        rebuildActiveElementIndex()
    }

    /// Ascends one level of the in-place context.
    public func exitInPlaceEdit() {
        guard isEditingInPlace else { return }
        inPlaceInstancePath.removeLast()
        clearSelection()
        rebuildActiveElementIndex()
        if inPlaceVerificationPending {
            resyncAfterInPlaceEdit()
        }
    }

    /// View-space point → edit-target local space, through the inverse of
    /// the occurrence chain. Identity outside an in-place context.
    public func mapToEditSpace(_ point: LayoutPoint) -> LayoutPoint {
        guard let resolution = resolveInPlacePath() else { return point }
        var mapped = point
        for transform in resolution.transforms {
            mapped = transform.inverseApply(to: mapped)
        }
        return mapped
    }

    /// Edit-target local point → view space, for selection overlays.
    public func mapFromEditSpace(_ point: LayoutPoint) -> LayoutPoint {
        guard let resolution = resolveInPlacePath() else { return point }
        var mapped = point
        for transform in resolution.transforms.reversed() {
            mapped = transform.apply(to: mapped)
        }
        return mapped
    }

    /// View-space direction → edit-target direction (linear part only).
    public func mapVectorToEditSpace(_ vector: LayoutPoint) -> LayoutPoint {
        let origin = mapToEditSpace(.zero)
        let tip = mapToEditSpace(vector)
        return LayoutPoint(x: tip.x - origin.x, y: tip.y - origin.y)
    }

    /// Canvas input point in the space editing verbs operate in. Inside
    /// an in-place context the point is mapped first and snapped on the
    /// CHILD's grid — one composed transform per point, so there is no
    /// view-then-child double rounding.
    private func editPoint(_ point: LayoutPoint) -> LayoutPoint {
        isEditingInPlace ? snapToGrid(mapToEditSpace(point)) : point
    }

    private func editVector(_ vector: LayoutPoint) -> LayoutPoint {
        isEditingInPlace ? mapVectorToEditSpace(vector) : vector
    }

    /// Child-space deltas are not expressible to the top-context live
    /// sessions, so an in-place edit re-derives them from the document.
    /// The fan-out to every occurrence of the edited cell is exact: the
    /// sessions flatten the viewed cell, which contains them all.
    private func resyncAfterInPlaceEdit() {
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
        inPlaceVerificationPending = false
    }

    // MARK: - Selection

    public func selectShape(at point: LayoutPoint) {
        guard let cellID = editTargetCellID, let cell = editor.document.cell(withID: cellID) else {
            return
        }
        let local = isEditingInPlace ? mapToEditSpace(point) : point
        for shape in cell.shapes.reversed() {
            guard isLayerVisible(shape.layer) else { continue }
            if LayoutGeometryAnalysis.contains(local, in: shape.geometry) {
                selectedShapeIDs = [shape.id]
                selectedInstanceID = nil
                return
            }
        }
        if let instID = selectInstance(at: point) {
            selectedInstanceID = instID
            selectedShapeIDs.removeAll()
            return
        }
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
    }

    /// Selects shapes by marquee box. Window mode selects shapes whose
    /// bounding box lies entirely inside the box; crossing mode selects
    /// shapes whose bounding box intersects it. Hidden layers never
    /// participate. With `additive`, hits join the current selection
    /// instead of replacing it.
    public func selectShapes(in box: LayoutRect, mode: LayoutMarqueeMode, additive: Bool = false) {
        guard let cellID = editTargetCellID, let cell = editor.document.cell(withID: cellID) else {
            return
        }
        // Inside an in-place context the marquee corners are mapped into
        // the child space; under a rotated occurrence the box becomes the
        // bounding box of the mapped corners.
        let box = isEditingInPlace ? Self.boundingBox(
            of: [
                mapToEditSpace(LayoutPoint(x: box.minX, y: box.minY)),
                mapToEditSpace(LayoutPoint(x: box.maxX, y: box.minY)),
                mapToEditSpace(LayoutPoint(x: box.maxX, y: box.maxY)),
                mapToEditSpace(LayoutPoint(x: box.minX, y: box.maxY)),
            ]
        ) : box
        var hits: Set<UUID> = []
        for shape in cell.shapes {
            guard isLayerVisible(shape.layer) else { continue }
            let bounds = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            let matched: Bool
            switch mode {
            case .window:
                matched = box.minX <= bounds.minX && box.minY <= bounds.minY
                    && box.maxX >= bounds.maxX && box.maxY >= bounds.maxY
            case .crossing:
                matched = box.intersects(bounds)
            }
            if matched {
                hits.insert(shape.id)
            }
        }
        if additive {
            selectedShapeIDs.formUnion(hits)
        } else {
            selectedShapeIDs = hits
        }
        if !additive || !hits.isEmpty {
            selectedInstanceID = nil
        }
    }

    public func selectInstance(at point: LayoutPoint) -> UUID? {
        let local = isEditingInPlace ? mapToEditSpace(point) : point
        for (inst, bounds) in instanceBoundingBoxes(in: editTargetCellID) {
            if bounds.contains(local) {
                return inst.id
            }
        }
        return nil
    }

    public func instanceBoundingBoxes() -> [(instance: LayoutInstance, bounds: LayoutRect)] {
        instanceBoundingBoxes(in: activeCellID)
    }

    private func instanceBoundingBoxes(
        in cellID: UUID?
    ) -> [(instance: LayoutInstance, bounds: LayoutRect)] {
        guard let cellID,
              let cell = editor.document.cell(withID: cellID) else { return [] }
        return cell.instances.compactMap { inst in
            guard let refCell = editor.document.cell(withID: inst.cellID) else { return nil }
            let localBounds = Self.cellBoundingBox(refCell)
            guard localBounds.size.width > 0, localBounds.size.height > 0 else { return nil }
            let transformedBounds = inst.occurrenceTransforms()
                .map { Self.transformRect(localBounds, by: $0) }
                .reduce(nil as LayoutRect?) { partial, box in
                    partial.map { $0.union(box) } ?? box
                }
            guard let transformedBounds else { return nil }
            return (inst, transformedBounds)
        }
    }

    /// The shapes editing and selection operate on. Inside an in-place
    /// context these are the EDIT TARGET cell's shapes with their geometry
    /// mapped into view space through the entered occurrence chain, so the
    /// canvas's selection drawing, handle hit-testing and drag pickup work
    /// unchanged; the IDs stay the child cell's real shape IDs.
    public func documentShapes() -> [LayoutShape] {
        if let resolution = resolveInPlacePath() {
            guard let cell = editor.document.cell(withID: resolution.targetCellID) else {
                return []
            }
            return cell.shapes.map { shape in
                var mapped = shape
                for transform in resolution.transforms.reversed() {
                    mapped.geometry = mapped.geometry.transformed(by: transform)
                }
                return mapped
            }
        }
        guard let cellID = activeCellID, let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        return cell.shapes
    }

    public func documentVias() -> [LayoutVia] {
        guard let cellID = activeCellID, let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        return cell.vias
    }

    /// All pins of the active cell hierarchy at their flattened positions
    /// — the terminals a wiring or SDL flow targets.
    public func flattenedDocumentPins() -> [LayoutPin] {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        var content = FlattenedContent()
        Self.collectFlattenedContent(
            of: cell,
            in: editor.document,
            transforms: [],
            depth: 0,
            into: &content
        )
        return content.pins
    }

    /// Returns all shapes from the active cell hierarchy, recursively flattening
    /// instance references with their transforms applied.
    public func flattenedDocumentShapes() -> [LayoutShape] {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        return flattenShapes(cell: cell, transforms: [], depth: 0)
    }

    private func flattenShapes(
        cell: LayoutCell,
        transforms: [LayoutTransform],
        depth: Int
    ) -> [LayoutShape] {
        guard depth < 10 else { return [] }
        var result: [LayoutShape] = []

        for shape in cell.shapes {
            if transforms.isEmpty {
                result.append(shape)
            } else {
                var geo = shape.geometry
                for t in transforms {
                    geo = geo.transformed(by: t)
                }
                result.append(LayoutShape(layer: shape.layer, geometry: geo))
            }
        }

        for inst in cell.instances {
            guard let refCell = editor.document.cell(withID: inst.cellID) else { continue }
            for occurrenceTransform in inst.occurrenceTransforms() {
                result.append(contentsOf: flattenShapes(
                    cell: refCell,
                    transforms: [occurrenceTransform] + transforms,
                    depth: depth + 1
                ))
            }
        }

        return result
    }

    // MARK: - Move Selected Shapes

    /// Moves the selection by a vector as one discrete, ID-preserving
    /// edit — the path for keyboard nudges and programmatic moves.
    /// Interactive drags go through ``beginShapeDrag()`` /
    /// ``updateShapeDrag(to:)`` / ``endShapeDrag()`` instead.
    public func moveSelectedShapes(by delta: LayoutPoint) {
        let delta = editVector(delta)
        let moved = selectedShapes().map { shape in
            var copy = shape
            copy.geometry = shape.geometry.translated(by: delta)
            return copy
        }
        guard !moved.isEmpty else { return }
        commitDelta(LayoutEditDelta(updatedShapes: moved))
    }

    private func selectedShapes() -> [LayoutShape] {
        guard !selectedShapeIDs.isEmpty else { return [] }
        // Resolved through the active-element index instead of scanning
        // the cell; canonical ID order keeps multi-select verbs
        // deterministic (sessions treat delta arrays as sets).
        return selectedShapeIDs
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { activeShapesByID[$0] }
    }

    // MARK: - Duplicate / Rotate / Mirror

    /// Duplicates the selection offset by one grid step on each axis —
    /// the default placement for the keyboard and menu duplicate commands.
    public func duplicateSelectedShapesByGridStep() {
        duplicateSelectedShapes(by: LayoutPoint(x: gridSize, y: gridSize))
    }

    /// Copies the selection, offset by a vector, as one discrete edit.
    /// The copies get fresh identities but keep their net assignment, so
    /// a copied labeled wire honestly reports as an open until it is
    /// wired up. Selection moves to the copies that landed.
    public func duplicateSelectedShapes(by offset: LayoutPoint) {
        let offset = editVector(offset)
        let copies = selectedShapes().map { shape in
            LayoutShape(
                layer: shape.layer,
                netID: shape.netID,
                geometry: shape.geometry.translated(by: offset),
                properties: shape.properties
            )
        }
        guard !copies.isEmpty else { return }
        commitDelta(LayoutEditDelta(addedShapes: copies))
        // commitDelta reports failures through handleError without
        // applying — intersect with the document so the selection only
        // ever names shapes that actually exist.
        let landed = Set(documentShapes().map(\.id))
        selectedShapeIDs = Set(copies.map(\.id)).intersection(landed)
        selectedInstanceID = nil
    }

    /// Rotates the selection a quarter turn about the grid-snapped center
    /// of its combined bounding box, preserving shape identity.
    public func rotateSelectedShapes(clockwise: Bool = true) {
        transformSelectedShapes { geometry, pivot in
            geometry.rotated90(around: pivot, clockwise: clockwise)
        }
    }

    /// Mirrors the selection across an axis through the grid-snapped
    /// center of its combined bounding box, preserving shape identity.
    public func mirrorSelectedShapes(across axis: LayoutMirrorAxis) {
        transformSelectedShapes { geometry, pivot in
            geometry.mirrored(across: axis, through: pivot)
        }
    }

    /// Applies an ID-preserving geometric transform about the selection's
    /// grid-snapped bounding-box center as one discrete edit.
    private func transformSelectedShapes(
        _ transform: (LayoutGeometry, LayoutPoint) -> LayoutGeometry
    ) {
        let shapes = selectedShapes()
        guard let first = shapes.first else { return }
        var combined = LayoutGeometryAnalysis.boundingBox(for: first.geometry)
        for shape in shapes.dropFirst() {
            combined = combined.union(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
        let pivot = snapToGrid(combined.center)
        let updated = shapes.map { shape in
            var copy = shape
            copy.geometry = transform(shape.geometry, pivot)
            return copy
        }
        commitDelta(LayoutEditDelta(updatedShapes: updated))
    }

    // MARK: - Interactive Drag (DRD)

    /// Whether an interactive shape drag is in progress.
    public var isDraggingShapes: Bool { dragOriginShapes != nil }

    /// Starts an interactive drag of the selected shapes. The whole drag
    /// collapses into one undo step; in `observe`/`enforce` mode every
    /// tick re-verifies through the live session.
    ///
    /// With `duplicating` (Option-drag), fresh copies of the selection are
    /// added in place and the drag moves the copies while the originals
    /// stay put. Copies keep their net assignment, so a copied labeled
    /// wire honestly reports as an open until it is wired up.
    public func beginShapeDrag(duplicating: Bool = false) {
        guard dragOriginShapes == nil, activeHandleDrag == nil else { return }
        let shapes = selectedShapes()
        guard !shapes.isEmpty else { return }
        editor.recordUndoBoundary()
        var dragged = shapes
        if duplicating {
            let copies = shapes.map { shape in
                LayoutShape(
                    layer: shape.layer,
                    netID: shape.netID,
                    geometry: shape.geometry,
                    properties: shape.properties
                )
            }
            commitDelta(LayoutEditDelta(addedShapes: copies), transient: true)
            // commitDelta reports failures through handleError without
            // applying — only start the drag if the copies actually landed.
            let copyIDs = Set(copies.map(\.id))
            guard copyIDs.isSubset(of: Set(documentShapes().map(\.id))) else { return }
            selectedShapeIDs = copyIDs
            dragged = copies
            dragIsDuplicating = true
        }
        dragOriginShapes = dragged
        // The DRD session verifies against the top-context DRC mirror,
        // which cannot take child-space deltas; in-place drags fall back
        // to the plain path with verification deferred to the gesture end.
        if !isEditingInPlace, let liveDRC {
            dragSession = DRDDragSession(session: liveDRC, shapes: dragged, grid: gridSize)
        }
    }

    /// Moves the drag to a cumulative offset from the drag origin. In
    /// enforce mode the offset may resolve to the closest legal position;
    /// the resolution is reported via ``dragOutcome``.
    public func updateShapeDrag(to offset: LayoutPoint) {
        guard let origin = dragOriginShapes else { return }
        let applied: LayoutPoint
        if let dragSession {
            do {
                let resolution = try dragSession.propose(
                    offset: offset,
                    enforce: drdMode == .enforce
                )
                violations = resolution.result.violations
                staleViolationKinds = liveDRC?.staleKinds ?? []
                dragOutcome = resolution.outcome
                applied = resolution.appliedOffset
            } catch {
                handleError(error)
                resyncLiveDRC()
                return
            }
        } else {
            applied = snapToGrid(editVector(offset))
        }
        mirrorDragOffset(applied, origin: origin)
    }

    /// Ends the drag at its current position and re-verifies the deferred
    /// tier so the snapshot is exact again.
    public func endShapeDrag() {
        guard dragOriginShapes != nil else { return }
        dragOriginShapes = nil
        dragSession = nil
        dragOutcome = nil
        dragIsDuplicating = false
        if isEditingInPlace {
            resyncAfterInPlaceEdit()
        } else if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        }
    }

    /// Aborts the drag. A move drag restores the dragged shapes to their
    /// origin; a duplicating drag removes the copies it added.
    public func cancelShapeDrag() {
        guard let origin = dragOriginShapes else { return }
        if let dragSession {
            do {
                violations = try dragSession.cancel().violations
                staleViolationKinds = liveDRC?.staleKinds ?? []
            } catch {
                handleError(error)
                resyncLiveDRC()
            }
        }
        if dragIsDuplicating {
            commitDelta(LayoutEditDelta(removedShapeIDs: origin.map(\.id)), transient: true)
            selectedShapeIDs.subtract(origin.map(\.id))
        } else {
            mirrorDragOffset(.zero, origin: origin)
        }
        dragOriginShapes = nil
        dragSession = nil
        dragOutcome = nil
        dragIsDuplicating = false
        if isEditingInPlace {
            resyncAfterInPlaceEdit()
        } else if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        }
    }

    /// Mirrors the drag position into the document as a transient edit so
    /// the canvas renders from the same state the live session verified.
    private func mirrorDragOffset(_ offset: LayoutPoint, origin: [LayoutShape]) {
        guard let cellID = editTargetCellID else { return }
        let moved = origin.map { shape in
            var copy = shape
            copy.geometry = shape.geometry.translated(by: offset)
            return copy
        }
        do {
            try editor.performTransient { doc in
                try applyDelta(LayoutEditDelta(updatedShapes: moved), to: &doc, cellID: cellID)
            }
            for shape in moved {
                activeShapesByID[shape.id] = shape
            }
        } catch {
            handleError(error)
            return
        }
        if isEditingInPlace {
            // Child-space ticks redraw the fan-out immediately; the
            // verdicts are declared stale until the gesture ends.
            inPlaceVerificationPending = true
            rebuildRenderIndex()
            return
        }
        // The DRC side of the drag verifies through DRDDragSession; the
        // connectivity, constraint, and render-index views follow the
        // document directly so they stay live during the gesture.
        applyConnectivityDelta(LayoutEditDelta(updatedShapes: moved))
        applyConstraintDelta(LayoutEditDelta(updatedShapes: moved))
        applyLVSDelta(LayoutEditDelta(updatedShapes: moved))
        renderIndex?.apply(LayoutEditDelta(updatedShapes: moved))
    }

    // MARK: - Handle Editing (Stretch / Vertex)

    /// Whether a handle drag is in progress.
    public var isDraggingHandle: Bool { activeHandleDrag != nil }

    /// Starts dragging one handle of a shape — the stretch/vertex-edit
    /// gesture. The whole drag collapses into one undo step and every
    /// tick verifies through the live sessions. Returns false when the
    /// handle does not exist on that shape's geometry.
    @discardableResult
    public func beginHandleDrag(shapeID: UUID, handle: LayoutShapeHandle) -> Bool {
        guard activeHandleDrag == nil, dragOriginShapes == nil else { return false }
        guard let cellID = editTargetCellID,
              let cell = editor.document.cell(withID: cellID),
              let shape = cell.shapes.first(where: { $0.id == shapeID }) else { return false }
        // Validate the handle against the geometry before recording any
        // gesture state.
        guard LayoutHandleEditor.apply(
            handle, offset: .zero, to: shape.geometry, minimumSize: gridSize
        ) != nil else { return false }
        editor.recordUndoBoundary()
        activeHandleDrag = (shapeID: shapeID, handle: handle)
        handleOriginShape = shape
        return true
    }

    /// Moves the dragged handle to a cumulative offset from the gesture
    /// origin. The geometry is recomputed from the origin shape each tick
    /// so the drag is replayable and cancel restores exactly.
    public func updateHandleDrag(to offset: LayoutPoint) {
        guard let drag = activeHandleDrag, let origin = handleOriginShape else { return }
        guard let geometry = LayoutHandleEditor.apply(
            drag.handle,
            offset: snapToGrid(editVector(offset)),
            to: origin.geometry,
            minimumSize: gridSize
        ) else { return }
        var moved = origin
        moved.geometry = geometry
        commitDelta(LayoutEditDelta(updatedShapes: [moved]), transient: true)
    }

    /// Ends the handle drag at its current geometry and re-verifies the
    /// deferred tier so the snapshot is exact again.
    public func endHandleDrag() {
        guard activeHandleDrag != nil else { return }
        activeHandleDrag = nil
        handleOriginShape = nil
        if isEditingInPlace {
            resyncAfterInPlaceEdit()
        } else if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        }
    }

    /// Aborts the handle drag and restores the shape's origin geometry.
    public func cancelHandleDrag() {
        guard activeHandleDrag != nil, let origin = handleOriginShape else { return }
        activeHandleDrag = nil
        handleOriginShape = nil
        commitDelta(LayoutEditDelta(updatedShapes: [origin]), transient: true)
        if isEditingInPlace {
            resyncAfterInPlaceEdit()
        } else if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        }
    }

    // MARK: - Merge

    /// Merges all selected shapes on the same layer into polygons by
    /// computing their union. All layers merge as one edit: one undo step,
    /// one live verification.
    public func mergeSelectedShapes() {
        guard let cellID = activeCellID, !selectedShapeIDs.isEmpty else { return }
        guard let cell = editor.document.cell(withID: cellID) else { return }

        // Group selected shapes by layer
        var shapesByLayer: [LayoutLayerID: [LayoutShape]] = [:]
        for shape in cell.shapes where selectedShapeIDs.contains(shape.id) {
            shapesByLayer[shape.layer, default: []].append(shape)
        }

        var removedIDs: [UUID] = []
        var addedShapes: [LayoutShape] = []

        for (layer, shapes) in shapesByLayer {
            guard shapes.count >= 2 else { continue }

            // Collect the mergeable shapes (paths keep their centerline
            // semantics and stay out of boolean merges).
            var polygons: [LayoutPolygon] = []
            var mergeable: [LayoutShape] = []
            for shape in shapes {
                switch shape.geometry {
                case .rect(let rect):
                    polygons.append(rect.toPolygon())
                    mergeable.append(shape)
                case .polygon(let poly):
                    polygons.append(poly)
                    mergeable.append(shape)
                case .path:
                    continue
                }
            }

            guard polygons.count >= 2 else { continue }

            let mergedPolygons = union(polygons: polygons, dbuPerMicron: editor.document.units.dbuPerMicron)
            guard !mergedPolygons.isEmpty else { continue }
            let mergedNetID = commonNetID(in: mergeable)
            let mergedProperties = commonProperties(in: mergeable)

            removedIDs.append(contentsOf: mergeable.map(\.id))
            for polygon in mergedPolygons {
                addedShapes.append(LayoutShape(
                    layer: layer,
                    netID: mergedNetID,
                    geometry: .polygon(polygon),
                    properties: mergedProperties
                ))
            }
        }

        guard !removedIDs.isEmpty else { return }
        commitDelta(LayoutEditDelta(addedShapes: addedShapes, removedShapeIDs: removedIDs))
        selectedShapeIDs.removeAll()
    }

    // MARK: - Bounding Box

    public func contentBounds() -> LayoutRect? {
        let shapes = flattenedDocumentShapes()
        guard let first = shapes.first else { return nil }
        var result = LayoutGeometryAnalysis.boundingBox(for: first.geometry)
        for shape in shapes.dropFirst() {
            result = result.union(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
        return result
    }

    public func fitAll() {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            // The canvas has not been laid out yet; defer via canvasSize.didSet
            // so the fit is not silently lost while the editor is off screen.
            pendingFitAll = true
            zoom = 1.0
            offset = .zero
            return
        }
        guard let bounds = contentBounds(),
              bounds.size.width > 0, bounds.size.height > 0 else {
            zoom = 1.0
            offset = .zero
            return
        }

        let margin: CGFloat = 40
        let availableWidth = canvasSize.width - margin * 2
        let availableHeight = canvasSize.height - margin * 2
        let scaleX = availableWidth / CGFloat(bounds.size.width)
        let scaleY = availableHeight / CGFloat(bounds.size.height)
        let newZoom = max(0.01, min(100000, min(scaleX, scaleY)))

        let centerX = CGFloat(bounds.origin.x) + CGFloat(bounds.size.width) / 2
        let centerY = CGFloat(bounds.origin.y) + CGFloat(bounds.size.height) / 2
        zoom = newZoom
        offset = CGPoint(
            x: canvasSize.width / 2 - centerX * newZoom,
            y: canvasSize.height / 2 - centerY * newZoom
        )
    }

    public func deleteSelectedShapes() {
        let ids = selectedShapes().map(\.id)
        guard !ids.isEmpty else { return }
        commitDelta(LayoutEditDelta(removedShapeIDs: ids))
        selectedShapeIDs.removeAll()
    }

    // MARK: - File Import

    public func loadMaskData(from url: URL) throws {
        let resolvedTech: LayoutTechDatabase
        let sidecarResolver = LayoutTechSidecarResolver()
        if let sidecarTech = try sidecarResolver.resolve(for: url) {
            resolvedTech = sidecarTech
        } else {
            resolvedTech = tech
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw error
        }
        let converter = MaskDataFormatConverter(tech: resolvedTech)
        let document = try converter.importFromData(data)

        loadDocument(document, tech: resolvedTech)
    }

    /// Replaces the edited document (and optionally the technology) and
    /// re-syncs all document-derived state: active cell, navigation,
    /// selection, render index, and live verification sessions.
    ///
    /// Assigning ``editor`` directly leaves that state pointing at the old
    /// document (a stale ``activeCellID`` makes the canvas draw nothing) —
    /// always go through this method to swap documents.
    public func loadDocument(_ document: LayoutDocument, tech newTech: LayoutTechDatabase? = nil) {
        if let newTech {
            self.tech = newTech
            self.gridSize = newTech.grid
            self.activeLayer = newTech.layers.first?.id ?? LayoutLayerID(name: "M1", purpose: "drawing")
            self.activeViaID = newTech.vias.first?.id ?? "VIA1"
            self.pathWidth = defaultPathWidth(for: newTech)
        }
        self.editor = LayoutDocumentEditor(document: document)
        self.activeCellID = document.topCellID ?? document.cells.first?.id
        self.cellNavigationPath = Self.initialNavigationPath(document: document, activeCellID: self.activeCellID)
        self.cellBackStack.removeAll()
        self.selectedShapeIDs.removeAll()
        self.selectedInstanceID = nil
        self.hiddenLayers.removeAll()
        self.violations.removeAll()
        // The technology may have changed with the document; a live
        // session cannot absorb that, so start fresh ones.
        restartLiveDRC()
        restartLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
        clearNetHighlight()
    }

    public func centerOn(_ point: LayoutPoint) {
        offset = CGPoint(
            x: canvasSize.width / 2 - CGFloat(point.x) * zoom,
            y: canvasSize.height / 2 - CGFloat(point.y) * zoom
        )
    }

    public func clearSelection() {
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
    }

    /// Selects every shape on a visible layer in the active cell.
    public func selectAllShapes() {
        selectedShapeIDs = Set(
            documentShapes()
                .filter { !hiddenLayers.contains($0.layer) }
                .map(\.id)
        )
    }

    // MARK: - Layer Visibility

    public func isLayerVisible(_ layer: LayoutLayerID) -> Bool {
        !hiddenLayers.contains(layer)
    }

    public func toggleLayerVisibility(_ layer: LayoutLayerID) {
        if hiddenLayers.contains(layer) {
            hiddenLayers.remove(layer)
        } else {
            hiddenLayers.insert(layer)
        }
    }

    // MARK: - Angle-Constrained Snap

    /// Applies grid snap and then angle constraint relative to an anchor point.
    public func constrainedSnap(_ point: LayoutPoint, from anchor: LayoutPoint?) -> LayoutPoint {
        let gridSnapped = snapToGrid(point)
        guard let anchor else { return gridSnapped }
        return angleConstraint.snap(gridSnapped, from: anchor)
    }

    // MARK: - Zoom Steps

    public static let zoomSteps: [CGFloat] = [
        0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50,
        100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000
    ]

    public func zoomToStep(_ step: CGFloat) {
        let clamped = max(0.01, min(100000, step))
        let oldZoom = zoom
        guard oldZoom > 0 else { zoom = clamped; return }
        let scale = clamped / oldZoom
        offset = CGPoint(
            x: canvasSize.width / 2 - (canvasSize.width / 2 - offset.x) * scale,
            y: canvasSize.height / 2 - (canvasSize.height / 2 - offset.y) * scale
        )
        zoom = clamped
    }

    public func zoomInStep() {
        if let next = Self.zoomSteps.first(where: { $0 > zoom * 1.01 }) {
            zoomToStep(next)
        }
    }

    public func zoomOutStep() {
        if let prev = Self.zoomSteps.last(where: { $0 < zoom * 0.99 }) {
            zoomToStep(prev)
        }
    }

    // MARK: - Boolean Operations

    public func subtractFromShapes(cutRect: LayoutRect) {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else { return }

        var removedIDs: [UUID] = []
        var addedShapes: [LayoutShape] = []

        for shape in cell.shapes {
            guard shape.layer == activeLayer else { continue }

            let polygon: LayoutPolygon
            switch shape.geometry {
            case .rect(let rect):
                guard rect.intersects(cutRect) else { continue }
                polygon = rect.toPolygon()
            case .polygon(let poly):
                let bbox = LayoutGeometryAnalysis.boundingBox(for: poly)
                guard bbox.intersects(cutRect) else { continue }
                polygon = poly
            case .path:
                continue
            }

            let remainders = polygon.subtract(cut: cutRect)
            if remainders.count != 1 || remainders.first != polygon {
                removedIDs.append(shape.id)
                for poly in remainders {
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(poly)))
                }
            }
        }

        guard !removedIDs.isEmpty else { return }
        commitDelta(LayoutEditDelta(addedShapes: addedShapes, removedShapeIDs: removedIDs))
        selectedShapeIDs.removeAll()
    }

    public func splitShapes(from start: LayoutPoint, to end: LayoutPoint) {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else { return }

        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        let isHorizontalCut = dx >= dy
        let cutPos = isHorizontalCut
            ? (start.y + end.y) / 2
            : (start.x + end.x) / 2

        var removedIDs: [UUID] = []
        var addedShapes: [LayoutShape] = []

        for shape in cell.shapes {
            guard shape.layer == activeLayer else { continue }

            let polygon: LayoutPolygon
            switch shape.geometry {
            case .rect(let rect):
                polygon = rect.toPolygon()
            case .polygon(let poly):
                polygon = poly
            case .path:
                continue
            }

            if isHorizontalCut {
                if let (bottom, top) = polygon.splitHorizontally(at: cutPos) {
                    removedIDs.append(shape.id)
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(bottom)))
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(top)))
                }
            } else {
                if let (left, right) = polygon.splitVertically(at: cutPos) {
                    removedIDs.append(shape.id)
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(left)))
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(right)))
                }
            }
        }

        guard !removedIDs.isEmpty else { return }
        commitDelta(LayoutEditDelta(addedShapes: addedShapes, removedShapeIDs: removedIDs))
        selectedShapeIDs.removeAll()
    }

    // MARK: - Grid Snap

    public func snapToGrid(_ point: LayoutPoint) -> LayoutPoint {
        let g = gridSize
        guard g > 0 else { return point }
        return LayoutPoint(
            x: (point.x / g).rounded() * g,
            y: (point.y / g).rounded() * g
        )
    }

    // MARK: - Private Helpers

    private func transformSelectedInstance(_ update: (inout LayoutTransform) -> Void) {
        guard let hostCellID = editTargetCellID,
              let selectedInstanceID else { return }
        do {
            try editor.perform { doc in
                guard var cell = doc.cell(withID: hostCellID) else {
                    throw LayoutCoreError.cellNotFound(hostCellID)
                }
                guard let index = cell.instances.firstIndex(where: { $0.id == selectedInstanceID }) else {
                    throw LayoutCoreError.instanceNotFound(selectedInstanceID)
                }
                update(&cell.instances[index].transform)
                doc.updateCell(cell)
            }
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    private static func boundingBox(of points: [LayoutPoint]) -> LayoutRect {
        var minX = points[0].x
        var maxX = points[0].x
        var minY = points[0].y
        var maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func resyncAfterInstanceEdit() {
        inPlaceVerificationPending = false
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }

    private func canPlaceInstance(childCellID: UUID, in parentCellID: UUID) -> Bool {
        guard childCellID != parentCellID else { return false }
        return !cellCanReach(childCellID, target: parentCellID, visited: [])
    }

    private func cellCanReach(_ source: UUID, target: UUID, visited: Set<UUID>) -> Bool {
        guard !visited.contains(source),
              let cell = editor.document.cell(withID: source) else { return false }
        if cell.instances.contains(where: { $0.cellID == target }) {
            return true
        }
        var nextVisited = visited
        nextVisited.insert(source)
        return cell.instances.contains { instance in
            cellCanReach(instance.cellID, target: target, visited: nextVisited)
        }
    }

    private func selectedInstanceTargetCellID() -> UUID? {
        guard let selectedInstanceID,
              let activeCellID,
              let cell = editor.document.cell(withID: activeCellID),
              let instance = cell.instances.first(where: { $0.id == selectedInstanceID }) else {
            return nil
        }
        return instance.cellID
    }

    private func navigate(to cellID: UUID, path: [UUID], recordBack: Bool) {
        guard editor.document.cell(withID: cellID) != nil else { return }

        if recordBack {
            let current = CellNavigationState(activeCellID: activeCellID, path: cellNavigationPath)
            let isMeaningfulTransition = current.activeCellID != cellID || current.path != path
            if isMeaningfulTransition {
                cellBackStack.append(current)
                if cellBackStack.count > 100 {
                    cellBackStack.removeFirst(cellBackStack.count - 100)
                }
            }
        }

        activeCellID = cellID
        cellNavigationPath = path
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
        highlightedInstanceIDs.removeAll()
        violations.removeAll()
        clearNetHighlight()
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }

    private func restoreNavigationState(_ state: CellNavigationState) {
        guard let restoredID = state.activeCellID,
              editor.document.cell(withID: restoredID) != nil else { return }

        let normalizedPath = state.path.filter { editor.document.cell(withID: $0) != nil }
        activeCellID = restoredID
        cellNavigationPath = normalizedPath.isEmpty ? bestPath(to: restoredID) : normalizedPath
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
        highlightedInstanceIDs.removeAll()
        violations.removeAll()
        clearNetHighlight()
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }

    private static func initialNavigationPath(document: LayoutDocument, activeCellID: UUID?) -> [UUID] {
        guard let activeCellID else { return [] }
        if let topCellID = document.topCellID {
            if topCellID == activeCellID {
                return [topCellID]
            }
            return [topCellID, activeCellID]
        }
        return [activeCellID]
    }

    private func bestPath(to cellID: UUID) -> [UUID] {
        let document = editor.document
        guard let topCellID = document.topCellID else { return [cellID] }
        if cellID == topCellID { return [topCellID] }

        var parentByChild: [UUID: UUID] = [:]
        var queue: [UUID] = [topCellID]
        var cursor = 0
        var visited: Set<UUID> = [topCellID]

        while cursor < queue.count {
            let parentID = queue[cursor]
            cursor += 1

            guard let parentCell = document.cell(withID: parentID) else { continue }
            for instance in parentCell.instances {
                let childID = instance.cellID
                if parentByChild[childID] == nil {
                    parentByChild[childID] = parentID
                }
                if !visited.contains(childID) {
                    visited.insert(childID)
                    queue.append(childID)
                }
            }
        }

        var chain: [UUID] = [cellID]
        var current = cellID
        while let parent = parentByChild[current] {
            chain.append(parent)
            if parent == topCellID {
                break
            }
            current = parent
        }

        if chain.last == topCellID {
            return chain.reversed()
        }

        return [topCellID, cellID]
    }

    private static func cellBoundingBox(_ cell: LayoutCell) -> LayoutRect {
        guard let first = cell.shapes.first else { return .zero }
        var bbox = LayoutGeometryAnalysis.boundingBox(for: first.geometry)
        for shape in cell.shapes.dropFirst() {
            bbox = bbox.union(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
        return bbox
    }

    private static func transformRect(_ rect: LayoutRect, by transform: LayoutTransform) -> LayoutRect {
        let corners = [
            transform.apply(to: rect.origin),
            transform.apply(to: LayoutPoint(x: rect.maxX, y: rect.origin.y)),
            transform.apply(to: LayoutPoint(x: rect.origin.x, y: rect.maxY)),
            transform.apply(to: LayoutPoint(x: rect.maxX, y: rect.maxY)),
        ]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func defaultPathWidth(for tech: LayoutTechDatabase) -> Double {
        // Use the minimum width of the first layer, or fall back to grid
        if let firstLayer = tech.layers.first,
           let ruleSet = tech.ruleSet(for: firstLayer.id),
           ruleSet.minWidth > 0 {
            return ruleSet.minWidth
        }
        return tech.grid * 10
    }

    public func clearError() {
        lastError = nil
    }

    private func handleError(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func union(polygons: [LayoutPolygon], dbuPerMicron: Double) -> [LayoutPolygon] {
        let boundaries = polygons.compactMap { irBoundary(from: $0, dbuPerMicron: dbuPerMicron) }
        guard let first = boundaries.first else { return [] }

        var region = Region(polygons: [first])
        for boundary in boundaries.dropFirst() {
            region = region.or(Region(polygons: [boundary]))
        }

        return region.polygons.compactMap { polygon(from: $0, dbuPerMicron: dbuPerMicron) }
    }

    private func irBoundary(from polygon: LayoutPolygon, dbuPerMicron: Double) -> IRBoundary? {
        guard polygon.points.count >= 3, dbuPerMicron > 0 else { return nil }
        var points = polygon.points.map { point in
            IRPoint(
                x: Int32((point.x * dbuPerMicron).rounded()),
                y: Int32((point.y * dbuPerMicron).rounded())
            )
        }
        guard Set(points).count >= 3 else { return nil }
        if points.first != points.last {
            points.append(points[0])
        }
        return IRBoundary(layer: 0, datatype: 0, points: points)
    }

    private func polygon(from boundary: IRBoundary, dbuPerMicron: Double) -> LayoutPolygon? {
        guard dbuPerMicron > 0 else { return nil }
        var points = boundary.points.map { point in
            LayoutPoint(
                x: Double(point.x) / dbuPerMicron,
                y: Double(point.y) / dbuPerMicron
            )
        }
        if points.first == points.last {
            points.removeLast()
        }
        guard points.count >= 3 else { return nil }
        return LayoutPolygon(points: points)
    }

    private func commonNetID(in shapes: [LayoutShape]) -> UUID? {
        guard let first = shapes.first else { return nil }
        return shapes.allSatisfy { $0.netID == first.netID } ? first.netID : nil
    }

    private func commonProperties(in shapes: [LayoutShape]) -> [String: String] {
        guard let first = shapes.first else { return [:] }
        return shapes.allSatisfy { $0.properties == first.properties } ? first.properties : [:]
    }
}
