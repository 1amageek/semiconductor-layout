import Foundation
import LayoutCore
import LayoutTech

/// Row-based placement engine for standard-cell-like layout.
///
/// Algorithm:
/// 1. Classify instances into rows: PMOS → top (near VDD), NMOS → bottom (near VSS), passive → middle.
/// 2. Order within each row by connectivity adjacency (greedy nearest-neighbor using shared net count).
/// 3. Place cells left-to-right with spacing from PDK minSpacing rules.
/// 4. Generate VDD/VSS power rails as M1 horizontal shapes.
/// 5. Snap all coordinates to tech grid.
public struct RowBasedPlacementEngine: PlacementEngine {
    public init() {}

    public func place(
        instances: [PlacementInstance],
        nets: [PlacementNet],
        tech: LayoutTechDatabase
    ) throws -> PlacementResult {
        guard !instances.isEmpty else {
            return PlacementResult(placements: [:], powerRails: [], totalBoundingBox: .zero)
        }

        let grid = tech.grid
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Rules = try tech.requiredRuleSet(for: m1ID)
        let m2Rules = try tech.requiredRuleSet(for: m2ID)
        let m1Width = m1Rules.minWidth

        // Spacing between cells
        let activeID = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let polyID = LayoutLayerID(name: "POLY", purpose: "drawing")
        let activeSpacing = try tech.requiredRuleSet(for: activeID).minSpacing
        let polySpacing = try tech.requiredRuleSet(for: polyID).minSpacing
        let routingPitch = max(
            m1Rules.minWidth + m1Rules.minSpacing,
            m2Rules.minWidth + m2Rules.minSpacing
        )
        let routingChannelSpacing = ContactArrayHelper.snapUp(routingPitch * 4, grid: grid)
        let deviceSpacing = max(activeSpacing, polySpacing) + grid * 10
        let cellSpacing = max(deviceSpacing, routingChannelSpacing)

        // Build adjacency graph (shared nets between instances)
        let adjacency = buildAdjacency(instances: instances, nets: nets)

        // Classify instances into rows
        var pmosInstances: [PlacementInstance] = []
        var nmosInstances: [PlacementInstance] = []
        var passiveInstances: [PlacementInstance] = []
        for inst in instances {
            switch inst.deviceType {
            case .pmos: pmosInstances.append(inst)
            case .nmos: nmosInstances.append(inst)
            case .passive: passiveInstances.append(inst)
            }
        }

        // Order within each row by connectivity
        pmosInstances = orderByConnectivity(pmosInstances, adjacency: adjacency)
        nmosInstances = orderByConnectivity(nmosInstances, adjacency: adjacency)
        passiveInstances = orderByConnectivity(passiveInstances, adjacency: adjacency)

        // Calculate row heights
        let pmosHeight = maxCellHeight(pmosInstances)
        let nmosHeight = maxCellHeight(nmosInstances)
        let passiveHeight = maxCellHeight(passiveInstances)

        // Power rail dimensions
        let railHeight = snap(max(m1Width * 3, 0.46), grid: grid)

        // Row Y positions (bottom to top): VSS rail → NMOS → passive → PMOS → VDD rail
        var currentY = 0.0
        let vssRailY = currentY
        currentY += railHeight + cellSpacing

        let nmosY = snap(currentY, grid: grid)
        if !nmosInstances.isEmpty {
            currentY += nmosHeight + cellSpacing
        }

        let passiveY = snap(currentY, grid: grid)
        if !passiveInstances.isEmpty {
            currentY += passiveHeight + cellSpacing
        }

        let pmosY = snap(currentY, grid: grid)
        if !pmosInstances.isEmpty {
            currentY += pmosHeight + cellSpacing
        }

        let vddRailY = snap(currentY, grid: grid)
        let totalHeight = vddRailY + railHeight

        // Place cells in each row
        var placements: [UUID: LayoutTransform] = [:]
        var maxRowWidth = 0.0

        let nmosWidth = placeRow(nmosInstances, y: nmosY, spacing: cellSpacing, grid: grid, placements: &placements)
        let passiveWidth = placeRow(passiveInstances, y: passiveY, spacing: cellSpacing, grid: grid, placements: &placements)
        let pmosWidth = placeRow(pmosInstances, y: pmosY, spacing: cellSpacing, grid: grid, placements: &placements)
        maxRowWidth = max(nmosWidth, passiveWidth, pmosWidth)
        let totalWidth = snap(max(maxRowWidth, 2.0), grid: grid)

        // Generate power rails
        var powerRails: [LayoutShape] = []

        // VSS rail (bottom)
        let vssRect = LayoutRect(
            origin: LayoutPoint(x: 0, y: vssRailY),
            size: LayoutSize(width: totalWidth, height: railHeight)
        )
        powerRails.append(LayoutShape(layer: m1ID, geometry: .rect(vssRect)))

        // VDD rail (top)
        let vddRect = LayoutRect(
            origin: LayoutPoint(x: 0, y: vddRailY),
            size: LayoutSize(width: totalWidth, height: railHeight)
        )
        powerRails.append(LayoutShape(layer: m1ID, geometry: .rect(vddRect)))

        let bbox = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: totalWidth, height: totalHeight)
        )

        return PlacementResult(
            placements: placements,
            powerRails: powerRails,
            totalBoundingBox: bbox
        )
    }

    // MARK: - Helpers

    private func buildAdjacency(
        instances: [PlacementInstance],
        nets: [PlacementNet]
    ) -> [UUID: [UUID: Int]] {
        var adj: [UUID: [UUID: Int]] = [:]
        let ids = Set(instances.map(\.id))

        for net in nets {
            let connectedIDs = net.pinConnections
                .map(\.instanceID)
                .filter { ids.contains($0) }
            for i in 0..<connectedIDs.count {
                for j in (i + 1)..<connectedIDs.count {
                    let a = connectedIDs[i]
                    let b = connectedIDs[j]
                    adj[a, default: [:]][b, default: 0] += 1
                    adj[b, default: [:]][a, default: 0] += 1
                }
            }
        }
        return adj
    }

    private func orderByConnectivity(
        _ instances: [PlacementInstance],
        adjacency: [UUID: [UUID: Int]]
    ) -> [PlacementInstance] {
        guard instances.count > 1 else { return instances }

        var remaining = instances
        var ordered: [PlacementInstance] = []

        // Start with the instance that has the most connections
        remaining.sort { a, b in
            let aConns = adjacency[a.id]?.values.reduce(0, +) ?? 0
            let bConns = adjacency[b.id]?.values.reduce(0, +) ?? 0
            return aConns > bConns
        }

        ordered.append(remaining.removeFirst())

        while !remaining.isEmpty {
            guard let lastID = ordered.last?.id else {
                ordered.append(remaining.removeFirst())
                continue
            }
            let neighbors = adjacency[lastID] ?? [:]

            // Find the remaining instance with highest connectivity to the last placed
            if let bestIdx = remaining.indices.max(by: { a, b in
                (neighbors[remaining[a].id] ?? 0) < (neighbors[remaining[b].id] ?? 0)
            }) {
                ordered.append(remaining.remove(at: bestIdx))
            } else {
                ordered.append(remaining.removeFirst())
            }
        }
        return ordered
    }

    private func maxCellHeight(_ instances: [PlacementInstance]) -> Double {
        instances.map { cellBoundingBox($0.cell).size.height }.max() ?? 0
    }

    private func cellBoundingBox(_ cell: LayoutCell) -> LayoutRect {
        var boxes = cell.shapes.map { geometryBounds($0.geometry) }
        boxes.append(contentsOf: cell.pins.map(pinBounds))
        guard let first = boxes.first else {
            return .zero
        }
        var bbox = first
        for box in boxes.dropFirst() {
            bbox = bbox.union(box)
        }
        return bbox
    }

    private func pinBounds(_ pin: LayoutPin) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(
                x: pin.position.x - pin.size.width / 2,
                y: pin.position.y - pin.size.height / 2
            ),
            size: pin.size
        )
    }

    private func geometryBounds(_ geometry: LayoutGeometry) -> LayoutRect {
        switch geometry {
        case .rect(let r):
            return r
        case .polygon(let p):
            guard let firstPt = p.points.first else { return .zero }
            var minX = firstPt.x, minY = firstPt.y
            var maxX = firstPt.x, maxY = firstPt.y
            for pt in p.points.dropFirst() {
                minX = min(minX, pt.x)
                minY = min(minY, pt.y)
                maxX = max(maxX, pt.x)
                maxY = max(maxY, pt.y)
            }
            return LayoutRect(
                origin: LayoutPoint(x: minX, y: minY),
                size: LayoutSize(width: maxX - minX, height: maxY - minY)
            )
        case .path(let p):
            guard let firstPt = p.points.first else { return .zero }
            var minX = firstPt.x, minY = firstPt.y
            var maxX = firstPt.x, maxY = firstPt.y
            for pt in p.points.dropFirst() {
                minX = min(minX, pt.x)
                minY = min(minY, pt.y)
                maxX = max(maxX, pt.x)
                maxY = max(maxY, pt.y)
            }
            let hw = p.width / 2
            return LayoutRect(
                origin: LayoutPoint(x: minX - hw, y: minY - hw),
                size: LayoutSize(width: maxX - minX + p.width, height: maxY - minY + p.width)
            )
        }
    }

    @discardableResult
    private func placeRow(
        _ instances: [PlacementInstance],
        y: Double,
        spacing: Double,
        grid: Double,
        placements: inout [UUID: LayoutTransform]
    ) -> Double {
        var currentX = 0.0
        for inst in instances {
            let bbox = cellBoundingBox(inst.cell)
            let tx = snap(currentX - bbox.origin.x, grid: grid)
            let ty = snap(y - bbox.origin.y, grid: grid)
            placements[inst.id] = LayoutTransform(
                translation: LayoutPoint(x: tx, y: ty)
            )
            currentX = snap(currentX + bbox.size.width + spacing, grid: grid)
        }
        return currentX
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }
}
