import Foundation
import LayoutCore
import LayoutTech

// MARK: - Saved Move State

/// Captures positions of all instances affected by a move for exact revert.
struct SavedMoveState: Sendable {
    var positions: [UUID: LayoutPoint]            // translation
    var rotationDegrees: [UUID: Double]
    var magnifications: [UUID: Double]
    var mirrors: [UUID: Bool]                     // mirrorX

    init() {
        positions = [:]
        rotationDegrees = [:]
        magnifications = [:]
        mirrors = [:]
    }

    mutating func save(instanceID: UUID, from state: SAPlacementState) {
        guard let slot = state.slots[instanceID] else { return }
        positions[instanceID] = slot.transform.translation
        rotationDegrees[instanceID] = slot.transform.rotationDegrees
        magnifications[instanceID] = slot.transform.magnification
        mirrors[instanceID] = slot.transform.mirrorX
    }
}

// MARK: - Placement State

/// Internal mutable state for the SA placement optimization.
struct SAPlacementState: Sendable {
    struct SlotEntry: Sendable {
        var instanceID: UUID
        var cell: LayoutCell
        var transform: LayoutTransform
        var rowType: DeviceType
    }

    var slots: [UUID: SlotEntry]
    var rowAssignments: [DeviceType: [UUID]]

    /// Applies a move to the state, mutating it in place.
    mutating func apply(_ move: SAMove, grid: Double) {
        switch move {
        case .swap(let a, let b):
            guard var slotA = slots[a], var slotB = slots[b] else { return }
            let tempTransform = slotA.transform
            slotA.transform = LayoutTransform(
                translation: LayoutPoint(
                    x: slotB.transform.translation.x,
                    y: slotA.transform.translation.y
                ),
                rotationDegrees: slotA.transform.rotationDegrees,
                magnification: slotA.transform.magnification,
                mirrorX: slotA.transform.mirrorX,
                mirrorY: slotA.transform.mirrorY
            )
            slotB.transform = LayoutTransform(
                translation: LayoutPoint(
                    x: tempTransform.translation.x,
                    y: slotB.transform.translation.y
                ),
                rotationDegrees: slotB.transform.rotationDegrees,
                magnification: slotB.transform.magnification,
                mirrorX: slotB.transform.mirrorX,
                mirrorY: slotB.transform.mirrorY
            )
            slots[a] = slotA
            slots[b] = slotB

            if slotA.rowType == slotB.rowType {
                if var row = rowAssignments[slotA.rowType],
                   let idxA = row.firstIndex(of: a),
                   let idxB = row.firstIndex(of: b) {
                    row.swapAt(idxA, idxB)
                    rowAssignments[slotA.rowType] = row
                }
            }

        case .shift(let inst, let dx):
            guard var slot = slots[inst] else { return }
            let newX = snap(slot.transform.translation.x + dx, grid: grid)
            slot.transform = LayoutTransform(
                translation: LayoutPoint(x: newX, y: slot.transform.translation.y),
                rotationDegrees: slot.transform.rotationDegrees,
                magnification: slot.transform.magnification,
                mirrorX: slot.transform.mirrorX,
                mirrorY: slot.transform.mirrorY
            )
            slots[inst] = slot

        case .shiftY(let inst, let dy):
            guard var slot = slots[inst] else { return }
            let newY = snap(slot.transform.translation.y + dy, grid: grid)
            slot.transform = LayoutTransform(
                translation: LayoutPoint(x: slot.transform.translation.x, y: newY),
                rotationDegrees: slot.transform.rotationDegrees,
                magnification: slot.transform.magnification,
                mirrorX: slot.transform.mirrorX,
                mirrorY: slot.transform.mirrorY
            )
            slots[inst] = slot

        case .rotate(let inst):
            guard var slot = slots[inst] else { return }
            let nextRotation: LayoutRotation
            switch slot.transform.rotation {
            case .deg0: nextRotation = .deg90
            case .deg90: nextRotation = .deg180
            case .deg180: nextRotation = .deg270
            case .deg270: nextRotation = .deg0
            }
            slot.transform = LayoutTransform(
                translation: slot.transform.translation,
                rotation: nextRotation,
                magnification: slot.transform.magnification,
                mirrorX: slot.transform.mirrorX,
                mirrorY: slot.transform.mirrorY
            )
            slots[inst] = slot

        case .mirror(let inst):
            guard var slot = slots[inst] else { return }
            slot.transform = LayoutTransform(
                translation: slot.transform.translation,
                rotationDegrees: slot.transform.rotationDegrees,
                magnification: slot.transform.magnification,
                mirrorX: !slot.transform.mirrorX,
                mirrorY: slot.transform.mirrorY
            )
            slots[inst] = slot

        case .symmetricShift(let a, let b, let dx):
            // a shifts +dx, b shifts -dx (preserves center)
            applyShiftTo(a, dx: dx, grid: grid)
            applyShiftTo(b, dx: -dx, grid: grid)

        case .symmetricShiftY(let a, let b, let dy):
            // Both shift by same dy
            applyShiftYTo(a, dy: dy, grid: grid)
            applyShiftYTo(b, dy: dy, grid: grid)

        case .groupSwap(let a, let b, let partnerA, let partnerB):
            // Swap a↔b and partnerA↔partnerB
            apply(.swap(a: a, b: b), grid: grid)
            apply(.swap(a: partnerA, b: partnerB), grid: grid)
        }
    }

    private mutating func applyShiftTo(_ inst: UUID, dx: Double, grid: Double) {
        guard var slot = slots[inst] else { return }
        let newX = snap(slot.transform.translation.x + dx, grid: grid)
        slot.transform = LayoutTransform(
            translation: LayoutPoint(x: newX, y: slot.transform.translation.y),
            rotationDegrees: slot.transform.rotationDegrees,
            magnification: slot.transform.magnification,
            mirrorX: slot.transform.mirrorX,
            mirrorY: slot.transform.mirrorY
        )
        slots[inst] = slot
    }

    private mutating func applyShiftYTo(_ inst: UUID, dy: Double, grid: Double) {
        guard var slot = slots[inst] else { return }
        let newY = snap(slot.transform.translation.y + dy, grid: grid)
        slot.transform = LayoutTransform(
            translation: LayoutPoint(x: slot.transform.translation.x, y: newY),
            rotationDegrees: slot.transform.rotationDegrees,
            magnification: slot.transform.magnification,
            mirrorX: slot.transform.mirrorX,
            mirrorY: slot.transform.mirrorY
        )
        slots[inst] = slot
    }

    /// Saves the state of all instances affected by a move.
    func saveState(for move: SAMove) -> SavedMoveState {
        var saved = SavedMoveState()
        for instID in SAMoveGenerator.movedInstances(for: move) {
            saved.save(instanceID: instID, from: self)
        }
        return saved
    }

    /// Reverts a move by restoring exact saved positions.
    mutating func revert(savedState: SavedMoveState) {
        for (instID, pos) in savedState.positions {
            guard var slot = slots[instID] else { continue }
            slot.transform = LayoutTransform(
                translation: pos,
                rotationDegrees: savedState.rotationDegrees[instID] ?? slot.transform.rotationDegrees,
                magnification: savedState.magnifications[instID] ?? slot.transform.magnification,
                mirrorX: savedState.mirrors[instID] ?? slot.transform.mirrorX,
                mirrorY: slot.transform.mirrorY
            )
            slots[instID] = slot
        }
    }

    /// Legacy revert for backward compatibility.
    mutating func revert(_ move: SAMove, originalX: Double?, grid: Double) {
        switch move {
        case .swap(let a, let b):
            apply(.swap(a: a, b: b), grid: grid)
        case .shift(let inst, _):
            if let origX = originalX {
                guard var slot = slots[inst] else { return }
                slot.transform = LayoutTransform(
                    translation: LayoutPoint(x: origX, y: slot.transform.translation.y),
                    rotationDegrees: slot.transform.rotationDegrees,
                    magnification: slot.transform.magnification,
                    mirrorX: slot.transform.mirrorX,
                    mirrorY: slot.transform.mirrorY
                )
                slots[inst] = slot
            }
        case .rotate(let inst):
            apply(.rotate(instance: inst), grid: grid)
            apply(.rotate(instance: inst), grid: grid)
            apply(.rotate(instance: inst), grid: grid)
        case .mirror(let inst):
            apply(.mirror(instance: inst), grid: grid)
        default:
            break
        }
    }

    /// Converts to PlacementResult with power rail generation.
    func toPlacementResult(tech: LayoutTechDatabase) throws -> PlacementResult {
        var placements: [UUID: LayoutTransform] = [:]
        for (id, slot) in slots {
            placements[id] = slot.transform
        }

        var bbox: LayoutRect?
        for slot in slots.values {
            let cellBBox = Self.cellBoundingBox(slot.cell)
            let transformed = Self.transformedBoundingBox(cellBBox, transform: slot.transform)
            bbox = bbox.map { $0.union(transformed) } ?? transformed
        }
        let totalBBox = bbox ?? .zero

        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m1Rules = try tech.requiredRuleSet(for: m1ID)
        let m1Width = m1Rules.minWidth
        let railHeight = snap(max(m1Width * 3, 0.46), grid: tech.grid)
        let railClearance = snap(m1Rules.minSpacing + tech.grid * 2, grid: tech.grid)

        let totalWidth = snap(max(totalBBox.size.width + 1.0, 2.0), grid: tech.grid)
        let vssY = snap(totalBBox.minY - railHeight - railClearance, grid: tech.grid)
        let vddY = snap(totalBBox.maxY + railClearance, grid: tech.grid)

        let vssRail = LayoutShape(
            layer: m1ID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: totalBBox.minX, y: vssY),
                size: LayoutSize(width: totalWidth, height: railHeight)
            ))
        )
        let vddRail = LayoutShape(
            layer: m1ID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: totalBBox.minX, y: vddY),
                size: LayoutSize(width: totalWidth, height: railHeight)
            ))
        )

        let finalBBox = LayoutRect(
            origin: LayoutPoint(x: totalBBox.minX, y: vssY),
            size: LayoutSize(width: totalWidth, height: vddY + railHeight - vssY)
        )

        return PlacementResult(
            placements: placements,
            powerRails: [vssRail, vddRail],
            totalBoundingBox: finalBBox
        )
    }

    // MARK: - Helpers

    static func cellBoundingBox(_ cell: LayoutCell) -> LayoutRect {
        var boxes = cell.shapes.map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
        boxes.append(contentsOf: cell.pins.map { pin in
            LayoutRect(
                origin: LayoutPoint(
                    x: pin.position.x - pin.size.width / 2,
                    y: pin.position.y - pin.size.height / 2
                ),
                size: pin.size
            )
        })
        var bbox: LayoutRect?
        for box in boxes {
            bbox = bbox.map { $0.union(box) } ?? box
        }
        return bbox ?? .zero
    }

    static func transformedBoundingBox(_ rect: LayoutRect, transform: LayoutTransform) -> LayoutRect {
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

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }
}

// MARK: - Temperature Mode

/// Controls how the initial SA temperature is determined.
public enum TemperatureMode: Sendable {
    /// Use a fixed initial temperature value.
    case fixed(Double)
    /// Calibrate T_init from random moves to achieve target acceptance rate.
    case adaptive(sampleCount: Int, targetAcceptance: Double)
}

// MARK: - SA Placement Engine

/// Simulated annealing placement engine.
///
/// Uses the greedy `RowBasedPlacementEngine` as warm start, then optimizes
/// via SA with normalized cost function and constraint-aware moves.
public struct SAPlacementEngine: PlacementEngine {

    public struct Configuration: Sendable {
        public var initialTemperature: Double
        public var coolingRate: Double
        public var iterationsPerTemperature: Int
        public var minTemperature: Double
        public var weights: CostWeights
        public var maxReheats: Int
        public var temperatureMode: TemperatureMode
        public var randomSeed: UInt64

        public init(
            initialTemperature: Double = 1000.0,
            coolingRate: Double = 0.97,
            iterationsPerTemperature: Int = 0,
            minTemperature: Double = 0.01,
            weights: CostWeights = CostWeights(),
            maxReheats: Int = 3,
            temperatureMode: TemperatureMode = .adaptive(sampleCount: 100, targetAcceptance: 0.95),
            randomSeed: UInt64 = 0x5EED
        ) {
            self.initialTemperature = initialTemperature
            self.coolingRate = coolingRate
            self.iterationsPerTemperature = iterationsPerTemperature
            self.minTemperature = minTemperature
            self.weights = weights
            self.maxReheats = maxReheats
            self.temperatureMode = temperatureMode
            self.randomSeed = randomSeed
        }
    }

    public let configuration: Configuration
    public let constraints: [LayoutConstraint]

    public init(
        configuration: Configuration = Configuration(),
        constraints: [LayoutConstraint] = []
    ) {
        self.configuration = configuration
        self.constraints = constraints
    }

    public func place(
        instances: [PlacementInstance],
        nets: [PlacementNet],
        tech: LayoutTechDatabase
    ) throws -> PlacementResult {
        guard !instances.isEmpty else {
            return PlacementResult(placements: [:], powerRails: [], totalBoundingBox: .zero)
        }

        // 1. Warm start from greedy placement
        let initial = try RowBasedPlacementEngine().place(instances: instances, nets: nets, tech: tech)
        var state = buildInitialState(from: initial, instances: instances)
        alignSelfSymmetricMembers(in: &state, constraints: constraints, grid: tech.grid)

        // 2. Setup cost function and move generator
        var costFn = try SACostFunction(
            nets: nets,
            tech: tech,
            constraints: constraints,
            weights: configuration.weights
        )

        // Calibrate normalization from initial state
        costFn.calibrate(initialState: state)

        let maxCellWidth = instances.map {
            SAPlacementState.cellBoundingBox($0.cell).size.width
        }.max() ?? 1.0
        var moveGen = SAMoveGenerator(
            grid: tech.grid,
            maxCellWidth: maxCellWidth,
            constraints: constraints,
            seed: configuration.randomSeed
        )

        // 3. Determine initial temperature
        let initialTemp: Double
        switch configuration.temperatureMode {
        case .fixed(let t):
            initialTemp = t
        case .adaptive(let sampleCount, let targetAcceptance):
            initialTemp = calibrateTemperature(
                state: &state,
                costFn: costFn,
                moveGen: &moveGen,
                tech: tech,
                sampleCount: sampleCount,
                targetAcceptance: targetAcceptance
            )
        }

        // 4. SA main loop
        let iterationsPerStep = configuration.iterationsPerTemperature > 0
            ? configuration.iterationsPerTemperature
            : max(10 * instances.count, 100)

        var temperature = initialTemp
        var currentCost = costFn.cost(for: state)
        var bestState = state
        var bestCost = currentCost
        var noImprovementSteps = 0
        var reheatCount = 0
        var temperatureStepCount = 0

        while temperature > configuration.minTemperature {
            var improved = false
            var locallyImproved = false

            for _ in 0..<iterationsPerStep {
                guard let move = moveGen.randomMove(
                    state: state,
                    temperature: temperature,
                    maxTemperature: initialTemp
                ) else { continue }

                let movedIDs = SAMoveGenerator.movedInstances(for: move)

                // Save complete state for exact revert
                let saved = state.saveState(for: move)
                let cacheDelta = costFn.saveCacheSnapshot(movedIDs: movedIDs)

                // Apply move
                state.apply(move, grid: tech.grid)

                // Hard constraint fast-reject (skip cost evaluation entirely)
                if !costFn.hardConstraintsSatisfied(state: state, grid: tech.grid) {
                    state.revert(savedState: saved)
                    continue
                }

                // Compute cost incrementally
                let newCost = costFn.applyAndComputeDeltaCost(
                    state: state, movedIDs: movedIDs
                )
                let delta = newCost - currentCost

                // Metropolis acceptance
                if delta < 0 || moveGen.nextUnit() < exp(-delta / temperature) {
                    currentCost = newCost
                    if delta < 0 { locallyImproved = true }
                    if currentCost < bestCost {
                        bestCost = currentCost
                        bestState = state
                        improved = true
                    }
                } else {
                    // Reject: revert state and caches
                    state.revert(savedState: saved)
                    costFn.revertCache(cacheDelta)
                }
            }

            if !improved && !locallyImproved {
                noImprovementSteps += 1
                if noImprovementSteps >= 3 && reheatCount < configuration.maxReheats {
                    temperature = min(temperature * 2.0, initialTemp)
                    reheatCount += 1
                    noImprovementSteps = 0
                    costFn.resyncCaches(state: state)
                    currentCost = costFn.cost(for: state)
                    continue
                }
            } else {
                noImprovementSteps = 0
            }

            temperatureStepCount += 1
            // Periodic resync to prevent floating-point drift
            if temperatureStepCount % 50 == 0 {
                costFn.resyncCaches(state: state)
                currentCost = costFn.cost(for: state)
            }

            temperature *= configuration.coolingRate
        }

        // 5. Convert best state to result
        return try bestState.toPlacementResult(tech: tech)
    }

    // MARK: - Temperature Calibration

    /// Determines T_init such that random uphill moves are accepted with the target probability.
    ///
    /// T_init = -avg_uphill_delta / ln(targetAcceptance)
    private func calibrateTemperature(
        state: inout SAPlacementState,
        costFn: SACostFunction,
        moveGen: inout SAMoveGenerator,
        tech: LayoutTechDatabase,
        sampleCount: Int,
        targetAcceptance: Double
    ) -> Double {
        var uphillDeltas: [Double] = []
        let baseCost = costFn.cost(for: state)

        for _ in 0..<sampleCount {
            guard let move = moveGen.randomMove(
                state: state,
                temperature: 1e6,
                maxTemperature: 1e6
            ) else { continue }

            let saved = state.saveState(for: move)
            state.apply(move, grid: tech.grid)
            let newCost = costFn.cost(for: state)
            let delta = newCost - baseCost
            if delta > 0 {
                uphillDeltas.append(delta)
            }
            state.revert(savedState: saved)
        }

        guard !uphillDeltas.isEmpty else {
            return configuration.initialTemperature
        }

        let avgUphill = uphillDeltas.reduce(0, +) / Double(uphillDeltas.count)
        let t = -avgUphill / log(max(targetAcceptance, 0.01))
        return max(t, configuration.minTemperature * 10)
    }

    // MARK: - State Construction

    private func buildInitialState(
        from result: PlacementResult,
        instances: [PlacementInstance]
    ) -> SAPlacementState {
        var slots: [UUID: SAPlacementState.SlotEntry] = [:]
        var rowAssignments: [DeviceType: [UUID]] = [
            .pmos: [],
            .nmos: [],
            .passive: [],
        ]

        for inst in instances {
            let transform = result.placements[inst.id] ?? LayoutTransform(translation: .zero)
            slots[inst.id] = SAPlacementState.SlotEntry(
                instanceID: inst.id,
                cell: inst.cell,
                transform: transform,
                rowType: inst.deviceType
            )
            rowAssignments[inst.deviceType, default: []].append(inst.id)
        }

        return SAPlacementState(slots: slots, rowAssignments: rowAssignments)
    }

    private func alignSelfSymmetricMembers(
        in state: inout SAPlacementState,
        constraints: [LayoutConstraint],
        grid: Double
    ) {
        for constraint in constraints {
            guard case .symmetry(let symmetry) = constraint,
                  let axisPosition = resolvedAxisPosition(for: symmetry, state: state) else {
                continue
            }

            for memberID in symmetry.selfSymmetricMembers {
                guard var slot = state.slots[memberID] else { continue }
                let bbox = SAPlacementState.transformedBoundingBox(
                    SAPlacementState.cellBoundingBox(slot.cell),
                    transform: slot.transform
                )
                let translation = slot.transform.translation
                let projectedTranslation: LayoutPoint
                switch symmetry.axis {
                case .vertical:
                    projectedTranslation = LayoutPoint(
                        x: snap(translation.x + axisPosition - bbox.center.x, grid: grid),
                        y: translation.y
                    )
                case .horizontal:
                    projectedTranslation = LayoutPoint(
                        x: translation.x,
                        y: snap(translation.y + axisPosition - bbox.center.y, grid: grid)
                    )
                }
                slot.transform = LayoutTransform(
                    translation: projectedTranslation,
                    rotationDegrees: slot.transform.rotationDegrees,
                    magnification: slot.transform.magnification,
                    mirrorX: slot.transform.mirrorX,
                    mirrorY: slot.transform.mirrorY
                )
                state.slots[memberID] = slot
            }
        }
    }

    private func resolvedAxisPosition(
        for symmetry: LayoutSymmetryConstraint,
        state: SAPlacementState
    ) -> Double? {
        if let axisPosition = symmetry.axisPosition {
            return axisPosition
        }

        let centers = symmetry.members.compactMap { memberID -> Double? in
            guard let slot = state.slots[memberID] else { return nil }
            let bbox = SAPlacementState.transformedBoundingBox(
                SAPlacementState.cellBoundingBox(slot.cell),
                transform: slot.transform
            )
            switch symmetry.axis {
            case .vertical:
                return bbox.center.x
            case .horizontal:
                return bbox.center.y
            }
        }
        guard !centers.isEmpty else { return nil }
        return centers.reduce(0, +) / Double(centers.count)
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }
}
