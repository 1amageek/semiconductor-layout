import Foundation
import Testing
import LayoutCore
import LayoutEditor
import LayoutTech
import LayoutVerify

/// N4 + N6 contracts: electrical estimates are golden-checked hand
/// arithmetic, unavailable quantities stay nil (never zero), EM width
/// requirements derive from declared currents, and the trust report
/// states what is verified, what has findings, and what is NOT checked.
@Suite("Electrical and trust", .timeLimit(.minutes(2)))
struct ElectricalAndTrustTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    /// Sky130-met1-flavored constants; the sheet resistance and unit
    /// capacitances mirror the values the PEXEngine met1 physics
    /// validation uses (PEXEngine G3 trust anchor), cited here as the
    /// golden source.
    private static func electricalTech() -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: m1,
                    displayName: "M1",
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9),
                    sheetResistance: 0.125,
                    areaCapacitance: 0.025,
                    fringeCapacitance: 0.04,
                    maxCurrentDensity: 2.0
                )
            ],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1,
                    minWidth: 0.2,
                    minSpacing: 0.2,
                    minArea: 0.01,
                    minDensity: 0,
                    maxDensity: 1
                )
            ]
        )
    }

    @Test func estimateMatchesHandArithmetic() {
        // One 100 x 0.5 um wire:
        //   R = 0.125 ohm/sq x (100 / 0.5) sq = 25 ohm
        //   C = 0.025 fF/um^2 x 50 um^2 + 0.04 fF/um x 201 um = 1.25 + 8.04 fF
        //   tau = 25 x 9.29 fF = 232.25 fs = 0.23225 ps
        let wire = LayoutShape(
            layer: Self.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 100, height: 0.5)))
        )
        let estimate = LayoutElectricalEstimator(tech: Self.electricalTech())
            .estimate(shapes: [wire], vias: [])

        #expect(abs((estimate.resistance ?? 0) - 25.0) < 1e-9)
        #expect(abs((estimate.capacitance ?? 0) - 9.29) < 1e-9)
        #expect(abs((estimate.timeConstantPS ?? 0) - 0.23225) < 1e-9)
        #expect(estimate.unmodeledElementCount == 0)
        #expect(estimate.minimumWireWidth == 0.5)
    }

    @Test func unmodeledLayersReportNilNotZero() {
        let bareTech = LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: Self.m1,
                    displayName: "M1",
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
                )
            ],
            vias: [],
            layerRules: []
        )
        let wire = LayoutShape(
            layer: Self.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 10, height: 0.5)))
        )
        let estimate = LayoutElectricalEstimator(tech: bareTech)
            .estimate(shapes: [wire], vias: [])

        #expect(estimate.resistance == nil, "no constants must mean no number, not zero")
        #expect(estimate.capacitance == nil)
        #expect(estimate.timeConstantPS == nil)
        #expect(estimate.unmodeledElementCount == 1)
    }

    @Test func electromigrationWidthDerivesFromCurrent() {
        let estimator = LayoutElectricalEstimator(tech: Self.electricalTech())
        // 5 mA at 2 mA/um -> 2.5 um required.
        #expect(estimator.requiredWidth(forCurrent: 5.0, layer: Self.m1) == 2.5)
    }

    @MainActor
    @Test func emAdvisoryFlagsAnUndersizedDeclaredNet() throws {
        let net = LayoutNet(name: "VPWR", currentSpec: 5.0)
        let wire = LayoutShape(
            layer: Self.m1,
            netID: net.id,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 50, height: 0.5)))
        )
        let cell = LayoutCell(name: "TOP", shapes: [wire], nets: [net])
        let document = LayoutDocument(name: "em", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: Self.electricalTech())

        let advisories = viewModel.electricalAdvisories

        #expect(advisories.count == 1)
        #expect(advisories[0].contains("VPWR"))
        if case .findings(1) = viewModel.trustReport.electrical {
        } else {
            Issue.record("the trust report must carry the EM advisory")
        }
    }

    @MainActor
    @Test func trustReportStatesUnavailableAxesExplicitly() {
        let cell = LayoutCell(name: "TOP", shapes: [
            LayoutShape(
                layer: Self.m1,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
            )
        ])
        let document = LayoutDocument(name: "trust", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        let report = viewModel.trustReport

        #expect(report.drc == .clean)
        #expect(report.connectivity == .clean)
        guard case .unavailable = report.constraints else {
            Issue.record("undeclared constraints must read as unavailable, not clean")
            return
        }
        guard case .unavailable = report.lvs else {
            Issue.record("missing LVS reference must read as unavailable, not clean")
            return
        }
        guard case .unavailable = report.electrical else {
            Issue.record("a tech without constants must read as unavailable, not clean")
            return
        }
        #expect(!report.verificationPending)
    }

    @MainActor
    @Test func trustReportCountsFindingsPerAxis() {
        let netA = UUID()
        let netB = UUID()
        let shapes = [
            LayoutShape(
                layer: Self.m1,
                netID: netA,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.4)))
            ),
            LayoutShape(
                layer: Self.m1,
                netID: netB,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 1.1, y: 0),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ),
            LayoutShape(
                layer: Self.m1,
                netID: netA,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 10, y: 0),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ),
        ]
        let cell = LayoutCell(name: "TOP", shapes: shapes)
        let document = LayoutDocument(name: "trust", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: Self.electricalTech())
        let report = viewModel.trustReport

        guard case .findings(let drcCount) = report.drc else {
            Issue.record("the spacing violation must surface")
            return
        }
        #expect(drcCount >= 1)
        guard case .findings(let openCount) = report.connectivity else {
            Issue.record("the split net must surface as an open")
            return
        }
        #expect(openCount == 1)
    }
}
