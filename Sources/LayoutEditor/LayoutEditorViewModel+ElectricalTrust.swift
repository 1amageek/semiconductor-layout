import Foundation
import LayoutCore
import LayoutTech
import LayoutVerify

extension LayoutEditorViewModel {
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

}
