import Foundation
import LayoutCore
import LayoutTech

/// Cost function weights for simulated annealing placement.
public struct CostWeights: Sendable {
    public var hpwl: Double
    public var area: Double
    public var overlap: Double
    public var symmetry: Double
    public var matching: Double
    public var commonCentroid: Double
    public var interdigitated: Double

    public init(
        hpwl: Double = 1.0,
        area: Double = 0.3,
        overlap: Double = 10.0,
        symmetry: Double = 5.0,
        matching: Double = 5.0,
        commonCentroid: Double = 5.0,
        interdigitated: Double = 5.0
    ) {
        self.hpwl = hpwl
        self.area = area
        self.overlap = overlap
        self.symmetry = symmetry
        self.matching = matching
        self.commonCentroid = commonCentroid
        self.interdigitated = interdigitated
    }
}

/// Baseline values for normalizing each cost term so that weights represent
/// true relative importance regardless of physical scale.
struct CostNormalization: Sendable {
    var hpwl: Double = 1.0
    var area: Double = 1.0
    var overlap: Double = 1.0
    var symmetry: Double = 1.0
    var matching: Double = 1.0
    var commonCentroid: Double = 1.0
    var interdigitated: Double = 1.0

    /// Scale-aware epsilon: uses a fraction of the actual baseline instead of a fixed constant.
    func normalize(_ raw: Double, baseline: Double) -> Double {
        guard baseline > 0 else { return raw }
        return raw / baseline
    }
}

/// Spatial hash grid for O(1) amortized overlap queries.
struct SpatialGrid: Sendable {
    let cellSize: Double
    let originX: Double
    let originY: Double
    let cols: Int
    let rows: Int
    var cells: [[UUID]]

    init(bounds: LayoutRect, cellSize: Double) {
        self.cellSize = max(cellSize, 0.01)
        self.originX = bounds.minX - cellSize
        self.originY = bounds.minY - cellSize
        let w = bounds.size.width + 2 * cellSize
        let h = bounds.size.height + 2 * cellSize
        self.cols = max(1, Int(ceil(w / self.cellSize)))
        self.rows = max(1, Int(ceil(h / self.cellSize)))
        self.cells = Array(repeating: [], count: self.cols * self.rows)
    }

    private func gridRange(for rect: LayoutRect) -> (colMin: Int, colMax: Int, rowMin: Int, rowMax: Int) {
        let colMin = max(0, Int(floor((rect.minX - originX) / cellSize)))
        let colMax = min(cols - 1, Int(floor((rect.maxX - originX) / cellSize)))
        let rowMin = max(0, Int(floor((rect.minY - originY) / cellSize)))
        let rowMax = min(rows - 1, Int(floor((rect.maxY - originY) / cellSize)))
        return (colMin, colMax, rowMin, rowMax)
    }

    mutating func insert(_ id: UUID, bbox: LayoutRect) {
        let (colMin, colMax, rowMin, rowMax) = gridRange(for: bbox)
        guard colMin <= colMax, rowMin <= rowMax else { return }
        for r in rowMin...rowMax {
            for c in colMin...colMax {
                cells[r * cols + c].append(id)
            }
        }
    }

    mutating func remove(_ id: UUID, bbox: LayoutRect) {
        let (colMin, colMax, rowMin, rowMax) = gridRange(for: bbox)
        guard colMin <= colMax, rowMin <= rowMax else { return }
        for r in rowMin...rowMax {
            for c in colMin...colMax {
                cells[r * cols + c].removeAll { $0 == id }
            }
        }
    }

    func neighbors(of bbox: LayoutRect) -> Set<UUID> {
        var result = Set<UUID>()
        let (colMin, colMax, rowMin, rowMax) = gridRange(for: bbox)
        guard colMin <= colMax, rowMin <= rowMax else { return result }
        for r in rowMin...rowMax {
            for c in colMin...colMax {
                for id in cells[r * cols + c] {
                    result.insert(id)
                }
            }
        }
        return result
    }
}

/// Snapshot of incremental cost caches for revert on move rejection.
struct CacheDelta: Sendable {
    var previousNetBBoxes: [Int: NetBBox?] = [:]
    var previousInstanceBBoxes: [UUID: LayoutRect] = [:]
    var previousHPWL: Double = 0
    var previousOverlapPenalty: Double = 0
}

/// Compact net bounding box.
struct NetBBox: Sendable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var hpwl: Double { (maxX - minX) + (maxY - minY) }
}

/// Evaluates placement cost for the SA placement engine.
///
/// All cost terms are normalized by their initial baseline values so that
/// weights represent true relative importance regardless of physical scale.
struct SACostFunction: Sendable {
    let nets: [PlacementNet]
    let tech: LayoutTechDatabase
    let constraints: [LayoutConstraint]
    let weights: CostWeights
    private(set) var normalization: CostNormalization

    // Fixed symmetry axes (computed once during calibration)
    private var resolvedSymmetryAxes: [Int: Double] = [:]

    // Incremental cost caches
    private var instanceToNetIndices: [UUID: [Int]] = [:]
    private var cachedNetBBoxes: [Int: NetBBox?] = [:]
    private var spatialGrid: SpatialGrid?
    private var instanceBBoxes: [UUID: LayoutRect] = [:]
    private var cachedHPWL: Double = 0
    private var cachedOverlapPenalty: Double = 0
    private var minSpacing: Double = 0.28

    init(
        nets: [PlacementNet],
        tech: LayoutTechDatabase,
        constraints: [LayoutConstraint],
        weights: CostWeights
    ) {
        self.nets = nets
        self.tech = tech
        self.constraints = constraints
        self.weights = weights
        self.normalization = CostNormalization()
        self.minSpacing = tech.ruleSet(for: LayoutLayerID(name: "ACTIVE", purpose: "drawing"))?.minSpacing ?? 0.28
    }

    /// Calibrates normalization baselines from the initial placement state.
    /// Must be called once before the SA loop begins.
    mutating func calibrate(initialState: SAPlacementState) {
        // Resolve symmetry axes (fixed for the entire SA run)
        resolvedSymmetryAxes = [:]
        for (idx, constraint) in constraints.enumerated() {
            if case .symmetry(let sym) = constraint {
                if let explicit = sym.axisPosition {
                    resolvedSymmetryAxes[idx] = explicit
                } else {
                    let positions = sym.members.compactMap { id -> Double? in
                        guard let slot = initialState.slots[id] else { return nil }
                        let bbox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)
                        return sym.axis == .vertical ? bbox.center.x : bbox.center.y
                    }
                    if !positions.isEmpty {
                        resolvedSymmetryAxes[idx] = positions.reduce(0, +) / Double(positions.count)
                    }
                }
            }
        }

        // Build instance-to-net index
        instanceToNetIndices = [:]
        for (netIdx, net) in nets.enumerated() {
            for conn in net.pinConnections {
                instanceToNetIndices[conn.instanceID, default: []].append(netIdx)
            }
        }

        // Initialize cached net bounding boxes
        for (netIdx, net) in nets.enumerated() {
            cachedNetBBoxes[netIdx] = computeNetBBox(net, state: initialState)
        }
        cachedHPWL = nets.enumerated().reduce(0.0) { total, pair in
            total + (cachedNetBBoxes[pair.offset]??.hpwl ?? 0)
        }

        // Build spatial grid
        let allBounds = computeGlobalBBox(state: initialState)
        let gridCellSize = max(
            instanceBBoxWidth(state: initialState) * 2,
            tech.grid * 50
        )
        spatialGrid = SpatialGrid(bounds: allBounds, cellSize: gridCellSize)
        instanceBBoxes = [:]
        for (id, slot) in initialState.slots {
            let bbox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)
            instanceBBoxes[id] = bbox
            spatialGrid?.insert(id, bbox: bbox)
        }
        cachedOverlapPenalty = computeOverlapFromGrid(state: initialState)

        // Compute normalization baselines using random-move sampling for zero-baseline robustness
        let hpwlVal = cachedHPWL
        let areaVal = computeArea(state: initialState)
        let overlapVal = cachedOverlapPenalty
        let symVal = computeSymmetryPenalty(state: initialState)
        let matchVal = computeMatchingPenalty(state: initialState)
        let ccVal = computeCommonCentroidPenalty(state: initialState)
        let idgVal = computeInterdigitatedPenalty(state: initialState)

        // Use max(value, scaleEstimate) to avoid zero-baseline explosion
        let scaleEstimate = max(hpwlVal * 0.01, tech.grid)
        normalization.hpwl = max(hpwlVal, scaleEstimate)
        normalization.area = max(areaVal, scaleEstimate * scaleEstimate)
        normalization.overlap = max(overlapVal, scaleEstimate * scaleEstimate)
        normalization.symmetry = max(symVal, scaleEstimate * scaleEstimate)
        normalization.matching = max(matchVal, scaleEstimate)
        normalization.commonCentroid = max(ccVal, scaleEstimate * scaleEstimate)
        normalization.interdigitated = max(idgVal, scaleEstimate)
    }

    /// Computes the full normalized cost for a given placement state.
    func cost(for state: SAPlacementState) -> Double {
        let n = normalization
        let hpwl = computeHPWL(state: state)
        let area = computeArea(state: state)
        let overlap = computeOverlapPenalty(state: state)
        let sym = computeSymmetryPenalty(state: state)
        let match = computeMatchingPenalty(state: state)
        let cc = computeCommonCentroidPenalty(state: state)
        let idg = computeInterdigitatedPenalty(state: state)
        return weights.hpwl * n.normalize(hpwl, baseline: n.hpwl)
            + weights.area * n.normalize(area, baseline: n.area)
            + weights.overlap * n.normalize(overlap, baseline: n.overlap)
            + weights.symmetry * n.normalize(sym, baseline: n.symmetry)
            + weights.matching * n.normalize(match, baseline: n.matching)
            + weights.commonCentroid * n.normalize(cc, baseline: n.commonCentroid)
            + weights.interdigitated * n.normalize(idg, baseline: n.interdigitated)
    }

    // MARK: - Hard Constraint Check

    /// Returns true if all hard constraints are satisfied.
    /// Fast check for immediate move rejection.
    func hardConstraintsSatisfied(state: SAPlacementState, grid: Double) -> Bool {
        let tolerance = grid * 2

        for (idx, constraint) in constraints.enumerated() {
            switch constraint {
            case .symmetry(let sym) where sym.isHard:
                // Self-symmetric members must be within tolerance of fixed axis
                if let axisPos = resolvedSymmetryAxes[idx] {
                    for selfID in sym.selfSymmetricMembers {
                        guard let slot = state.slots[selfID] else { continue }
                        let bbox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)
                        let pos = sym.axis == .vertical ? bbox.center.x : bbox.center.y
                        if abs(pos - axisPos) > tolerance { return false }
                    }
                }

            case .matching(let match) where match.isHard:
                // All members must have same rotation and mirror
                let transforms = match.members.compactMap { state.slots[$0]?.transform }
                guard transforms.count == match.members.count, let ref = transforms.first else { continue }
                for t in transforms.dropFirst() {
                    if t.rotation != ref.rotation || t.mirrorX != ref.mirrorX {
                        return false
                    }
                }

            default:
                continue
            }
        }
        return true
    }

    // MARK: - Incremental Cost

    /// Saves cache snapshot for potential revert.
    func saveCacheSnapshot(movedIDs: Set<UUID>) -> CacheDelta {
        var delta = CacheDelta()
        delta.previousHPWL = cachedHPWL
        delta.previousOverlapPenalty = cachedOverlapPenalty
        let affectedNetIndices = Set(movedIDs.flatMap { instanceToNetIndices[$0] ?? [] })
        for netIdx in affectedNetIndices {
            delta.previousNetBBoxes[netIdx] = cachedNetBBoxes[netIdx] ?? nil
        }
        for id in movedIDs {
            if let bbox = instanceBBoxes[id] {
                delta.previousInstanceBBoxes[id] = bbox
            }
        }
        return delta
    }

    /// Computes cost incrementally after a move affecting movedIDs.
    /// Updates internal caches. Call revertCache() if the move is rejected.
    mutating func applyAndComputeDeltaCost(
        state: SAPlacementState,
        movedIDs: Set<UUID>
    ) -> Double {
        let n = normalization

        // 1. Delta HPWL — only recompute affected nets
        let affectedNetIndices = Set(movedIDs.flatMap { instanceToNetIndices[$0] ?? [] })
        var hpwlDelta = 0.0
        for netIdx in affectedNetIndices {
            let oldHPWL = cachedNetBBoxes[netIdx]??.hpwl ?? 0
            let newBBox = computeNetBBox(nets[netIdx], state: state)
            let newHPWL = newBBox?.hpwl ?? 0
            hpwlDelta += newHPWL - oldHPWL
            cachedNetBBoxes[netIdx] = newBBox
        }
        cachedHPWL += hpwlDelta

        // 2. Delta overlap — spatial grid based
        var overlapDelta = 0.0
        for id in movedIDs {
            guard let slot = state.slots[id] else { continue }
            let oldBBox = instanceBBoxes[id] ?? .zero
            let newBBox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)

            // Remove old position from grid
            spatialGrid?.remove(id, bbox: oldBBox)

            // Subtract old overlaps with neighbors
            let expandedOld = oldBBox.expanded(by: minSpacing, minSpacing)
            let oldNeighbors = spatialGrid?.neighbors(of: expandedOld) ?? []
            for neighborID in oldNeighbors where neighborID != id && !movedIDs.contains(neighborID) {
                guard let nBBox = instanceBBoxes[neighborID] else { continue }
                overlapDelta -= overlapArea(
                    oldBBox.expanded(by: minSpacing / 2, minSpacing / 2),
                    nBBox.expanded(by: minSpacing / 2, minSpacing / 2)
                )
            }

            // Insert new position
            spatialGrid?.insert(id, bbox: newBBox)
            instanceBBoxes[id] = newBBox

            // Add new overlaps with neighbors
            let expandedNew = newBBox.expanded(by: minSpacing, minSpacing)
            let newNeighbors = spatialGrid?.neighbors(of: expandedNew) ?? []
            for neighborID in newNeighbors where neighborID != id && !movedIDs.contains(neighborID) {
                guard let nBBox = instanceBBoxes[neighborID] else { continue }
                overlapDelta += overlapArea(
                    newBBox.expanded(by: minSpacing / 2, minSpacing / 2),
                    nBBox.expanded(by: minSpacing / 2, minSpacing / 2)
                )
            }
        }

        // Handle overlaps between moved instances (when multiple move)
        if movedIDs.count > 1 {
            let movedArray = Array(movedIDs)
            for i in 0..<movedArray.count {
                for j in (i+1)..<movedArray.count {
                    guard let bboxA = instanceBBoxes[movedArray[i]],
                          let bboxB = instanceBBoxes[movedArray[j]] else { continue }
                    overlapDelta += overlapArea(
                        bboxA.expanded(by: minSpacing / 2, minSpacing / 2),
                        bboxB.expanded(by: minSpacing / 2, minSpacing / 2)
                    )
                }
            }
        }

        cachedOverlapPenalty = max(0, cachedOverlapPenalty + overlapDelta)

        // 3. Constraint penalties — full recompute (cheap, O(constraint_size))
        let symPenalty = computeSymmetryPenalty(state: state)
        let matchPenalty = computeMatchingPenalty(state: state)
        let ccPenalty = computeCommonCentroidPenalty(state: state)
        let idgPenalty = computeInterdigitatedPenalty(state: state)

        // 4. Area — full recompute (O(n), cheap)
        let areaPenalty = computeArea(state: state)

        return weights.hpwl * n.normalize(cachedHPWL, baseline: n.hpwl)
            + weights.area * n.normalize(areaPenalty, baseline: n.area)
            + weights.overlap * n.normalize(cachedOverlapPenalty, baseline: n.overlap)
            + weights.symmetry * n.normalize(symPenalty, baseline: n.symmetry)
            + weights.matching * n.normalize(matchPenalty, baseline: n.matching)
            + weights.commonCentroid * n.normalize(ccPenalty, baseline: n.commonCentroid)
            + weights.interdigitated * n.normalize(idgPenalty, baseline: n.interdigitated)
    }

    /// Reverts caches after a rejected move.
    mutating func revertCache(_ delta: CacheDelta) {
        cachedHPWL = delta.previousHPWL
        cachedOverlapPenalty = delta.previousOverlapPenalty
        for (netIdx, bbox) in delta.previousNetBBoxes {
            cachedNetBBoxes[netIdx] = bbox
        }
        for (id, bbox) in delta.previousInstanceBBoxes {
            if let currentBBox = instanceBBoxes[id] {
                spatialGrid?.remove(id, bbox: currentBBox)
            }
            instanceBBoxes[id] = bbox
            spatialGrid?.insert(id, bbox: bbox)
        }
    }

    /// Resyncs all caches from scratch to prevent floating-point drift.
    mutating func resyncCaches(state: SAPlacementState) {
        // Rebuild net bboxes
        for (netIdx, net) in nets.enumerated() {
            cachedNetBBoxes[netIdx] = computeNetBBox(net, state: state)
        }
        cachedHPWL = nets.enumerated().reduce(0.0) { total, pair in
            total + (cachedNetBBoxes[pair.offset]??.hpwl ?? 0)
        }

        // Rebuild spatial grid
        let allBounds = computeGlobalBBox(state: state)
        let gridCellSize = spatialGrid?.cellSize ?? tech.grid * 50
        spatialGrid = SpatialGrid(bounds: allBounds, cellSize: gridCellSize)
        instanceBBoxes = [:]
        for (id, slot) in state.slots {
            let bbox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)
            instanceBBoxes[id] = bbox
            spatialGrid?.insert(id, bbox: bbox)
        }
        cachedOverlapPenalty = computeOverlapFromGrid(state: state)
    }

    // MARK: - HPWL

    private func computeHPWL(state: SAPlacementState) -> Double {
        var total = 0.0
        for net in nets {
            total += netHPWL(net, state: state)
        }
        return total
    }

    private func netHPWL(_ net: PlacementNet, state: SAPlacementState) -> Double {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var count = 0

        for conn in net.pinConnections {
            guard let slot = state.slots[conn.instanceID] else { continue }
            let cell = slot.cell
            guard let pin = cell.pins.first(where: { $0.name == conn.pinName }) else { continue }
            let absPos = slot.transform.apply(to: pin.position)
            minX = min(minX, absPos.x)
            minY = min(minY, absPos.y)
            maxX = max(maxX, absPos.x)
            maxY = max(maxY, absPos.y)
            count += 1
        }

        guard count >= 2 else { return 0 }
        return (maxX - minX) + (maxY - minY)
    }

    private func computeNetBBox(_ net: PlacementNet, state: SAPlacementState) -> NetBBox? {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var count = 0
        for conn in net.pinConnections {
            guard let slot = state.slots[conn.instanceID] else { continue }
            guard let pin = slot.cell.pins.first(where: { $0.name == conn.pinName }) else { continue }
            let absPos = slot.transform.apply(to: pin.position)
            minX = min(minX, absPos.x)
            minY = min(minY, absPos.y)
            maxX = max(maxX, absPos.x)
            maxY = max(maxY, absPos.y)
            count += 1
        }
        guard count >= 2 else { return nil }
        return NetBBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    // MARK: - Area

    private func computeArea(state: SAPlacementState) -> Double {
        var bbox: LayoutRect?
        for slot in state.slots.values {
            let cellBBox = cellBoundingBox(slot.cell)
            let transformed = transformedBoundingBox(cellBBox, transform: slot.transform)
            bbox = bbox.map { $0.union(transformed) } ?? transformed
        }
        guard let b = bbox else { return 0 }
        return b.size.width * b.size.height
    }

    // MARK: - Overlap Penalty

    private func computeOverlapPenalty(state: SAPlacementState) -> Double {
        var penalty = 0.0
        let allSlots = Array(state.slots.values)
        for i in 0..<allSlots.count {
            let bboxA = transformedBoundingBox(
                cellBoundingBox(allSlots[i].cell),
                transform: allSlots[i].transform
            )
            for j in (i + 1)..<allSlots.count {
                let bboxB = transformedBoundingBox(
                    cellBoundingBox(allSlots[j].cell),
                    transform: allSlots[j].transform
                )
                penalty += overlapArea(
                    bboxA.expanded(by: minSpacing / 2, minSpacing / 2),
                    bboxB.expanded(by: minSpacing / 2, minSpacing / 2)
                )
            }
        }
        return penalty
    }

    /// Grid-based overlap computation using spatial hash.
    private func computeOverlapFromGrid(state: SAPlacementState) -> Double {
        guard let grid = spatialGrid else { return computeOverlapPenalty(state: state) }
        var penalty = 0.0
        var checked = Set<String>()
        for (id, bbox) in instanceBBoxes {
            let expanded = bbox.expanded(by: minSpacing, minSpacing)
            let neighbors = grid.neighbors(of: expanded)
            for neighborID in neighbors where neighborID != id {
                let pairKey = id < neighborID
                    ? "\(id)-\(neighborID)"
                    : "\(neighborID)-\(id)"
                guard !checked.contains(pairKey) else { continue }
                checked.insert(pairKey)
                guard let nBBox = instanceBBoxes[neighborID] else { continue }
                penalty += overlapArea(
                    bbox.expanded(by: minSpacing / 2, minSpacing / 2),
                    nBBox.expanded(by: minSpacing / 2, minSpacing / 2)
                )
            }
        }
        return penalty
    }

    private func overlapArea(_ a: LayoutRect, _ b: LayoutRect) -> Double {
        let ox = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let oy = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        return ox * oy
    }

    // MARK: - Symmetry Penalty

    private func computeSymmetryPenalty(state: SAPlacementState) -> Double {
        var penalty = 0.0
        for (idx, constraint) in constraints.enumerated() {
            if case .symmetry(let sym) = constraint {
                let axisPos = resolvedSymmetryAxes[idx]
                penalty += symmetryViolation(sym, state: state, fixedAxisPosition: axisPos)
            }
        }
        return penalty
    }

    // MARK: - Matching Penalty

    private func computeMatchingPenalty(state: SAPlacementState) -> Double {
        var penalty = 0.0
        for constraint in constraints {
            if case .matching(let match) = constraint {
                penalty += matchingViolation(match, state: state)
            }
        }
        return penalty
    }

    private func matchingViolation(
        _ constraint: LayoutMatchingConstraint,
        state: SAPlacementState
    ) -> Double {
        let members = constraint.members.compactMap { id -> (UUID, SAPlacementState.SlotEntry)? in
            guard let slot = state.slots[id] else { return nil }
            return (id, slot)
        }
        guard members.count >= 2 else { return 0 }

        var penalty = 0.0

        // Penalize rotation/mirror mismatches within the group
        let refRotation = members[0].1.transform.rotation
        let refMirror = members[0].1.transform.mirrorX
        for i in 1..<members.count {
            if members[i].1.transform.rotation != refRotation {
                penalty += 1.0
            }
            if members[i].1.transform.mirrorX != refMirror {
                penalty += 1.0
            }
        }

        // Penalize Y-coordinate deviations (matched devices should be at same Y)
        let avgY = members.map { slot in
            let bbox = transformedBoundingBox(cellBoundingBox(slot.1.cell), transform: slot.1.transform)
            return bbox.center.y
        }.reduce(0, +) / Double(members.count)

        for member in members {
            let bbox = transformedBoundingBox(cellBoundingBox(member.1.cell), transform: member.1.transform)
            let dy = bbox.center.y - avgY
            penalty += dy * dy
        }

        return penalty
    }

    // MARK: - Common Centroid Penalty

    private func computeCommonCentroidPenalty(state: SAPlacementState) -> Double {
        var penalty = 0.0
        for constraint in constraints {
            if case .commonCentroid(let cc) = constraint {
                penalty += commonCentroidViolation(cc, state: state)
            }
        }
        return penalty
    }

    private func commonCentroidViolation(
        _ constraint: LayoutCommonCentroidConstraint,
        state: SAPlacementState
    ) -> Double {
        let members = constraint.members.compactMap { id -> (UUID, LayoutPoint)? in
            guard let slot = state.slots[id] else { return nil }
            let bbox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)
            return (id, bbox.center)
        }
        guard members.count >= 2 else { return 0 }

        let cx = members.map(\.1.x).reduce(0, +) / Double(members.count)
        let cy = members.map(\.1.y).reduce(0, +) / Double(members.count)

        let pattern = constraint.pattern
        guard !pattern.isEmpty else { return 0 }

        var groups: [Int: [LayoutPoint]] = [:]
        for (i, member) in members.enumerated() {
            let patIdx = i < pattern.count ? pattern[i] : pattern[i % pattern.count]
            groups[patIdx, default: []].append(member.1)
        }

        var penalty = 0.0
        for (_, groupMembers) in groups {
            guard !groupMembers.isEmpty else { continue }
            let gx = groupMembers.map(\.x).reduce(0, +) / Double(groupMembers.count)
            let gy = groupMembers.map(\.y).reduce(0, +) / Double(groupMembers.count)
            let dx = gx - cx
            let dy = gy - cy
            penalty += dx * dx + dy * dy
        }

        return penalty
    }

    // MARK: - Interdigitated Penalty

    private func computeInterdigitatedPenalty(state: SAPlacementState) -> Double {
        var penalty = 0.0
        for constraint in constraints {
            if case .interdigitated(let id) = constraint {
                penalty += interdigitatedViolation(id, state: state)
            }
        }
        return penalty
    }

    private func interdigitatedViolation(
        _ constraint: LayoutInterdigitatedConstraint,
        state: SAPlacementState
    ) -> Double {
        let members: [(UUID, LayoutPoint)] = constraint.members.compactMap { id in
            guard let slot = state.slots[id] else { return nil }
            let bbox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)
            return (id, bbox.center)
        }
        guard members.count >= 2 else { return 0 }

        let pattern = constraint.pattern
        guard !pattern.isEmpty else { return 0 }

        let sorted = members.sorted { $0.1.x < $1.1.x }

        var penalty = 0.0
        for (i, member) in sorted.enumerated() {
            let expectedPatIdx = i < pattern.count ? pattern[i] : pattern[i % pattern.count]
            if let origIdx = constraint.members.firstIndex(of: member.0) {
                let actualPatIdx = origIdx < pattern.count ? pattern[origIdx] : pattern[origIdx % pattern.count]
                if actualPatIdx != expectedPatIdx {
                    penalty += 1.0
                }
            }
        }

        if sorted.count >= 2 {
            let spacings = (1..<sorted.count).map { sorted[$0].1.x - sorted[$0 - 1].1.x }
            let avgSpacing = spacings.reduce(0, +) / Double(spacings.count)
            for s in spacings {
                let dev = s - avgSpacing
                penalty += dev * dev
            }
        }

        return penalty
    }

    // MARK: - Symmetry Violation (with fixed axis)

    private func symmetryViolation(
        _ constraint: LayoutSymmetryConstraint,
        state: SAPlacementState,
        fixedAxisPosition: Double?
    ) -> Double {
        var validMembers: [SAPlacementState.SlotEntry] = []
        var validIndices: [Int] = []
        for (idx, memberID) in constraint.members.enumerated() {
            if let slot = state.slots[memberID] {
                validMembers.append(slot)
                validIndices.append(idx)
            }
        }
        guard validMembers.count >= 2 else { return 0 }

        let centroids = validMembers.map { slot -> LayoutPoint in
            let bbox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)
            return bbox.center
        }

        // Use fixed axis position (resolved at calibration time) instead of dynamic centroid
        let axisPos: Double
        if let fixed = fixedAxisPosition {
            axisPos = fixed
        } else {
            // Fallback: compute from current positions (should not happen after calibrate)
            let count = Double(centroids.count)
            if constraint.axis == .vertical {
                let sumX: Double = centroids.map(\.x).reduce(0, +)
                axisPos = sumX / count
            } else {
                let sumY: Double = centroids.map(\.y).reduce(0, +)
                axisPos = sumY / count
            }
        }

        var penalty = 0.0
        var paired = Set<Int>()
        for k in 0..<validMembers.count {
            guard !paired.contains(k) else { continue }
            let origIdx = validIndices[k]
            let partnerOrigIdx = origIdx % 2 == 0 ? origIdx + 1 : origIdx - 1
            guard let partnerK = validIndices.firstIndex(of: partnerOrigIdx),
                  !paired.contains(partnerK) else { continue }
            paired.insert(k)
            paired.insert(partnerK)

            switch constraint.axis {
            case .vertical:
                let dx = centroids[k].x + centroids[partnerK].x - 2 * axisPos
                let dy = centroids[k].y - centroids[partnerK].y
                penalty += dx * dx + dy * dy
            case .horizontal:
                let dy = centroids[k].y + centroids[partnerK].y - 2 * axisPos
                let dx = centroids[k].x - centroids[partnerK].x
                penalty += dx * dx + dy * dy
            }
        }

        // Self-symmetric members: penalize deviation from axis
        for selfID in constraint.selfSymmetricMembers {
            guard let slot = state.slots[selfID] else { continue }
            let bbox = transformedBoundingBox(cellBoundingBox(slot.cell), transform: slot.transform)
            let center = bbox.center
            let deviation: Double
            switch constraint.axis {
            case .vertical:
                deviation = center.x - axisPos
            case .horizontal:
                deviation = center.y - axisPos
            }
            penalty += deviation * deviation
        }

        return penalty
    }

    // MARK: - Geometry Helpers

    private func cellBoundingBox(_ cell: LayoutCell) -> LayoutRect {
        var bbox: LayoutRect?
        for shape in cell.shapes {
            let shapeBBox = LayoutGeometryUtils.boundingBox(for: shape.geometry)
            bbox = bbox.map { $0.union(shapeBBox) } ?? shapeBBox
        }
        return bbox ?? .zero
    }

    private func transformedBoundingBox(_ rect: LayoutRect, transform: LayoutTransform) -> LayoutRect {
        let corners = [
            LayoutPoint(x: rect.minX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.maxY),
            LayoutPoint(x: rect.minX, y: rect.maxY),
        ]
        let transformed = corners.map { transform.apply(to: $0) }
        guard let first = transformed.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in transformed.dropFirst() {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func computeGlobalBBox(state: SAPlacementState) -> LayoutRect {
        var bbox: LayoutRect?
        for slot in state.slots.values {
            let cellBBox = cellBoundingBox(slot.cell)
            let transformed = transformedBoundingBox(cellBBox, transform: slot.transform)
            bbox = bbox.map { $0.union(transformed) } ?? transformed
        }
        return bbox ?? .zero
    }

    private func instanceBBoxWidth(state: SAPlacementState) -> Double {
        state.slots.values.map { slot in
            cellBoundingBox(slot.cell).size.width
        }.max() ?? 1.0
    }
}
