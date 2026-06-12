import SwiftUI
import LayoutCore
import LayoutTech

public struct LayoutCanvasView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    // MARK: - Drawing State (shared by polygon, path, ruler)

    /// Vertices placed so far in multi-click drawing (polygon, path, ruler).
    @State private var drawingVertices: [LayoutPoint] = []
    @State private var hoverLocation: CGPoint?

    // MARK: - Drag State

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var dragMode: DragMode?
    @State private var panStartOffset: CGPoint?

    private let dragThreshold: CGFloat = 3
    private let polygonCloseThreshold: CGFloat = 10

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    private enum DragMode {
        case drawing       // Rectangle, subtract, split (drag-based)
        case panningCanvas // Multi-click tool drag (pan; select-tool pan lives on the scroll overlay)
        case movingShape   // Select tool drag on selected shape
        case marquee       // Select tool drag on empty area (box selection)
        case handle        // Select tool drag on a vertex/edge handle (stretch)
    }

    public var body: some View {
        Canvas { context, size in
            drawGrid(context: &context, size: size)

            context.translateBy(x: viewModel.offset.x, y: viewModel.offset.y)
            context.scaleBy(x: viewModel.zoom, y: viewModel.zoom)

            drawShapes(context: &context)
            drawInstances(context: &context)
            drawInPlaceFocus(context: &context)
            drawViolations(context: &context)
            drawFocusedViolation(context: &context)
            drawConstraintViolations(context: &context)
            drawLVSFindings(context: &context)
            drawConnectivity(context: &context)
            drawSelection(context: &context)
            drawInstanceHighlights(context: &context)
            drawRulers(context: &context)
            drawMultiClickPreview(context: &context)

            // Undo transform for screen-space drawing
            context.scaleBy(x: 1 / viewModel.zoom, y: 1 / viewModel.zoom)
            context.translateBy(x: -viewModel.offset.x, y: -viewModel.offset.y)

            drawDragPreview(context: &context)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(Color(nsColor: .controlBackgroundColor))
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { _, newSize in
                viewModel.canvasSize = newSize
            }
        })
        .gesture(unifiedDragGesture)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
                if viewModel.tool == .route, viewModel.isRouting {
                    viewModel.updateRoute(to: toLayout(location))
                }
            case .ended:
                hoverLocation = nil
            }
        }
        .background(scrollEventOverlay)
        .onKeyPress(phases: .down) { keyPress in
            handleKeyPress(keyPress)
        }
        .onChange(of: viewModel.tool) { _, _ in
            drawingVertices.removeAll()
            viewModel.cancelRoute()
        }
        .focusable()
    }

    // MARK: - Drag Detection

    private func isDrag(_ value: DragGesture.Value) -> Bool {
        let dx = value.translation.width
        let dy = value.translation.height
        return hypot(dx, dy) >= dragThreshold
    }

    // MARK: - Keyboard Handling

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let hasCmd = keyPress.modifiers.contains(.command)
        let hasShift = keyPress.modifiers.contains(.shift)

        if hasCmd {
            switch keyPress.characters.lowercased() {
            case "=", "+":
                viewModel.zoomInStep()
                return .handled
            case "-":
                viewModel.zoomOutStep()
                return .handled
            case "0":
                viewModel.fitAll()
                return .handled
            default:
                break
            }
        }

        // Shift+K: clear all rulers (Virtuoso convention)
        if hasShift && keyPress.characters.lowercased() == "k" {
            viewModel.clearAllRulers()
            return .handled
        }

        switch keyPress.key {
        case .delete, .deleteForward:
            viewModel.deleteSelectedShapes()
            return .handled
        case .escape:
            if viewModel.isDraggingHandle {
                viewModel.cancelHandleDrag()
                return .handled
            }
            if viewModel.isDraggingShapes {
                viewModel.cancelShapeDrag()
                return .handled
            }
            if viewModel.pendingIntentDevice != nil {
                viewModel.disarmIntentPlacement()
                return .handled
            }
            if viewModel.isRouting {
                viewModel.cancelRoute()
                return .handled
            }
            if !drawingVertices.isEmpty {
                drawingVertices.removeAll()
                return .handled
            }
            if viewModel.isEditingInPlace {
                viewModel.exitInPlaceEdit()
                return .handled
            }
            viewModel.tool = .select
            viewModel.clearSelection()
            return .handled
        case .space:
            viewModel.fitAll()
            return .handled
        case .return:
            // Enter/Return finishes multi-click drawing
            finishMultiClickDrawing()
            return .handled
        default:
            break
        }

        // Backspace removes last vertex in multi-click mode
        if keyPress.characters == "\u{7F}" || keyPress.key == .delete {
            if !drawingVertices.isEmpty {
                drawingVertices.removeLast()
                return .handled
            }
        }

        guard !hasCmd else { return .ignored }

        // Editing verbs on the selection (case-sensitive: Shift reverses
        // rotation direction and flips the mirror axis).
        switch keyPress.characters {
        case "i":
            // Descend into the selected instance in place; Escape ascends.
            if let instanceID = viewModel.selectedInstanceID {
                viewModel.enterInPlaceEdit(instanceID: instanceID)
                return .handled
            }
            return .ignored
        case "a":
            // Auto-complete the active route to the cursor.
            if viewModel.isRouting, let hover = hoverLocation {
                viewModel.completeRoute(to: toLayout(hover))
                return .handled
            }
            return .ignored
        case "n":
            viewModel.focusNextViolation(forward: true)
            return .handled
        case "N":
            viewModel.focusNextViolation(forward: false)
            return .handled
        case "t":
            viewModel.rotateSelectedShapes(clockwise: true)
            return .handled
        case "T":
            viewModel.rotateSelectedShapes(clockwise: false)
            return .handled
        case "f":
            viewModel.mirrorSelectedShapes(across: .vertical)
            return .handled
        case "F":
            viewModel.mirrorSelectedShapes(across: .horizontal)
            return .handled
        case "d":
            viewModel.duplicateSelectedShapes(
                by: LayoutPoint(x: viewModel.gridSize, y: viewModel.gridSize)
            )
            return .handled
        default:
            break
        }

        // Tool shortcut keys
        for tool in LayoutTool.allCases {
            if let key = tool.shortcutKey,
               keyPress.characters == String(key) {
                if viewModel.tool != tool {
                    drawingVertices.removeAll()
                }
                viewModel.tool = tool
                return .handled
            }
        }

        return .ignored
    }

    // MARK: - Unified Gesture

    private var unifiedDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isDrag(value) else { return }

                if dragMode == nil {
                    switch viewModel.tool {
                    case .select:
                        // Handle grab beats move beats marquee: a drag
                        // starting on a vertex/edge handle stretches, on
                        // a selected shape moves (Option duplicates), on
                        // empty area box-selects.
                        let layoutPt = toLayout(value.startLocation)
                        if let hit = handleHitTest(at: value.startLocation) {
                            dragMode = .handle
                            viewModel.beginHandleDrag(shapeID: hit.shapeID, handle: hit.handle)
                        } else if !viewModel.selectedShapeIDs.isEmpty,
                                  shapeHitTest(at: layoutPt, in: viewModel.selectedShapeIDs) {
                            dragMode = .movingShape
                            viewModel.beginShapeDrag(
                                duplicating: NSEvent.modifierFlags.contains(.option)
                            )
                        } else {
                            dragMode = .marquee
                            dragStart = value.startLocation
                        }
                    case .polygon, .path, .route, .ruler, .merge:
                        // Multi-click tools don't use drag for drawing
                        dragMode = .panningCanvas
                        panStartOffset = viewModel.offset
                    default:
                        dragMode = .drawing
                        dragStart = value.startLocation
                    }
                }

                switch dragMode {
                case .panningCanvas:
                    if let startOffset = panStartOffset {
                        viewModel.offset = CGPoint(
                            x: startOffset.x + value.translation.width,
                            y: startOffset.y + value.translation.height
                        )
                    }
                case .drawing, .marquee:
                    dragCurrent = value.location
                case .movingShape:
                    // Cumulative offset from the drag origin in layout
                    // coordinates; the view model quantizes and, in
                    // enforce mode, resolves it to a legal position.
                    let offset = LayoutPoint(
                        x: Double(value.translation.width / viewModel.zoom),
                        y: Double(value.translation.height / viewModel.zoom)
                    )
                    viewModel.updateShapeDrag(to: offset)
                case .handle:
                    let offset = LayoutPoint(
                        x: Double(value.translation.width / viewModel.zoom),
                        y: Double(value.translation.height / viewModel.zoom)
                    )
                    viewModel.updateHandleDrag(to: offset)
                case .none:
                    break
                }
            }
            .onEnded { value in
                if isDrag(value) {
                    switch dragMode {
                    case .drawing:
                        let start = dragStart ?? value.startLocation
                        handleDrawingEnd(start: start, end: value.location)
                    case .movingShape:
                        viewModel.endShapeDrag()
                    case .marquee:
                        let start = dragStart ?? value.startLocation
                        handleMarqueeEnd(start: start, end: value.location)
                    case .handle:
                        viewModel.endHandleDrag()
                    case .panningCanvas, .none:
                        break
                    }
                } else {
                    handleTap(at: value.startLocation)
                }
                dragStart = nil
                dragCurrent = nil
                dragMode = nil
                panStartOffset = nil
            }
    }

    // MARK: - Shape Hit Test

    private func shapeHitTest(at point: LayoutPoint, in ids: Set<UUID>) -> Bool {
        for shape in viewModel.documentShapes() where ids.contains(shape.id) {
            if LayoutGeometryAnalysis.contains(point, in: shape.geometry) {
                return true
            }
        }
        return false
    }

    // MARK: - Handle Hit Test

    /// The handle under a screen point when exactly one shape is selected.
    /// Vertex handles take priority over edge handles; tolerances are in
    /// screen pixels so grabbing feels the same at any zoom.
    private func handleHitTest(at screenPoint: CGPoint) -> (shapeID: UUID, handle: LayoutShapeHandle)? {
        guard viewModel.selectedShapeIDs.count == 1,
              let shapeID = viewModel.selectedShapeIDs.first,
              let shape = viewModel.documentShapes().first(where: { $0.id == shapeID }),
              viewModel.isLayerVisible(shape.layer) else {
            return nil
        }
        let vertexTolerance: CGFloat = 8
        let edgeTolerance: CGFloat = 6

        for (index, vertex) in LayoutHandleEditor.vertices(of: shape.geometry).enumerated() {
            let p = toView(vertex)
            if hypot(screenPoint.x - p.x, screenPoint.y - p.y) <= vertexTolerance {
                return (shapeID, .vertex(index))
            }
        }
        for (index, edge) in LayoutHandleEditor.edges(of: shape.geometry).enumerated() {
            let distance = distanceToSegment(
                screenPoint, from: toView(edge.start), to: toView(edge.end)
            )
            if distance <= edgeTolerance {
                return (shapeID, .edge(index))
            }
        }
        return nil
    }

    private func distanceToSegment(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - projection.x, p.y - projection.y)
    }

    // MARK: - Marquee End

    /// Resolves a finished marquee drag into a selection. Drag direction
    /// picks the semantics — left-to-right is a window (containment)
    /// selection, right-to-left a crossing (intersection) selection — and
    /// Shift adds to the existing selection.
    private func handleMarqueeEnd(start: CGPoint, end: CGPoint) {
        let a = toLayout(start)
        let b = toLayout(end)
        let box = LayoutRect(
            origin: LayoutPoint(x: min(a.x, b.x), y: min(a.y, b.y)),
            size: LayoutSize(width: abs(a.x - b.x), height: abs(a.y - b.y))
        )
        let mode: LayoutMarqueeMode = end.x >= start.x ? .window : .crossing
        viewModel.selectShapes(
            in: box,
            mode: mode,
            additive: NSEvent.modifierFlags.contains(.shift)
        )
    }

    // MARK: - Tap (single click)

    private func handleTap(at location: CGPoint) {
        let raw = toLayout(location)

        // An armed intent device captures the next click as its placement.
        if viewModel.pendingIntentDevice != nil {
            viewModel.placeArmedIntentDevice(at: raw)
            return
        }

        switch viewModel.tool {
        case .select:
            viewModel.selectShape(at: raw)

        case .polygon:
            let snapped = viewModel.snapToGrid(raw)
            handleMultiClickVertex(snapped, screenLocation: location, closesShape: true)

        case .path:
            let anchor = drawingVertices.last
            let snapped = viewModel.constrainedSnap(raw, from: anchor)
            drawingVertices.append(snapped)

        case .route:
            // Session-driven DRC-enforced routing: the first click anchors
            // the route, each further click commits the legal segment and
            // chains the next one from its legal end.
            if viewModel.isRouting {
                viewModel.updateRoute(to: raw)
                if let end = viewModel.commitRoute() {
                    viewModel.beginRoute(at: end)
                }
            } else {
                viewModel.beginRoute(at: raw)
            }

        case .ruler:
            let snapped = viewModel.snapToGrid(raw)
            if drawingVertices.isEmpty {
                drawingVertices.append(snapped)
            } else {
                viewModel.addRuler(from: drawingVertices[0], to: snapped)
                drawingVertices.removeAll()
            }

        case .merge:
            // Merge uses shift-click additive selection; on click just select
            viewModel.selectShape(at: raw)

        case .rectangle, .subtract, .split:
            break

        case .via:
            viewModel.addVia(at: viewModel.snapToGrid(raw))

        case .label:
            viewModel.addLabel(text: "LABEL", at: viewModel.snapToGrid(raw))

        case .pin:
            let snapped = viewModel.snapToGrid(raw)
            viewModel.addPin(name: "PIN", at: snapped, size: LayoutSize(width: 0.2, height: 0.2))
        }
    }

    // MARK: - Multi-Click Vertex Placement

    private func handleMultiClickVertex(_ point: LayoutPoint, screenLocation: CGPoint, closesShape: Bool) {
        // Check if clicking near first vertex to close polygon
        if closesShape, let first = drawingVertices.first, drawingVertices.count >= 3 {
            let firstScreen = toView(first)
            let dist = hypot(screenLocation.x - firstScreen.x, screenLocation.y - firstScreen.y)
            if dist < polygonCloseThreshold {
                finishMultiClickDrawing()
                return
            }
        }
        drawingVertices.append(point)
    }

    /// Finishes the current multi-click drawing operation.
    private func finishMultiClickDrawing() {
        if viewModel.tool == .route {
            viewModel.commitRoute()
            return
        }
        guard !drawingVertices.isEmpty else { return }

        switch viewModel.tool {
        case .polygon:
            if drawingVertices.count >= 3 {
                viewModel.addPolygon(points: drawingVertices)
            }
        case .path:
            if drawingVertices.count >= 2 {
                viewModel.addPath(points: drawingVertices)
            }
        default:
            break
        }

        drawingVertices.removeAll()
    }

    // MARK: - Drawing End (drag-based tools: rectangle, subtract, split)

    private func handleDrawingEnd(start: CGPoint, end: CGPoint) {
        let startLayout = viewModel.snapToGrid(toLayout(start))
        let endLayout = viewModel.snapToGrid(toLayout(end))
        switch viewModel.tool {
        case .rectangle:
            viewModel.addRectangle(from: startLayout, to: endLayout)
        case .subtract:
            let minX = min(startLayout.x, endLayout.x)
            let minY = min(startLayout.y, endLayout.y)
            let maxX = max(startLayout.x, endLayout.x)
            let maxY = max(startLayout.y, endLayout.y)
            let cutRect = LayoutRect(
                origin: LayoutPoint(x: minX, y: minY),
                size: LayoutSize(width: maxX - minX, height: maxY - minY)
            )
            viewModel.subtractFromShapes(cutRect: cutRect)
        case .split:
            viewModel.splitShapes(from: startLayout, to: endLayout)
        default:
            break
        }
    }

    // MARK: - Scroll & Zoom

    private var scrollEventOverlay: some View {
        LayoutScrollEventOverlay(
            onScroll: { deltaX, deltaY in
                viewModel.offset.x += deltaX
                viewModel.offset.y += deltaY
            },
            onZoom: { magnification, cursorLocation in
                zoomToward(cursorLocation, factor: 1 + magnification)
            },
            onBackSwipe: {
                viewModel.navigateBack()
            }
        )
    }

    private func zoomToward(_ screenPoint: CGPoint, factor: CGFloat) {
        let oldZoom = viewModel.zoom
        let newZoom = max(0.01, min(100000, oldZoom * factor))
        let scale = newZoom / oldZoom
        viewModel.offset = CGPoint(
            x: screenPoint.x - (screenPoint.x - viewModel.offset.x) * scale,
            y: screenPoint.y - (screenPoint.y - viewModel.offset.y) * scale
        )
        viewModel.zoom = newZoom
    }

    // MARK: - Drawing: Grid

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let baseGrid = viewModel.gridSize
        guard baseGrid > 0, viewModel.zoom > 0 else { return }

        let minScreenSpacing: CGFloat = 8

        var fineGrid = baseGrid
        while CGFloat(fineGrid) * viewModel.zoom < minScreenSpacing {
            fineGrid *= 10
        }
        let coarseGrid = fineGrid * 10

        drawGridLines(context: &context, size: size, gridSpacing: fineGrid,
                      color: .gray.opacity(0.12), lineWidth: 0.5)

        if CGFloat(coarseGrid) * viewModel.zoom >= minScreenSpacing {
            drawGridLines(context: &context, size: size, gridSpacing: coarseGrid,
                          color: .gray.opacity(0.3), lineWidth: 0.5)
        }

        drawOriginAxes(context: &context, size: size)
    }

    private func drawGridLines(
        context: inout GraphicsContext, size: CGSize,
        gridSpacing: Double, color: Color, lineWidth: CGFloat
    ) {
        let screenSpacing = CGFloat(gridSpacing) * viewModel.zoom
        guard screenSpacing > 0 else { return }

        let ox = viewModel.offset.x
        let oy = viewModel.offset.y
        var path = Path()

        let startGX = floor(-ox / screenSpacing)
        let endGX = ceil((size.width - ox) / screenSpacing)
        var gx = startGX
        while gx <= endGX {
            let sx = gx * screenSpacing + ox
            path.move(to: CGPoint(x: sx, y: 0))
            path.addLine(to: CGPoint(x: sx, y: size.height))
            gx += 1
        }

        let startGY = floor(-oy / screenSpacing)
        let endGY = ceil((size.height - oy) / screenSpacing)
        var gy = startGY
        while gy <= endGY {
            let sy = gy * screenSpacing + oy
            path.move(to: CGPoint(x: 0, y: sy))
            path.addLine(to: CGPoint(x: size.width, y: sy))
            gy += 1
        }

        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private func drawOriginAxes(context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let x0 = viewModel.offset.x
        if x0 >= 0, x0 <= size.width {
            path.move(to: CGPoint(x: x0, y: 0))
            path.addLine(to: CGPoint(x: x0, y: size.height))
        }
        let y0 = viewModel.offset.y
        if y0 >= 0, y0 <= size.height {
            path.move(to: CGPoint(x: 0, y: y0))
            path.addLine(to: CGPoint(x: size.width, y: y0))
        }
        guard !path.isEmpty else { return }
        context.stroke(path, with: .color(.gray.opacity(0.45)), lineWidth: 1)
    }

    // MARK: - Drawing: Shapes

    private func drawShapes(context: inout GraphicsContext) {
        // The render plan culls to the viewport and tiers shapes by their
        // on-screen size, so this draw is proportional to what is visible
        // — never to the database. A nil plan means there is genuinely
        // nothing to draw (no active cell or zero-sized canvas).
        guard let plan = viewModel.currentRenderPlan() else { return }

        let strokeWidth = 1.0 / viewModel.zoom

        for batch in plan.batches {
            guard viewModel.isLayerVisible(batch.layer) else { continue }
            let color = colorForLayer(batch.layer)
            let pattern = patternForLayer(batch.layer)

            // Combine full-tier geometry and box-tier rects into a single
            // fill path so overlapping shapes on the same layer fill once,
            // producing uniform color. Path geometries are converted to
            // filled outlines via strokedPath().
            var combinedFillPath = Path()
            for shape in batch.fullShapes {
                if case .path = shape.geometry {
                    let centerline = pathForShape(shape)
                    let width = pathLineWidth(for: shape)
                    let outline = centerline.strokedPath(StrokeStyle(
                        lineWidth: width, lineCap: .butt, lineJoin: .miter
                    ))
                    combinedFillPath.addPath(outline)
                } else {
                    combinedFillPath.addPath(pathForShape(shape))
                }
            }
            var boxPath = Path()
            for rect in batch.boxRects {
                boxPath.addRect(CGRect(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.size.width,
                    height: rect.size.height
                ))
            }
            combinedFillPath.addPath(boxPath)

            // Pattern fill for all layers — solid uses semi-transparent fill
            if !combinedFillPath.isEmpty {
                if pattern == .solid {
                    context.fill(combinedFillPath, with: .color(color.opacity(0.15)))
                } else {
                    drawPatternOverlay(context: &context, path: combinedFillPath, color: color, pattern: pattern)
                }
            }

            // Outline strokes per full-tier shape; box-tier shapes are a
            // few pixels at most, so one combined stroke keeps them as
            // visible as individually stroked shapes used to be.
            for shape in batch.fullShapes {
                switch shape.geometry {
                case .path:
                    let centerline = pathForShape(shape)
                    let width = pathLineWidth(for: shape)
                    let outline = centerline.strokedPath(StrokeStyle(
                        lineWidth: width, lineCap: .butt, lineJoin: .miter
                    ))
                    context.stroke(outline, with: .color(color), lineWidth: strokeWidth)
                default:
                    let path = pathForShape(shape)
                    context.stroke(path, with: .color(color), lineWidth: strokeWidth)
                }
            }
            if !boxPath.isEmpty {
                context.stroke(boxPath, with: .color(color), lineWidth: strokeWidth)
            }
        }

        drawDensityAggregates(context: &context, aggregates: plan.aggregates)
    }

    /// Sub-pixel shapes (or whole grid cells when the visit budget is
    /// exceeded) drawn as density tiles: one fill per layer and quantized
    /// density level, so a million aggregated shapes cost a handful of
    /// draw calls.
    private func drawDensityAggregates(
        context: inout GraphicsContext,
        aggregates: [LayoutRenderPlan.Aggregate]
    ) {
        guard !aggregates.isEmpty else { return }
        let levelCount = 8
        var buckets: [DensityBucket: Path] = [:]
        for aggregate in aggregates {
            guard viewModel.isLayerVisible(aggregate.layer) else { continue }
            let level = min(Int(aggregate.density * Double(levelCount)), levelCount - 1)
            let key = DensityBucket(layer: aggregate.layer, level: level)
            buckets[key, default: Path()].addRect(CGRect(
                x: aggregate.rect.origin.x,
                y: aggregate.rect.origin.y,
                width: aggregate.rect.size.width,
                height: aggregate.rect.size.height
            ))
        }
        for (bucket, path) in buckets {
            let color = colorForLayer(bucket.layer)
            let opacity = 0.15 + 0.45 * (Double(bucket.level) + 0.5) / Double(levelCount)
            context.fill(path, with: .color(color.opacity(opacity)))
        }
    }

    /// Density tiles bucket by layer and quantized opacity level to bound
    /// the number of fill calls per frame.
    private struct DensityBucket: Hashable {
        var layer: LayoutLayerID
        var level: Int
    }

    // MARK: - Drawing: Violations

    private func drawViolations(context: inout GraphicsContext) {
        guard !viewModel.violations.isEmpty else { return }
        let minMarkerSize = 6.0 / viewModel.zoom
        let lineWidth = 1.5 / viewModel.zoom
        let dash = StrokeStyle(
            lineWidth: lineWidth,
            dash: [3 / viewModel.zoom, 2 / viewModel.zoom]
        )

        for violation in viewModel.violations {
            if let layer = violation.layer, !viewModel.isLayerVisible(layer) { continue }

            let baseColor: Color = violation.severity == .error ? .red : .orange
            let isStale = viewModel.staleViolationKinds.contains(violation.kind)
            let color = isStale ? baseColor.opacity(0.35) : baseColor

            let region = violation.region
            var rect = CGRect(
                x: region.origin.x,
                y: region.origin.y,
                width: region.size.width,
                height: region.size.height
            )
            // Degenerate regions (edge-to-edge gaps collapse to a line or
            // point) still get a visible marker.
            if rect.width < minMarkerSize {
                rect = rect.insetBy(dx: (rect.width - minMarkerSize) / 2, dy: 0)
            }
            if rect.height < minMarkerSize {
                rect = rect.insetBy(dx: 0, dy: (rect.height - minMarkerSize) / 2)
            }

            let path = Path(rect)
            context.fill(path, with: .color(color.opacity(0.18)))
            context.stroke(path, with: .color(color), style: dash)
        }
    }

    // MARK: - Drawing: Constraint Violations

    /// Broken design-intent constraints (symmetry, matching, alignment, ...).
    /// Purple, long-dashed, with a diagonal cross so they read apart from
    /// DRC markers even when regions overlap.
    private func drawConstraintViolations(context: inout GraphicsContext) {
        guard !viewModel.constraintViolations.isEmpty else { return }
        let minMarkerSize = 8.0 / viewModel.zoom
        let lineWidth = 1.5 / viewModel.zoom
        let dash = StrokeStyle(
            lineWidth: lineWidth,
            dash: [6 / viewModel.zoom, 3 / viewModel.zoom]
        )

        for violation in viewModel.constraintViolations {
            let color: Color = violation.severity == .error
                ? .purple
                : .purple.opacity(0.55)

            let region = violation.region
            var rect = CGRect(
                x: region.origin.x,
                y: region.origin.y,
                width: region.size.width,
                height: region.size.height
            )
            if rect.width < minMarkerSize {
                rect = rect.insetBy(dx: (rect.width - minMarkerSize) / 2, dy: 0)
            }
            if rect.height < minMarkerSize {
                rect = rect.insetBy(dx: 0, dy: (rect.height - minMarkerSize) / 2)
            }

            let path = Path(rect)
            context.fill(path, with: .color(color.opacity(0.10)))
            context.stroke(path, with: .color(color), style: dash)

            var cross = Path()
            cross.move(to: CGPoint(x: rect.minX, y: rect.minY))
            cross.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            cross.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            cross.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.stroke(cross, with: .color(color.opacity(0.6)), lineWidth: lineWidth)
        }
    }

    // MARK: - Drawing: Connectivity

    /// Live connectivity overlay: short regions, open-net flylines, and
    /// the highlighted net. Everything here comes from the incremental
    /// extraction session, so it tracks the gesture in progress.
    private func drawConnectivity(context: inout GraphicsContext) {
        guard let analysis = viewModel.connectivityAnalysis else { return }
        let lineWidth = 1.5 / viewModel.zoom

        drawHighlightedNet(context: &context)

        // Short regions: one conductor piece carrying several declared
        // nets — red, hatched apart from DRC markers by a tighter dash.
        if !analysis.shorts.isEmpty {
            let dash = StrokeStyle(
                lineWidth: lineWidth,
                dash: [2 / viewModel.zoom, 2 / viewModel.zoom]
            )
            for short in analysis.shorts {
                let region = short.region
                let rect = CGRect(
                    x: region.origin.x,
                    y: region.origin.y,
                    width: region.size.width,
                    height: region.size.height
                )
                let path = Path(rect.insetBy(dx: -2 / viewModel.zoom, dy: -2 / viewModel.zoom))
                context.fill(path, with: .color(.red.opacity(0.12)))
                context.stroke(path, with: .color(.red), style: dash)
            }
        }

        // Flylines: minimum spanning connections of each open net's
        // islands — the classic unrouted-net guide.
        if !analysis.opens.isEmpty {
            let dash = StrokeStyle(
                lineWidth: lineWidth,
                dash: [5 / viewModel.zoom, 3 / viewModel.zoom]
            )
            let endpointRadius = 2.5 / viewModel.zoom
            for flyline in analysis.flylines {
                var path = Path()
                path.move(to: CGPoint(x: flyline.start.x, y: flyline.start.y))
                path.addLine(to: CGPoint(x: flyline.end.x, y: flyline.end.y))
                context.stroke(path, with: .color(.yellow), style: dash)
                for point in [flyline.start, flyline.end] {
                    let dot = Path(ellipseIn: CGRect(
                        x: point.x - endpointRadius,
                        y: point.y - endpointRadius,
                        width: endpointRadius * 2,
                        height: endpointRadius * 2
                    ))
                    context.fill(dot, with: .color(.yellow))
                }
            }
        }
    }

    /// Glow stroke over every member of the highlighted net, including
    /// via cuts, so the whole conductor reads as one piece.
    private func drawHighlightedNet(context: inout GraphicsContext) {
        guard let net = viewModel.highlightedNet else { return }
        let shapeIDs = Set(net.shapeIDs)
        let viaIDs = Set(net.viaIDs)
        let glowWidth = 4 / viewModel.zoom
        let coreWidth = 1.5 / viewModel.zoom

        for shape in viewModel.documentShapes() where shapeIDs.contains(shape.id) {
            let path = pathForShape(shape)
            context.stroke(path, with: .color(.cyan.opacity(0.35)), lineWidth: glowWidth)
            context.stroke(path, with: .color(.cyan), lineWidth: coreWidth)
        }
        for via in viewModel.documentVias() where viaIDs.contains(via.id) {
            guard let def = viewModel.tech.viaDefinition(for: via.viaDefinitionID) else { continue }
            let rect = CGRect(
                x: via.position.x - def.cutSize.width / 2,
                y: via.position.y - def.cutSize.height / 2,
                width: def.cutSize.width,
                height: def.cutSize.height
            )
            let path = Path(rect)
            context.stroke(path, with: .color(.cyan.opacity(0.35)), lineWidth: glowWidth)
            context.stroke(path, with: .color(.cyan), lineWidth: coreWidth)
        }
    }

    // MARK: - Drawing: Selection

    /// Selection stroke color doubles as design-rule-driven drag feedback:
    /// orange while the drag is being constrained to a legal position, red
    /// while it is fully blocked.
    private var selectionColor: Color {
        switch viewModel.dragOutcome {
        case .constrained: return .orange
        case .blocked: return .red
        case .followed, nil: return .yellow
        }
    }

    /// Pulsing focus ring around the violation selected by n/N cycling
    /// or a diagnostics-row click.
    private func drawFocusedViolation(context: inout GraphicsContext) {
        guard let focusedID = viewModel.focusedViolationID,
              let violation = viewModel.violations.first(where: { $0.id == focusedID }) else {
            return
        }
        let rect = violation.region
        let inset = -4.0 / viewModel.zoom
        let path = Path(CGRect(
            x: rect.minX, y: rect.minY,
            width: rect.size.width, height: rect.size.height
        ).insetBy(dx: inset, dy: inset))
        context.stroke(
            path,
            with: .color(.yellow),
            style: StrokeStyle(lineWidth: 3 / viewModel.zoom)
        )
    }

    /// Live LVS findings: extracted devices with no reference counterpart
    /// or mismatched parameters, marked at their channel regions, plus
    /// extraction issues at their regions.
    private func drawLVSFindings(context: inout GraphicsContext) {
        guard let comparison = viewModel.lvsComparison else { return }
        let stroke = 2.0 / viewModel.zoom
        func mark(_ rect: LayoutRect, color: Color) {
            guard rect.size.width > 0 || rect.size.height > 0 else { return }
            let path = Path(CGRect(
                x: rect.minX, y: rect.minY,
                width: rect.size.width, height: rect.size.height
            ).insetBy(dx: -2 / viewModel.zoom, dy: -2 / viewModel.zoom))
            context.stroke(path, with: .color(color), style: StrokeStyle(
                lineWidth: stroke,
                dash: [5 / viewModel.zoom, 3 / viewModel.zoom]
            ))
        }
        for device in comparison.unmatchedExtractedDevices {
            mark(device.region, color: .red)
        }
        for mismatch in comparison.parameterMismatches {
            mark(mismatch.region, color: .orange)
        }
        if let extraction = viewModel.lvsExtraction {
            for issue in extraction.issues {
                mark(issue.region, color: .pink)
            }
        }
    }

    /// In-place editing focus: everything outside the entered context is
    /// dimmed, then the edit target's shapes (already mapped to view space
    /// by `documentShapes()`) are redrawn at full strength on top.
    private func drawInPlaceFocus(context: inout GraphicsContext) {
        guard viewModel.isEditingInPlace else { return }
        let viewportOrigin = toLayout(.zero)
        let viewportCorner = toLayout(CGPoint(
            x: viewModel.canvasSize.width,
            y: viewModel.canvasSize.height
        ))
        let dimRect = CGRect(
            x: min(viewportOrigin.x, viewportCorner.x),
            y: min(viewportOrigin.y, viewportCorner.y),
            width: abs(viewportCorner.x - viewportOrigin.x),
            height: abs(viewportCorner.y - viewportOrigin.y)
        )
        context.fill(
            Path(dimRect),
            with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        for shape in viewModel.documentShapes() where viewModel.isLayerVisible(shape.layer) {
            let path = pathForShape(shape)
            context.fill(path, with: .color(colorForLayer(shape.layer).opacity(0.85)))
        }
    }

    private func drawSelection(context: inout GraphicsContext) {
        let color = selectionColor
        for shape in viewModel.documentShapes() where viewModel.selectedShapeIDs.contains(shape.id) {
            let path = pathForShape(shape)
            context.stroke(path, with: .color(color), lineWidth: 2 / viewModel.zoom)
        }
        drawHandles(context: &context)
    }

    /// Vertex and edge handles for a single selected shape — filled
    /// squares on vertices, hollow squares on edge midpoints. Drawn from
    /// the current document geometry so they follow a live handle drag.
    private func drawHandles(context: inout GraphicsContext) {
        guard viewModel.tool == .select,
              viewModel.selectedShapeIDs.count == 1,
              let shapeID = viewModel.selectedShapeIDs.first,
              let shape = viewModel.documentShapes().first(where: { $0.id == shapeID }),
              viewModel.isLayerVisible(shape.layer) else { return }

        let size = 6.0 / viewModel.zoom
        let stroke = 1.0 / viewModel.zoom

        for edge in LayoutHandleEditor.edges(of: shape.geometry) {
            let mid = CGPoint(
                x: (edge.start.x + edge.end.x) / 2,
                y: (edge.start.y + edge.end.y) / 2
            )
            let rect = CGRect(x: mid.x - size / 2, y: mid.y - size / 2, width: size, height: size)
            context.fill(Path(rect), with: .color(Color(nsColor: .controlBackgroundColor)))
            context.stroke(Path(rect), with: .color(.yellow), lineWidth: stroke)
        }
        for vertex in LayoutHandleEditor.vertices(of: shape.geometry) {
            let rect = CGRect(
                x: vertex.x - size / 2, y: vertex.y - size / 2,
                width: size, height: size
            )
            context.fill(Path(rect), with: .color(.yellow))
        }
    }

    // MARK: - Drawing: Instances

    private func drawInstances(context: inout GraphicsContext) {
        for (inst, bounds) in viewModel.instanceBoundingBoxes() {
            let viewRect = CGRect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.size.width,
                height: bounds.size.height
            )
            let path = Path(viewRect)
            let isSelected = viewModel.selectedInstanceID == inst.id
            let strokeColor: Color = isSelected ? .yellow : .gray.opacity(0.5)
            let lineWidth: CGFloat = (isSelected ? 2 : 1) / viewModel.zoom
            context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)

            let labelPoint = CGPoint(x: viewRect.midX, y: viewRect.minY - 4 / viewModel.zoom)
            context.draw(
                Text(inst.name).font(.system(size: 9 / viewModel.zoom)).foregroundColor(.gray),
                at: labelPoint
            )
        }
    }

    // MARK: - Drawing: Instance Highlights

    private func drawInstanceHighlights(context: inout GraphicsContext) {
        guard !viewModel.highlightedInstanceIDs.isEmpty else { return }
        for (inst, bounds) in viewModel.instanceBoundingBoxes() {
            guard viewModel.highlightedInstanceIDs.contains(inst.id) else { continue }
            let viewRect = CGRect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.size.width,
                height: bounds.size.height
            )
            let path = Path(viewRect)
            context.stroke(path, with: .color(.orange), lineWidth: 3 / viewModel.zoom)
            context.fill(path, with: .color(.orange.opacity(0.1)))
        }
    }

    // MARK: - Drawing: Rulers

    private func drawRulers(context: inout GraphicsContext) {
        let lineWidth = 1.0 / viewModel.zoom
        let fontSize = 10.0 / viewModel.zoom

        for ruler in viewModel.rulers {
            var path = Path()
            path.move(to: CGPoint(x: ruler.start.x, y: ruler.start.y))
            path.addLine(to: CGPoint(x: ruler.end.x, y: ruler.end.y))
            context.stroke(path, with: .color(.cyan), lineWidth: lineWidth)

            // Endpoints
            let endpointR = 3.0 / viewModel.zoom
            for pt in [ruler.start, ruler.end] {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: pt.x - endpointR, y: pt.y - endpointR,
                        width: endpointR * 2, height: endpointR * 2
                    )),
                    with: .color(.cyan)
                )
            }

            // Distance label
            let midPoint = CGPoint(
                x: (ruler.start.x + ruler.end.x) / 2,
                y: (ruler.start.y + ruler.end.y) / 2 - fontSize * 1.2
            )
            let distStr = formatDistance(ruler.distance)
            context.draw(
                Text(distStr).font(.system(size: fontSize)).foregroundColor(.cyan),
                at: midPoint
            )
        }
    }

    private func formatDistance(_ d: Double) -> String {
        if d >= 1.0 {
            return String(format: "%.3f \u{00B5}m", d)
        } else {
            return String(format: "%.1f nm", d * 1000)
        }
    }

    // MARK: - Drawing: Multi-Click Preview (polygon, path, ruler — in layout coords)

    private func drawMultiClickPreview(context: inout GraphicsContext) {
        // The route preview lives in the session, not in drawingVertices.
        guard !drawingVertices.isEmpty || viewModel.tool == .route else { return }

        switch viewModel.tool {
        case .polygon:
            drawPolygonPreview(context: &context)
        case .path:
            drawPathPreview(context: &context)
        case .route:
            drawRoutePreview(context: &context)
        case .ruler:
            drawRulerPreview(context: &context)
        default:
            break
        }
    }

    private func drawPolygonPreview(context: inout GraphicsContext) {
        let lineWidth = 1.5 / viewModel.zoom
        let vertexRadius = 4.0 / viewModel.zoom
        let color = colorForLayer(viewModel.activeLayer)

        var path = Path()
        let first = drawingVertices[0]
        path.move(to: CGPoint(x: first.x, y: first.y))
        for vertex in drawingVertices.dropFirst() {
            path.addLine(to: CGPoint(x: vertex.x, y: vertex.y))
        }

        // Rubber-band line from last vertex to cursor
        if let hover = hoverLocation, let last = drawingVertices.last {
            let hoverLayout = viewModel.constrainedSnap(toLayout(hover), from: last)
            path.addLine(to: CGPoint(x: hoverLayout.x, y: hoverLayout.y))
        }

        let dash = StrokeStyle(lineWidth: lineWidth, dash: [4 / viewModel.zoom, 3 / viewModel.zoom])
        context.stroke(path, with: .color(color), style: dash)

        // Draw vertices
        for (i, vertex) in drawingVertices.enumerated() {
            let isFirst = i == 0
            let dotColor: Color = isFirst ? .green : color
            let r = isFirst ? vertexRadius * 1.3 : vertexRadius
            context.fill(
                Path(ellipseIn: CGRect(
                    x: vertex.x - r, y: vertex.y - r,
                    width: r * 2, height: r * 2
                )),
                with: .color(dotColor)
            )
        }

        // Closing indicator
        if drawingVertices.count >= 3, let hover = hoverLocation {
            let firstScreen = toView(first)
            let dist = hypot(hover.x - firstScreen.x, hover.y - firstScreen.y)
            if dist < polygonCloseThreshold {
                let closeR = vertexRadius * 2
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: first.x - closeR, y: first.y - closeR,
                        width: closeR * 2, height: closeR * 2
                    )),
                    with: .color(.green),
                    lineWidth: lineWidth
                )
            }
        }
    }

    /// Session-driven route preview: the legal geometry the session would
    /// commit, plus a dashed blocked segment from the legal end to the
    /// cursor when DRC stopped the route short.
    private func drawRoutePreview(context: inout GraphicsContext) {
        guard let preview = viewModel.routePreview else { return }
        let color = colorForLayer(viewModel.activeLayer)

        for shape in preview.delta.addedShapes {
            if case .rect(let rect) = shape.geometry {
                context.fill(
                    Path(CGRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)),
                    with: .color(color.opacity(0.45))
                )
            }
        }

        // Live electrical estimate of the wire being drawn (plus its
        // net's existing geometry) — the editor reads circuits, not just
        // rectangles. Shown only when the tech models the constants.
        if let estimate = viewModel.routeElectricalEstimate(),
           let resistance = estimate.resistance,
           let capacitance = estimate.capacitance {
            var hud = String(format: "R %.1f ohm  C %.1f fF", resistance, capacitance)
            if let tau = estimate.timeConstantPS {
                hud += String(format: "  tau %.2f ps", tau)
            }
            let fontSize = 10.0 / viewModel.zoom
            context.draw(
                Text(hud)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(.cyan),
                at: CGPoint(
                    x: preview.legalEnd.x,
                    y: preview.legalEnd.y + 16 / viewModel.zoom
                )
            )
        }

        // Neighbours displaced by shove, at their preview positions.
        for shape in preview.pushedShapes {
            if case .rect(let rect) = shape.geometry {
                let path = Path(CGRect(
                    x: rect.minX, y: rect.minY,
                    width: rect.size.width, height: rect.size.height
                ))
                context.fill(path, with: .color(.orange.opacity(0.35)))
                context.stroke(path, with: .color(.orange), lineWidth: 1.5 / viewModel.zoom)
            }
        }

        if preview.stopReason != nil {
            var blocked = Path()
            blocked.move(to: CGPoint(x: preview.legalEnd.x, y: preview.legalEnd.y))
            blocked.addLine(to: CGPoint(x: preview.requestedEnd.x, y: preview.requestedEnd.y))
            let dash = StrokeStyle(
                lineWidth: 1.5 / viewModel.zoom,
                dash: [4 / viewModel.zoom, 3 / viewModel.zoom]
            )
            context.stroke(blocked, with: .color(.red), style: dash)

            // WHY the route stopped, right at the cursor — the engine
            // knows; the user should not have to guess.
            if let first = preview.violations.first {
                var reason = first.kind.rawValue
                if let required = first.required {
                    reason += String(format: " (needs %.3f um)", required)
                }
                let fontSize = 11.0 / viewModel.zoom
                context.draw(
                    Text(reason)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.red),
                    at: CGPoint(
                        x: preview.requestedEnd.x,
                        y: preview.requestedEnd.y - 14 / viewModel.zoom
                    )
                )
            }
        }
    }

    private func drawPathPreview(context: inout GraphicsContext) {
        let color = colorForLayer(viewModel.activeLayer)
        let w = CGFloat(viewModel.pathWidth)

        // Draw placed segments with width
        if drawingVertices.count >= 2 {
            for i in 0..<(drawingVertices.count - 1) {
                let a = drawingVertices[i]
                let b = drawingVertices[i + 1]
                var seg = Path()
                seg.move(to: CGPoint(x: a.x, y: a.y))
                seg.addLine(to: CGPoint(x: b.x, y: b.y))
                context.stroke(seg, with: .color(color.opacity(0.8)), lineWidth: w)
            }
        }

        // Centerline dashed
        var centerline = Path()
        centerline.move(to: CGPoint(x: drawingVertices[0].x, y: drawingVertices[0].y))
        for v in drawingVertices.dropFirst() {
            centerline.addLine(to: CGPoint(x: v.x, y: v.y))
        }

        // Rubber-band to cursor
        if let hover = hoverLocation, let last = drawingVertices.last {
            let hoverLayout = viewModel.constrainedSnap(toLayout(hover), from: last)
            centerline.addLine(to: CGPoint(x: hoverLayout.x, y: hoverLayout.y))

            // Preview the rubber-band segment with width
            var rubberSeg = Path()
            rubberSeg.move(to: CGPoint(x: last.x, y: last.y))
            rubberSeg.addLine(to: CGPoint(x: hoverLayout.x, y: hoverLayout.y))
            context.stroke(rubberSeg, with: .color(color.opacity(0.4)), lineWidth: w)
        }

        let dash = StrokeStyle(lineWidth: 1 / viewModel.zoom, dash: [4 / viewModel.zoom, 3 / viewModel.zoom])
        context.stroke(centerline, with: .color(color), style: dash)

        // Vertex dots
        let vertexR = 3.0 / viewModel.zoom
        for vertex in drawingVertices {
            context.fill(
                Path(ellipseIn: CGRect(
                    x: vertex.x - vertexR, y: vertex.y - vertexR,
                    width: vertexR * 2, height: vertexR * 2
                )),
                with: .color(color)
            )
        }
    }

    private func drawRulerPreview(context: inout GraphicsContext) {
        guard let first = drawingVertices.first, let hover = hoverLocation else { return }
        let hoverLayout = viewModel.snapToGrid(toLayout(hover))
        let lineWidth = 1.0 / viewModel.zoom
        let fontSize = 10.0 / viewModel.zoom

        var path = Path()
        path.move(to: CGPoint(x: first.x, y: first.y))
        path.addLine(to: CGPoint(x: hoverLayout.x, y: hoverLayout.y))

        let dash = StrokeStyle(lineWidth: lineWidth, dash: [6 / viewModel.zoom, 4 / viewModel.zoom])
        context.stroke(path, with: .color(.cyan), style: dash)

        let dist = hypot(hoverLayout.x - first.x, hoverLayout.y - first.y)
        let midPt = CGPoint(
            x: (first.x + hoverLayout.x) / 2,
            y: (first.y + hoverLayout.y) / 2 - fontSize * 1.2
        )
        context.draw(
            Text(formatDistance(dist)).font(.system(size: fontSize)).foregroundColor(.cyan),
            at: midPt
        )
    }

    // MARK: - Drawing: Drag Preview (screen space — rectangle, subtract, split)

    private func drawDragPreview(context: inout GraphicsContext) {
        guard let start = dragStart,
              let current = dragCurrent else { return }

        if dragMode == .marquee {
            drawMarqueePreview(context: &context, start: start, current: current)
            return
        }

        switch viewModel.tool {
        case .rectangle:
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(start.x - current.x),
                height: abs(start.y - current.y)
            )
            context.stroke(Path(rect), with: .color(.blue), lineWidth: 1)

        case .subtract:
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(start.x - current.x),
                height: abs(start.y - current.y)
            )
            context.fill(Path(rect), with: .color(.red.opacity(0.15)))
            let dash = StrokeStyle(lineWidth: 1, dash: [4, 3])
            context.stroke(Path(rect), with: .color(.red.opacity(0.8)), style: dash)

        case .split:
            let dx = abs(current.x - start.x)
            let dy = abs(current.y - start.y)
            let canvasW = viewModel.canvasSize.width
            let canvasH = viewModel.canvasSize.height
            var linePath = Path()
            if dx >= dy {
                let y = (start.y + current.y) / 2
                linePath.move(to: CGPoint(x: 0, y: y))
                linePath.addLine(to: CGPoint(x: canvasW, y: y))
            } else {
                let x = (start.x + current.x) / 2
                linePath.move(to: CGPoint(x: x, y: 0))
                linePath.addLine(to: CGPoint(x: x, y: canvasH))
            }
            let dash = StrokeStyle(lineWidth: 1, dash: [6, 4])
            context.stroke(linePath, with: .color(.orange), style: dash)

        default:
            break
        }
    }

    /// Window (left-to-right) drags preview solid blue; crossing
    /// (right-to-left) drags preview dashed green — the convention that
    /// tells the user which selection semantics will apply on release.
    private func drawMarqueePreview(
        context: inout GraphicsContext, start: CGPoint, current: CGPoint
    ) {
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
        if current.x >= start.x {
            context.fill(Path(rect), with: .color(.blue.opacity(0.08)))
            context.stroke(Path(rect), with: .color(.blue.opacity(0.8)), lineWidth: 1)
        } else {
            context.fill(Path(rect), with: .color(.green.opacity(0.08)))
            let dash = StrokeStyle(lineWidth: 1, dash: [4, 3])
            context.stroke(Path(rect), with: .color(.green.opacity(0.8)), style: dash)
        }
    }

    // MARK: - Coordinate Conversion

    private func toLayout(_ point: CGPoint) -> LayoutPoint {
        let x = (point.x - viewModel.offset.x) / viewModel.zoom
        let y = (point.y - viewModel.offset.y) / viewModel.zoom
        return LayoutPoint(x: Double(x), y: Double(y))
    }

    private func toView(_ point: LayoutPoint) -> CGPoint {
        let x = CGFloat(point.x) * viewModel.zoom + viewModel.offset.x
        let y = CGFloat(point.y) * viewModel.zoom + viewModel.offset.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Shape Path (in layout coordinates)

    private func pathForShape(_ shape: LayoutShape) -> Path {
        switch shape.geometry {
        case .rect(let rect):
            return Path(CGRect(
                x: rect.minX, y: rect.minY,
                width: rect.size.width, height: rect.size.height
            ))
        case .polygon(let polygon):
            var path = Path()
            guard let first = polygon.points.first else { return path }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in polygon.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            path.closeSubpath()
            return path
        case .path(let layoutPath):
            var path = Path()
            guard let first = layoutPath.points.first else { return path }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in layoutPath.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            return path
        }
    }

    private func pathLineWidth(for shape: LayoutShape) -> CGFloat {
        if case .path(let layoutPath) = shape.geometry {
            return CGFloat(layoutPath.width)
        }
        return 1 / viewModel.zoom
    }

    private func colorForLayer(_ layer: LayoutLayerID) -> Color {
        if let def = viewModel.tech.layerDefinition(for: layer) {
            return Color(
                red: def.color.red,
                green: def.color.green,
                blue: def.color.blue,
                opacity: def.color.alpha
            )
        }
        return .gray
    }

    private func patternForLayer(_ layer: LayoutLayerID) -> LayoutFillPattern {
        viewModel.tech.layerDefinition(for: layer)?.fillPattern ?? .solid
    }

    // MARK: - Pattern Rendering

    private func drawPatternOverlay(
        context: inout GraphicsContext,
        path: Path,
        color: Color,
        pattern: LayoutFillPattern
    ) {
        let bounds = path.boundingRect
        guard !bounds.isEmpty else { return }
        let spacing = 14.0 / viewModel.zoom
        guard spacing > 0 else { return }
        let maxLines = max(bounds.width, bounds.height) / spacing
        guard maxLines < 200 else { return }
        let lineWidth = 1.0 / viewModel.zoom

        context.drawLayer { layerContext in
            layerContext.clip(to: path)
            if pattern == .dots {
                let dotPath = dotPatternPath(in: bounds, spacing: spacing)
                layerContext.fill(dotPath, with: .color(color.opacity(0.5)))
            } else {
                let linePath = linePatternPath(for: pattern, in: bounds, spacing: spacing)
                layerContext.stroke(linePath, with: .color(color.opacity(0.5)), lineWidth: lineWidth)
            }
        }
    }

    private func linePatternPath(for pattern: LayoutFillPattern, in rect: CGRect, spacing: CGFloat) -> Path {
        var path = Path()
        switch pattern {
        case .forwardDiagonal:
            addForwardDiagonals(to: &path, in: rect, spacing: spacing)
        case .backwardDiagonal:
            addBackwardDiagonals(to: &path, in: rect, spacing: spacing)
        case .crosshatch:
            addForwardDiagonals(to: &path, in: rect, spacing: spacing)
            addBackwardDiagonals(to: &path, in: rect, spacing: spacing)
        case .horizontal:
            addHorizontalLines(to: &path, in: rect, spacing: spacing)
        case .vertical:
            addVerticalLines(to: &path, in: rect, spacing: spacing)
        case .grid:
            addHorizontalLines(to: &path, in: rect, spacing: spacing)
            addVerticalLines(to: &path, in: rect, spacing: spacing)
        case .solid, .dots:
            break
        }
        return path
    }

    private func addForwardDiagonals(to path: inout Path, in rect: CGRect, spacing: CGFloat) {
        let h = rect.height
        var x = rect.minX - h
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + h, y: rect.minY))
            x += spacing
        }
    }

    private func addBackwardDiagonals(to path: inout Path, in rect: CGRect, spacing: CGFloat) {
        let h = rect.height
        var x = rect.minX - h
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + h, y: rect.maxY))
            x += spacing
        }
    }

    private func addHorizontalLines(to path: inout Path, in rect: CGRect, spacing: CGFloat) {
        var y = rect.minY + spacing
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
    }

    private func addVerticalLines(to path: inout Path, in rect: CGRect, spacing: CGFloat) {
        var x = rect.minX + spacing
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }
    }

    private func dotPatternPath(in rect: CGRect, spacing: CGFloat) -> Path {
        let dotRadius = max(0.5 / viewModel.zoom, spacing * 0.12)
        var path = Path()
        var y = rect.minY + spacing / 2
        while y <= rect.maxY {
            var x = rect.minX + spacing / 2
            while x <= rect.maxX {
                path.addEllipse(in: CGRect(
                    x: x - dotRadius, y: y - dotRadius,
                    width: dotRadius * 2, height: dotRadius * 2
                ))
                x += spacing
            }
            y += spacing
        }
        return path
    }
}
