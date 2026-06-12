import Foundation
import LayoutCore
import LayoutTech

/// Lumped electrical estimate of one conductor net.
///
/// Quantities are nil — never zero — when the technology does not model
/// the contributing layers; `unmodeledElementCount` says how much of the
/// net the estimate could not see.
public struct LayoutElectricalEstimate: Sendable, Equatable {
    /// Series-chain resistance estimate in ohms.
    public var resistance: Double?
    /// Lumped ground capacitance in fF.
    public var capacitance: Double?
    /// Elements (shapes or vias) on layers without electrical constants,
    /// or unreachable child occurrences — the honest coverage gap.
    public var unmodeledElementCount: Int
    /// Narrowest modeled wire dimension in the net, um.
    public var minimumWireWidth: Double?

    /// R x C in picoseconds (R[ohm] x C[fF] = femtoseconds / 1000).
    public var timeConstantPS: Double? {
        guard let resistance, let capacitance else { return nil }
        return resistance * capacitance / 1000
    }
}

/// Geometry-level electrical model: per-shape squares x sheet resistance
/// summed as a series chain (a deliberate, documented over-estimate for
/// branched nets), area + fringe capacitance summed exactly under the
/// lumped model. Constants come from `LayoutLayerDefinition`; layers
/// without constants contribute to `unmodeledElementCount` instead of
/// silently contributing zero.
public struct LayoutElectricalEstimator: Sendable {
    private let tech: LayoutTechDatabase

    public init(tech: LayoutTechDatabase) {
        self.tech = tech
    }

    public func estimate(shapes: [LayoutShape], vias: [LayoutVia]) -> LayoutElectricalEstimate {
        var resistance = 0.0
        var sawResistance = false
        var capacitance = 0.0
        var sawCapacitance = false
        var unmodeled = 0
        var minimumWidth: Double? = nil

        for shape in shapes {
            guard let definition = tech.layerDefinition(for: shape.layer) else {
                unmodeled += 1
                continue
            }
            let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            let longer = max(box.size.width, box.size.height)
            let shorter = min(box.size.width, box.size.height)
            var modeled = false
            if let sheet = definition.sheetResistance, shorter > 0 {
                resistance += sheet * (longer / shorter)
                sawResistance = true
                modeled = true
                minimumWidth = min(minimumWidth ?? shorter, shorter)
            }
            if let area = definition.areaCapacitance {
                capacitance += area * box.size.width * box.size.height
                sawCapacitance = true
                modeled = true
            }
            if let fringe = definition.fringeCapacitance {
                capacitance += fringe * 2 * (box.size.width + box.size.height)
                sawCapacitance = true
                modeled = true
            }
            if !modeled {
                unmodeled += 1
            }
        }
        // Vias are not modeled in the first electrical tier (their plug
        // resistance needs per-definition constants); they count as
        // unmodeled coverage, never as zero ohms.
        unmodeled += vias.count

        return LayoutElectricalEstimate(
            resistance: sawResistance ? resistance : nil,
            capacitance: sawCapacitance ? capacitance : nil,
            unmodeledElementCount: unmodeled,
            minimumWireWidth: minimumWidth
        )
    }

    /// Minimum wire width to carry `currentMA` on `layer`, or nil when
    /// the layer has no electromigration limit configured.
    public func requiredWidth(forCurrent currentMA: Double, layer: LayoutLayerID) -> Double? {
        guard let density = tech.layerDefinition(for: layer)?.maxCurrentDensity,
              density > 0 else { return nil }
        return currentMA / density
    }
}
