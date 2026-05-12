import Foundation
import LayoutCore

/// A single move in the SA placement search space.
enum SAMove: Sendable {
    /// Swap two instances within the same row.
    case swap(a: UUID, b: UUID)
    /// Shift an instance horizontally by dx (grid-snapped).
    case shift(instance: UUID, dx: Double)
    /// Shift an instance vertically by dy (grid-snapped, clamped to row bands).
    case shiftY(instance: UUID, dy: Double)
    /// Cycle rotation of an instance (0→90→180→270→0).
    case rotate(instance: UUID)
    /// Toggle mirrorX of an instance.
    case mirror(instance: UUID)
    /// Symmetric shift: a shifts +dx, b shifts -dx (preserves center).
    case symmetricShift(a: UUID, b: UUID, dx: Double)
    /// Symmetric Y shift: both shift by same dy.
    case symmetricShiftY(a: UUID, b: UUID, dy: Double)
    /// Group swap: swap (a,b) and their constraint partners (partnerA, partnerB).
    case groupSwap(a: UUID, b: UUID, partnerA: UUID, partnerB: UUID)
}

/// Pre-computed index of constraint relationships for efficient move generation.
struct ConstraintIndex: Sendable {
    struct SymmetryPartner: Sendable {
        let partner: UUID
        let axis: LayoutSymmetryAxis
    }

    /// Maps instance ID to its symmetry partner (if any).
    var symmetryPartners: [UUID: SymmetryPartner] = [:]
    /// Maps instance ID to the set of instances in its matching group.
    var matchingGroups: [UUID: [UUID]] = [:]
    /// Self-symmetric members that must sit on the axis.
    var selfSymmetricInstances: [UUID: LayoutSymmetryAxis] = [:]
    /// True if any constraints exist.
    var hasConstraints: Bool = false

    init(constraints: [LayoutConstraint]) {
        hasConstraints = !constraints.isEmpty
        for constraint in constraints {
            switch constraint {
            case .symmetry(let sym):
                let members = sym.members
                for i in stride(from: 0, to: members.count - 1, by: 2) {
                    let a = members[i]
                    let b = members[i + 1]
                    symmetryPartners[a] = SymmetryPartner(partner: b, axis: sym.axis)
                    symmetryPartners[b] = SymmetryPartner(partner: a, axis: sym.axis)
                }
                for selfID in sym.selfSymmetricMembers {
                    selfSymmetricInstances[selfID] = sym.axis
                }
            case .matching(let match):
                for memberID in match.members {
                    matchingGroups[memberID] = match.members.filter { $0 != memberID }
                }
            case .commonCentroid, .interdigitated:
                break
            }
        }
    }
}

/// Generates random moves for the SA placement engine.
struct SAMoveGenerator: Sendable {
    let grid: Double
    let maxCellWidth: Double
    let constraintIndex: ConstraintIndex
    private var rng: SeededRandomNumberGenerator

    init(grid: Double, maxCellWidth: Double, constraints: [LayoutConstraint] = [], seed: UInt64) {
        self.grid = grid
        self.maxCellWidth = max(maxCellWidth, grid * 10)
        self.constraintIndex = ConstraintIndex(constraints: constraints)
        self.rng = SeededRandomNumberGenerator(seed: seed)
    }

    /// Generates a random move appropriate for the current temperature.
    mutating func randomMove(
        state: SAPlacementState,
        temperature: Double,
        maxTemperature: Double
    ) -> SAMove? {
        let ratio = temperature / maxTemperature
        let r = Double.random(in: 0..<1, using: &rng)

        if constraintIndex.hasConstraints {
            // With constraints: include symmetry-aware and group moves
            if ratio > 0.5 {
                // Hot: swap 25%, shift 20%, shiftY 10%, symmetricShift 15%, rotate 10%, mirror 10%, groupSwap 10%
                if r < 0.25 {
                    return randomSwap(state: state)
                } else if r < 0.45 {
                    return randomShift(state: state, ratio: ratio)
                } else if r < 0.55 {
                    return randomShiftY(state: state, ratio: ratio)
                } else if r < 0.70 {
                    return randomSymmetricShift(state: state, ratio: ratio)
                } else if r < 0.80 {
                    return randomRotate(state: state)
                } else if r < 0.90 {
                    return randomMirror(state: state)
                } else {
                    return randomGroupSwap(state: state)
                }
            } else {
                // Cold: shift 30%, shiftY 15%, symmetricShift 20%, swap 10%, rotate 10%, mirror 10%, groupSwap 5%
                if r < 0.10 {
                    return randomSwap(state: state)
                } else if r < 0.40 {
                    return randomShift(state: state, ratio: ratio)
                } else if r < 0.55 {
                    return randomShiftY(state: state, ratio: ratio)
                } else if r < 0.75 {
                    return randomSymmetricShift(state: state, ratio: ratio)
                } else if r < 0.85 {
                    return randomRotate(state: state)
                } else if r < 0.95 {
                    return randomMirror(state: state)
                } else {
                    return randomGroupSwap(state: state)
                }
            }
        } else {
            // No constraints: original distribution + shiftY
            if ratio > 0.5 {
                if r < 0.35 {
                    return randomSwap(state: state)
                } else if r < 0.60 {
                    return randomShift(state: state, ratio: ratio)
                } else if r < 0.70 {
                    return randomShiftY(state: state, ratio: ratio)
                } else if r < 0.85 {
                    return randomRotate(state: state)
                } else {
                    return randomMirror(state: state)
                }
            } else {
                if r < 0.10 {
                    return randomSwap(state: state)
                } else if r < 0.50 {
                    return randomShift(state: state, ratio: ratio)
                } else if r < 0.65 {
                    return randomShiftY(state: state, ratio: ratio)
                } else if r < 0.80 {
                    return randomRotate(state: state)
                } else {
                    return randomMirror(state: state)
                }
            }
        }
    }

    /// Returns the set of instance IDs moved by an SAMove.
    static func movedInstances(for move: SAMove) -> Set<UUID> {
        switch move {
        case .swap(let a, let b):
            return [a, b]
        case .shift(let inst, _), .shiftY(let inst, _), .rotate(let inst), .mirror(let inst):
            return [inst]
        case .symmetricShift(let a, let b, _), .symmetricShiftY(let a, let b, _):
            return [a, b]
        case .groupSwap(let a, let b, let pA, let pB):
            return [a, b, pA, pB]
        }
    }

    // MARK: - Move Generators

    mutating func nextUnit() -> Double {
        Double.random(in: 0..<1, using: &rng)
    }

    private mutating func randomSwap(state: SAPlacementState) -> SAMove? {
        let nonEmptyRows = state.rowAssignments.filter { $0.value.count >= 2 }
        guard let (_, ids) = nonEmptyRows.randomElement(using: &rng) else { return nil }
        guard ids.count >= 2 else { return nil }
        let shuffled = ids.shuffled(using: &rng)
        return .swap(a: shuffled[0], b: shuffled[1])
    }

    private mutating func randomShift(state: SAPlacementState, ratio: Double) -> SAMove? {
        guard let (instID, _) = state.slots.randomElement(using: &rng) else { return nil }

        // Self-symmetric instances on vertical axis: only shift along axis (Y only)
        if let selfAxis = constraintIndex.selfSymmetricInstances[instID] {
            if selfAxis == .vertical {
                return randomShiftY(state: state, ratio: ratio, forInstance: instID)
            }
            // horizontal axis: X shift is fine
        }

        let sigma = maxCellWidth * ratio
        let dx = gaussianRandom(sigma: sigma)
        let snappedDx = (dx / grid).rounded() * grid
        guard abs(snappedDx) >= grid else {
            return .shift(instance: instID, dx: grid * (Bool.random(using: &rng) ? 1 : -1))
        }
        return .shift(instance: instID, dx: snappedDx)
    }

    private mutating func randomShiftY(state: SAPlacementState, ratio: Double) -> SAMove? {
        guard let (instID, _) = state.slots.randomElement(using: &rng) else { return nil }
        return randomShiftY(state: state, ratio: ratio, forInstance: instID)
    }

    private mutating func randomShiftY(state: SAPlacementState, ratio: Double, forInstance instID: UUID) -> SAMove? {
        let sigma = maxCellWidth * ratio * 0.5
        let dy = gaussianRandom(sigma: sigma)
        let snappedDy = (dy / grid).rounded() * grid
        guard abs(snappedDy) >= grid else {
            return .shiftY(instance: instID, dy: grid * (Bool.random(using: &rng) ? 1 : -1))
        }
        return .shiftY(instance: instID, dy: snappedDy)
    }

    private mutating func randomSymmetricShift(state: SAPlacementState, ratio: Double) -> SAMove? {
        guard let (instID, _) = state.slots.randomElement(using: &rng) else { return nil }

        // If this is a self-symmetric instance, only shift along the axis
        if let selfAxis = constraintIndex.selfSymmetricInstances[instID] {
            let sigma = maxCellWidth * ratio * 0.5
            switch selfAxis {
            case .vertical:
                // Vertical axis: instance must stay on axis X, only shift Y
                let dy = gaussianRandom(sigma: sigma)
                let snappedDy = (dy / grid).rounded() * grid
                guard abs(snappedDy) >= grid else {
                    return .shiftY(instance: instID, dy: grid * (Bool.random(using: &rng) ? 1 : -1))
                }
                return .shiftY(instance: instID, dy: snappedDy)
            case .horizontal:
                // Horizontal axis: instance must stay on axis Y, only shift X
                let dx = gaussianRandom(sigma: sigma)
                let snappedDx = (dx / grid).rounded() * grid
                guard abs(snappedDx) >= grid else {
                    return .shift(instance: instID, dx: grid * (Bool.random(using: &rng) ? 1 : -1))
                }
                return .shift(instance: instID, dx: snappedDx)
            }
        }

        guard let partner = constraintIndex.symmetryPartners[instID] else {
            // Fallback to normal shift
            return randomShift(state: state, ratio: ratio)
        }
        guard state.slots[partner.partner] != nil else {
            return randomShift(state: state, ratio: ratio)
        }

        let sigma = maxCellWidth * ratio * 0.5
        if partner.axis == .vertical {
            let dx = gaussianRandom(sigma: sigma)
            let snappedDx = (dx / grid).rounded() * grid
            guard abs(snappedDx) >= grid else {
                return .symmetricShift(a: instID, b: partner.partner, dx: grid)
            }
            return .symmetricShift(a: instID, b: partner.partner, dx: snappedDx)
        } else {
            let dy = gaussianRandom(sigma: sigma)
            let snappedDy = (dy / grid).rounded() * grid
            guard abs(snappedDy) >= grid else {
                return .symmetricShiftY(a: instID, b: partner.partner, dy: grid)
            }
            return .symmetricShiftY(a: instID, b: partner.partner, dy: snappedDy)
        }
    }

    private mutating func randomGroupSwap(state: SAPlacementState) -> SAMove? {
        // Try to find two instances with matching partners and swap them
        let nonEmptyRows = state.rowAssignments.filter { $0.value.count >= 2 }
        guard let (_, ids) = nonEmptyRows.randomElement(using: &rng) else { return nil }
        guard ids.count >= 2 else { return nil }

        let shuffled = ids.shuffled(using: &rng)
        let a = shuffled[0]
        let b = shuffled[1]

        if let partnerA = constraintIndex.symmetryPartners[a]?.partner,
           let partnerB = constraintIndex.symmetryPartners[b]?.partner,
           partnerA != b, partnerB != a {
            return .groupSwap(a: a, b: b, partnerA: partnerA, partnerB: partnerB)
        }

        // Fallback to simple swap
        return .swap(a: a, b: b)
    }

    private mutating func randomRotate(state: SAPlacementState) -> SAMove? {
        guard let (instID, _) = state.slots.randomElement(using: &rng) else { return nil }
        return .rotate(instance: instID)
    }

    private mutating func randomMirror(state: SAPlacementState) -> SAMove? {
        guard let (instID, _) = state.slots.randomElement(using: &rng) else { return nil }
        return .mirror(instance: instID)
    }

    /// Box-Muller transform for Gaussian random numbers.
    private mutating func gaussianRandom(sigma: Double) -> Double {
        let u1 = Double.random(in: 0.0001..<1.0, using: &rng)
        let u2 = Double.random(in: 0..<1.0, using: &rng)
        return sigma * sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}
