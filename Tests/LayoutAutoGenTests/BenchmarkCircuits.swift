import Foundation
import LayoutAutoGen
import LayoutCore
import LayoutTech

/// Factory for standard benchmark circuits used to evaluate placement/routing algorithms.
struct BenchmarkCircuits {

    struct BenchmarkInput {
        var instances: [PlacementInstance]
        var nets: [PlacementNet]
        var constraints: [LayoutConstraint]
        var cells: [UUID: LayoutCell]
        var tech: LayoutTechDatabase
    }

    // MARK: - Inverter (1P + 1N, 3 nets)

    static func inverter() throws -> BenchmarkInput {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()
        let params: [String: Double] = ["w": 1.0, "l": 0.18]

        let pmosCell = try mosGen.generateCell(
            deviceKindID: "pmos", instanceName: "MP1", parameters: params, tech: tech
        )
        let nmosCell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MN1", parameters: params, tech: tech
        )

        let pmosID = UUID()
        let nmosID = UUID()

        let instances = [
            PlacementInstance(id: pmosID, cell: pmosCell, deviceType: .pmos, name: "MP1"),
            PlacementInstance(id: nmosID, cell: nmosCell, deviceType: .nmos, name: "MN1"),
        ]

        let nets = [
            PlacementNet(name: "VDD", pinConnections: [(instanceID: pmosID, pinName: "source")]),
            PlacementNet(name: "VSS", pinConnections: [(instanceID: nmosID, pinName: "source")]),
            PlacementNet(name: "IN", pinConnections: [
                (instanceID: pmosID, pinName: "gate"),
                (instanceID: nmosID, pinName: "gate"),
            ]),
            PlacementNet(name: "OUT", pinConnections: [
                (instanceID: pmosID, pinName: "drain"),
                (instanceID: nmosID, pinName: "drain"),
            ]),
        ]

        var cells: [UUID: LayoutCell] = [:]
        cells[pmosCell.id] = pmosCell
        cells[nmosCell.id] = nmosCell

        return BenchmarkInput(
            instances: instances, nets: nets, constraints: [],
            cells: cells, tech: tech
        )
    }

    // MARK: - Current Mirror (2P matched, 3 nets)

    static func currentMirror() throws -> BenchmarkInput {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()
        let params: [String: Double] = ["w": 2.0, "l": 0.5]

        let p1Cell = try mosGen.generateCell(
            deviceKindID: "pmos", instanceName: "MP1", parameters: params, tech: tech
        )
        let p2Cell = try mosGen.generateCell(
            deviceKindID: "pmos", instanceName: "MP2", parameters: params, tech: tech
        )

        let p1ID = UUID()
        let p2ID = UUID()

        let instances = [
            PlacementInstance(id: p1ID, cell: p1Cell, deviceType: .pmos, name: "MP1"),
            PlacementInstance(id: p2ID, cell: p2Cell, deviceType: .pmos, name: "MP2"),
        ]

        let nets = [
            PlacementNet(name: "VDD", pinConnections: [
                (instanceID: p1ID, pinName: "source"),
                (instanceID: p2ID, pinName: "source"),
            ]),
            PlacementNet(name: "IREF", pinConnections: [
                (instanceID: p1ID, pinName: "drain"),
                (instanceID: p1ID, pinName: "gate"),
                (instanceID: p2ID, pinName: "gate"),
            ]),
            PlacementNet(name: "IOUT", pinConnections: [
                (instanceID: p2ID, pinName: "drain"),
            ]),
        ]

        let constraints: [LayoutConstraint] = [
            .matching(LayoutMatchingConstraint(members: [p1ID, p2ID])),
        ]

        var cells: [UUID: LayoutCell] = [:]
        cells[p1Cell.id] = p1Cell
        cells[p2Cell.id] = p2Cell

        return BenchmarkInput(
            instances: instances, nets: nets, constraints: constraints,
            cells: cells, tech: tech
        )
    }

    // MARK: - Differential Pair (2N + 1N tail + 2R load, 7 nets)

    static func differentialPair() throws -> BenchmarkInput {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()
        let resGen = ResistorCellGenerator()

        let diffParams: [String: Double] = ["w": 5.0, "l": 0.5]
        let tailParams: [String: Double] = ["w": 10.0, "l": 0.5]
        let resParams: [String: Double] = ["r": 1000.0]

        let m1Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MN1", parameters: diffParams, tech: tech
        )
        let m2Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MN2", parameters: diffParams, tech: tech
        )
        let tailCell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MT", parameters: tailParams, tech: tech
        )
        let r1Cell = try resGen.generateCell(
            deviceKindID: "resistor", instanceName: "R1", parameters: resParams, tech: tech
        )
        let r2Cell = try resGen.generateCell(
            deviceKindID: "resistor", instanceName: "R2", parameters: resParams, tech: tech
        )

        let m1ID = UUID(), m2ID = UUID(), tailID = UUID(), r1ID = UUID(), r2ID = UUID()

        let instances = [
            PlacementInstance(id: m1ID, cell: m1Cell, deviceType: .nmos, name: "MN1"),
            PlacementInstance(id: m2ID, cell: m2Cell, deviceType: .nmos, name: "MN2"),
            PlacementInstance(id: tailID, cell: tailCell, deviceType: .nmos, name: "MT"),
            PlacementInstance(id: r1ID, cell: r1Cell, deviceType: .passive, name: "R1"),
            PlacementInstance(id: r2ID, cell: r2Cell, deviceType: .passive, name: "R2"),
        ]

        let nets = [
            PlacementNet(name: "VDD", pinConnections: [
                (instanceID: r1ID, pinName: "pos"),
                (instanceID: r2ID, pinName: "pos"),
            ]),
            PlacementNet(name: "VSS", pinConnections: [
                (instanceID: tailID, pinName: "source"),
            ]),
            PlacementNet(name: "INP", pinConnections: [
                (instanceID: m1ID, pinName: "gate"),
            ]),
            PlacementNet(name: "INM", pinConnections: [
                (instanceID: m2ID, pinName: "gate"),
            ]),
            PlacementNet(name: "OUTP", pinConnections: [
                (instanceID: m1ID, pinName: "drain"),
                (instanceID: r1ID, pinName: "neg"),
            ]),
            PlacementNet(name: "OUTM", pinConnections: [
                (instanceID: m2ID, pinName: "drain"),
                (instanceID: r2ID, pinName: "neg"),
            ]),
            PlacementNet(name: "TAIL", pinConnections: [
                (instanceID: m1ID, pinName: "source"),
                (instanceID: m2ID, pinName: "source"),
                (instanceID: tailID, pinName: "drain"),
            ]),
        ]

        let constraints: [LayoutConstraint] = [
            .symmetry(LayoutSymmetryConstraint(axis: .vertical, members: [m1ID, m2ID])),
        ]

        var cells: [UUID: LayoutCell] = [:]
        cells[m1Cell.id] = m1Cell
        cells[m2Cell.id] = m2Cell
        cells[tailCell.id] = tailCell
        cells[r1Cell.id] = r1Cell
        cells[r2Cell.id] = r2Cell

        return BenchmarkInput(
            instances: instances, nets: nets, constraints: constraints,
            cells: cells, tech: tech
        )
    }

    // MARK: - Simple OTA (7 MOS, ~12 nets)

    static func simpleOTA() throws -> BenchmarkInput {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()

        let diffParams: [String: Double] = ["w": 5.0, "l": 0.5]
        let loadParams: [String: Double] = ["w": 3.0, "l": 0.5]
        let tailParams: [String: Double] = ["w": 10.0, "l": 0.5]
        let mirrorParams: [String: Double] = ["w": 3.0, "l": 0.5]

        // Differential pair
        let mn1Cell = try mosGen.generateCell(deviceKindID: "nmos", instanceName: "MN1", parameters: diffParams, tech: tech)
        let mn2Cell = try mosGen.generateCell(deviceKindID: "nmos", instanceName: "MN2", parameters: diffParams, tech: tech)
        // Tail current source
        let mtailCell = try mosGen.generateCell(deviceKindID: "nmos", instanceName: "MT", parameters: tailParams, tech: tech)
        // Active load (PMOS current mirror)
        let mp1Cell = try mosGen.generateCell(deviceKindID: "pmos", instanceName: "MP1", parameters: loadParams, tech: tech)
        let mp2Cell = try mosGen.generateCell(deviceKindID: "pmos", instanceName: "MP2", parameters: loadParams, tech: tech)
        // Bias mirror
        let mbRefCell = try mosGen.generateCell(deviceKindID: "nmos", instanceName: "MB_REF", parameters: mirrorParams, tech: tech)
        let mbCell = try mosGen.generateCell(deviceKindID: "nmos", instanceName: "MB", parameters: mirrorParams, tech: tech)

        let mn1 = UUID(), mn2 = UUID(), mt = UUID()
        let mp1 = UUID(), mp2 = UUID()
        let mbRef = UUID(), mb = UUID()

        let instances = [
            PlacementInstance(id: mn1, cell: mn1Cell, deviceType: .nmos, name: "MN1"),
            PlacementInstance(id: mn2, cell: mn2Cell, deviceType: .nmos, name: "MN2"),
            PlacementInstance(id: mt, cell: mtailCell, deviceType: .nmos, name: "MT"),
            PlacementInstance(id: mp1, cell: mp1Cell, deviceType: .pmos, name: "MP1"),
            PlacementInstance(id: mp2, cell: mp2Cell, deviceType: .pmos, name: "MP2"),
            PlacementInstance(id: mbRef, cell: mbRefCell, deviceType: .nmos, name: "MB_REF"),
            PlacementInstance(id: mb, cell: mbCell, deviceType: .nmos, name: "MB"),
        ]

        let nets = [
            PlacementNet(name: "VDD", pinConnections: [
                (instanceID: mp1, pinName: "source"),
                (instanceID: mp2, pinName: "source"),
            ]),
            PlacementNet(name: "VSS", pinConnections: [
                (instanceID: mt, pinName: "source"),
                (instanceID: mbRef, pinName: "source"),
                (instanceID: mb, pinName: "source"),
            ]),
            PlacementNet(name: "INP", pinConnections: [(instanceID: mn1, pinName: "gate")]),
            PlacementNet(name: "INM", pinConnections: [(instanceID: mn2, pinName: "gate")]),
            PlacementNet(name: "OUT", pinConnections: [
                (instanceID: mn2, pinName: "drain"),
                (instanceID: mp2, pinName: "drain"),
            ]),
            PlacementNet(name: "TAIL", pinConnections: [
                (instanceID: mn1, pinName: "source"),
                (instanceID: mn2, pinName: "source"),
                (instanceID: mt, pinName: "drain"),
            ]),
            PlacementNet(name: "MIRROR_LOAD", pinConnections: [
                (instanceID: mp1, pinName: "gate"),
                (instanceID: mp2, pinName: "gate"),
                (instanceID: mp1, pinName: "drain"),
                (instanceID: mn1, pinName: "drain"),
            ]),
            PlacementNet(name: "BIAS", pinConnections: [
                (instanceID: mbRef, pinName: "gate"),
                (instanceID: mbRef, pinName: "drain"),
                (instanceID: mb, pinName: "gate"),
            ]),
            PlacementNet(name: "BIAS_OUT", pinConnections: [
                (instanceID: mb, pinName: "drain"),
                (instanceID: mt, pinName: "gate"),
            ]),
        ]

        let constraints: [LayoutConstraint] = [
            .symmetry(LayoutSymmetryConstraint(axis: .vertical, members: [mn1, mn2])),
            .matching(LayoutMatchingConstraint(members: [mp1, mp2])),
        ]

        var cells: [UUID: LayoutCell] = [:]
        cells[mn1Cell.id] = mn1Cell
        cells[mn2Cell.id] = mn2Cell
        cells[mtailCell.id] = mtailCell
        cells[mp1Cell.id] = mp1Cell
        cells[mp2Cell.id] = mp2Cell
        cells[mbRefCell.id] = mbRefCell
        cells[mbCell.id] = mbCell

        return BenchmarkInput(
            instances: instances, nets: nets, constraints: constraints,
            cells: cells, tech: tech
        )
    }
}
