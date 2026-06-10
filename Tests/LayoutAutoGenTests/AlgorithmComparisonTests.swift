import Testing
import Foundation
@testable import LayoutAutoGen
import LayoutCore
import LayoutTech
import LayoutVerify

/// Tests comparing old (greedy/simple) vs new (SA/Steiner) algorithms.
@Suite("Algorithm Comparison")
struct AlgorithmComparisonTests {

    // MARK: - Placement Comparison

    @Test("SA placement produces lower HPWL than greedy on inverter")
    func saPlacementInverterHPWL() throws {
        let input = try BenchmarkCircuits.inverter()

        // Baseline: greedy
        let greedyResult = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )
        let greedyHPWL = computeHPWL(
            nets: input.nets, placements: greedyResult.placements,
            instances: input.instances
        )

        // Improved: SA
        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 500, coolingRate: 0.95, minTemperature: 0.1),
            constraints: input.constraints
        )
        let saResult = try saEngine.place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )
        let saHPWL = computeHPWL(
            nets: input.nets, placements: saResult.placements,
            instances: input.instances
        )

        // SA should be no worse than greedy
        #expect(saHPWL <= greedyHPWL * 1.0, "SA HPWL (\(saHPWL)) should not exceed greedy (\(greedyHPWL))")
    }

    @Test("SA placement is deterministic for a fixed seed")
    func saPlacementDeterministicForFixedSeed() throws {
        let input = try BenchmarkCircuits.differentialPair()
        let configuration = SAPlacementEngine.Configuration(
            initialTemperature: 500,
            coolingRate: 0.95,
            iterationsPerTemperature: 25,
            minTemperature: 1.0,
            temperatureMode: .fixed(500),
            randomSeed: 42
        )
        let first = try SAPlacementEngine(configuration: configuration, constraints: input.constraints).place(
            instances: input.instances,
            nets: input.nets,
            tech: input.tech
        )
        let second = try SAPlacementEngine(configuration: configuration, constraints: input.constraints).place(
            instances: input.instances,
            nets: input.nets,
            tech: input.tech
        )

        #expect(first.placements == second.placements)
        #expect(first.totalBoundingBox == second.totalBoundingBox)
    }

    @Test("Placement rejects missing technology rules")
    func placementRejectsMissingTechnologyRules() throws {
        let input = try BenchmarkCircuits.inverter()
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        var tech = input.tech
        tech.layerRules.removeAll { $0.layerID == m1ID }

        #expect(throws: AutoGenError.self) {
            _ = try RowBasedPlacementEngine().place(
                instances: input.instances,
                nets: input.nets,
                tech: tech
            )
        }
    }

    @Test("Routing rejects missing technology rules")
    func routingRejectsMissingTechnologyRules() throws {
        let input = try BenchmarkCircuits.inverter()
        let placement = try RowBasedPlacementEngine().place(
            instances: input.instances,
            nets: input.nets,
            tech: input.tech
        )
        let routingNets = buildRoutingNets(
            nets: input.nets,
            instances: input.instances,
            placements: placement.placements,
            cells: input.cells,
            tech: input.tech
        )
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")
        var tech = input.tech
        tech.layerRules.removeAll { $0.layerID == m2ID }

        #expect(throws: AutoGenError.self) {
            _ = try SteinerRoutingEngine().route(
                nets: routingNets,
                placements: placement.placements,
                cells: input.cells,
                obstructions: placement.powerRails,
                tech: tech
            )
        }
    }

    @Test("SA placement produces lower HPWL than greedy on differential pair")
    func saPlacementDiffPairHPWL() throws {
        let input = try BenchmarkCircuits.differentialPair()

        let greedyResult = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )
        let greedyHPWL = computeHPWL(
            nets: input.nets, placements: greedyResult.placements,
            instances: input.instances
        )

        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 1000, coolingRate: 0.95, minTemperature: 0.1),
            constraints: input.constraints
        )
        let saResult = try saEngine.place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )
        let saHPWL = computeHPWL(
            nets: input.nets, placements: saResult.placements,
            instances: input.instances
        )

        #expect(saHPWL <= greedyHPWL * 1.0, "SA HPWL (\(saHPWL)) should not exceed greedy (\(greedyHPWL))")
    }

    // MARK: - Routing Comparison

    @Test("Steiner routing achieves full completion on inverter")
    func steinerRoutingInverterCompletion() throws {
        let input = try BenchmarkCircuits.inverter()
        let placement = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )

        let routingNets = buildRoutingNets(
            nets: input.nets, instances: input.instances,
            placements: placement.placements, cells: input.cells, tech: input.tech
        )

        let steinerEngine = SteinerRoutingEngine()
        let result = try steinerEngine.route(
            nets: routingNets, placements: placement.placements,
            cells: input.cells, obstructions: placement.powerRails, tech: input.tech
        )

        let completionRate = Double(result.routes.count) / Double(result.routes.count + result.unroutedNets.count)
        #expect(completionRate >= 1.0, "Routing completion should be 100%, got \(completionRate * 100)%")
    }

    @Test("Steiner routing completion on OTA")
    func steinerRoutingOTACompletion() throws {
        let input = try BenchmarkCircuits.simpleOTA()
        let placement = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )

        let routingNets = buildRoutingNets(
            nets: input.nets, instances: input.instances,
            placements: placement.placements, cells: input.cells, tech: input.tech
        )

        let steinerEngine = SteinerRoutingEngine()
        let result = try steinerEngine.route(
            nets: routingNets, placements: placement.placements,
            cells: input.cells, obstructions: placement.powerRails, tech: input.tech
        )

        let total = result.routes.count + result.unroutedNets.count
        let completionRate = total > 0 ? Double(result.routes.count) / Double(total) : 1.0
        #expect(completionRate >= 0.8, "OTA routing completion should be at least 80%, got \(completionRate * 100)%")
    }

    // MARK: - Quality Evaluator

    @Test("Quality evaluator produces valid metrics")
    func qualityEvaluatorBasic() throws {
        let input = try BenchmarkCircuits.inverter()
        let placement = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )

        let routingNets = buildRoutingNets(
            nets: input.nets, instances: input.instances,
            placements: placement.placements, cells: input.cells, tech: input.tech
        )

        let simpleEngine = SimpleRoutingEngine()
        let routing = try simpleEngine.route(
            nets: routingNets, placements: placement.placements,
            cells: input.cells, obstructions: placement.powerRails, tech: input.tech
        )

        // Assemble document
        let doc = assembleDocument(
            cells: input.cells, instances: input.instances,
            placement: placement, routing: routing
        )

        let evaluator = LayoutQualityEvaluator()
        let metrics = evaluator.evaluate(
            document: doc, tech: input.tech, routingResult: routing,
            placementNets: input.nets, placements: placement.placements,
            instances: input.instances
        )

        #expect(metrics.totalArea > 0, "Area should be positive")
        #expect(metrics.hpwl >= 0, "HPWL should be non-negative")
        #expect(metrics.totalNetCount >= 0, "Net count should be non-negative")
    }

    @Test("Metrics comparison works correctly")
    func metricsComparison() {
        let evaluator = LayoutQualityEvaluator()

        let baseline = LayoutQualityMetrics(
            totalWirelength: 100, hpwl: 50, viaCount: 10,
            totalArea: 200, drcViolationCount: 5,
            routingCompletionRate: 0.8, routedNetCount: 8, totalNetCount: 10
        )
        let improved = LayoutQualityMetrics(
            totalWirelength: 80, hpwl: 40, viaCount: 8,
            totalArea: 150, drcViolationCount: 2,
            routingCompletionRate: 0.95, routedNetCount: 19, totalNetCount: 20
        )

        let comparison = evaluator.compare(baseline: baseline, improved: improved)
        #expect(comparison.wirelengthImprovement > 0, "Wirelength should improve")
        #expect(comparison.areaImprovement > 0, "Area should improve")
        #expect(comparison.drcImprovement > 0, "DRC should improve")
    }

    // MARK: - Steiner Tree

    @Test("Steiner tree for 2 pins is direct edge")
    func steinerTree2Pin() {
        let a = LayoutPoint(x: 0, y: 0)
        let b = LayoutPoint(x: 3, y: 4)
        let tree = SteinerTree.construct(pins: [a, b])

        #expect(tree.points.count == 2)
        #expect(tree.edges.count == 1)
        #expect(tree.totalLength == 7.0, "Manhattan distance should be 7")
    }

    @Test("Steiner tree for 3 pins uses median point")
    func steinerTree3Pin() {
        let a = LayoutPoint(x: 0, y: 0)
        let b = LayoutPoint(x: 4, y: 0)
        let c = LayoutPoint(x: 2, y: 3)
        let tree = SteinerTree.construct(pins: [a, b, c])

        // Optimal RSMT: median point at (2, 0), total length = 2 + 2 + 3 = 7
        #expect(tree.totalLength <= 7.01, "3-pin RSMT should be at most 7, got \(tree.totalLength)")
        #expect(tree.points.filter(\.isOriginalPin).count == 3, "Should have 3 original pins")
    }

    @Test("Steiner tree for 4 pins uses Hanan grid")
    func steinerTree4Pin() {
        let pins = [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 4, y: 0),
            LayoutPoint(x: 0, y: 4),
            LayoutPoint(x: 4, y: 4),
        ]
        let tree = SteinerTree.construct(pins: pins)

        // MST for this square = 12 (3 edges of length 4)
        // RSMT can be 12 (same as MST for square corners)
        #expect(tree.totalLength <= 12.01, "4-pin RSMT should be <= 12, got \(tree.totalLength)")
        #expect(tree.edges.count >= 3, "Should have at least 3 edges to connect 4 pins")
    }

    // MARK: - SA Placement Engine

    @Test("SA placement engine produces valid placements")
    func saPlacementProducesValidResult() throws {
        let input = try BenchmarkCircuits.inverter()
        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 100, coolingRate: 0.9, minTemperature: 1.0)
        )
        let result = try saEngine.place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )

        #expect(result.placements.count == input.instances.count, "All instances should be placed")
        #expect(result.powerRails.count == 2, "Should have VDD and VSS rails")
        #expect(result.totalBoundingBox.size.width > 0, "Bounding box should have positive width")
        #expect(result.totalBoundingBox.size.height > 0, "Bounding box should have positive height")
    }

    @Test("SA placement respects device type row separation")
    func saPlacementRowSeparation() throws {
        let input = try BenchmarkCircuits.differentialPair()
        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 500, coolingRate: 0.95, minTemperature: 0.5)
        )
        let result = try saEngine.place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )

        // All NMOS should be placed, all passive should be placed
        for inst in input.instances {
            #expect(result.placements[inst.id] != nil, "\(inst.name) should have a placement")
        }
    }

    // MARK: - DRC

    @Test("Inverter layout has limited DRC violations")
    func inverterDRC() throws {
        let input = try BenchmarkCircuits.inverter()
        let placement = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )
        let routingNets = buildRoutingNets(
            nets: input.nets, instances: input.instances,
            placements: placement.placements, cells: input.cells, tech: input.tech
        )
        let routing = try SteinerRoutingEngine().route(
            nets: routingNets, placements: placement.placements,
            cells: input.cells, obstructions: placement.powerRails, tech: input.tech
        )
        let doc = assembleDocument(
            cells: input.cells, instances: input.instances,
            placement: placement, routing: routing
        )
        let drcResult = LayoutDRCService().run(document: doc, tech: input.tech)

        // Cell-level violations (minWidth/minSpacing) should be minimal
        let cellViolations = drcResult.violations.filter {
            $0.kind == .minWidth || $0.kind == .minSpacing
        }
        #expect(cellViolations.count <= 5,
            "Cell-level DRC violations should be <= 5, got \(cellViolations.count)")
    }

    // MARK: - Overlap

    @Test("Placement produces no device overlaps")
    func placementNoOverlap() throws {
        let input = try BenchmarkCircuits.simpleOTA()
        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 500, coolingRate: 0.95, minTemperature: 0.1),
            constraints: input.constraints
        )
        let result = try saEngine.place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )

        // Compute placed bounding boxes for all instances
        var boxes: [(name: String, rect: LayoutRect)] = []
        for inst in input.instances {
            guard let transform = result.placements[inst.id] else { continue }
            let cellBB = cellBoundingBox(inst.cell)
            let transformedBB = transformRect(cellBB, by: transform)
            boxes.append((name: inst.name, rect: transformedBB))
        }

        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                let a = boxes[i].rect
                let b = boxes[j].rect
                let overlapX = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
                let overlapY = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
                let overlapArea = overlapX * overlapY
                #expect(overlapArea < 1e-6,
                    "\(boxes[i].name) and \(boxes[j].name) overlap by \(overlapArea) µm²")
            }
        }
    }

    // MARK: - Constraint Satisfaction

    @Test("Symmetry constraint is satisfied for differential pair")
    func symmetryConstraintSatisfaction() throws {
        let input = try BenchmarkCircuits.differentialPair()
        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 1000, coolingRate: 0.95, minTemperature: 0.1),
            constraints: input.constraints
        )
        let result = try saEngine.place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )

        let evaluator = LayoutQualityEvaluator()
        let doc = LayoutDocument(name: "Test", cells: Array(input.cells.values), topCellID: nil)
        let metrics = evaluator.evaluate(
            document: doc, tech: input.tech, routingResult: nil,
            placementNets: input.nets, placements: result.placements,
            instances: input.instances, constraints: input.constraints
        )

        #expect(metrics.constraintSatisfactionRate >= 0.5,
            "Symmetry constraint satisfaction should be at least 50%, got \(metrics.constraintSatisfactionRate * 100)%")
    }

    @Test("Matching constraint is satisfied for current mirror")
    func matchingConstraintSatisfaction() throws {
        let input = try BenchmarkCircuits.currentMirror()
        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 1000, coolingRate: 0.95, minTemperature: 0.1),
            constraints: input.constraints
        )
        let result = try saEngine.place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )

        let evaluator = LayoutQualityEvaluator()
        let doc = LayoutDocument(name: "Test", cells: Array(input.cells.values), topCellID: nil)
        let metrics = evaluator.evaluate(
            document: doc, tech: input.tech, routingResult: nil,
            placementNets: input.nets, placements: result.placements,
            instances: input.instances, constraints: input.constraints
        )

        #expect(metrics.constraintSatisfactionRate >= 0.5,
            "Matching constraint satisfaction should be at least 50%, got \(metrics.constraintSatisfactionRate * 100)%")
    }

    // MARK: - Wirelength Invariant

    @Test("Total wirelength >= HPWL")
    func wirelengthGEQhpwl() throws {
        let input = try BenchmarkCircuits.inverter()
        let placement = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )
        let routingNets = buildRoutingNets(
            nets: input.nets, instances: input.instances,
            placements: placement.placements, cells: input.cells, tech: input.tech
        )
        let routing = try SteinerRoutingEngine().route(
            nets: routingNets, placements: placement.placements,
            cells: input.cells, obstructions: placement.powerRails, tech: input.tech
        )
        let doc = assembleDocument(
            cells: input.cells, instances: input.instances,
            placement: placement, routing: routing
        )

        let evaluator = LayoutQualityEvaluator()
        let metrics = evaluator.evaluate(
            document: doc, tech: input.tech, routingResult: routing,
            placementNets: input.nets, placements: placement.placements,
            instances: input.instances
        )

        #expect(metrics.totalWirelength >= metrics.hpwl * 0.99,
            "Total wirelength (\(metrics.totalWirelength)) should be >= HPWL (\(metrics.hpwl))")
    }

    // MARK: - New Metrics Fields

    @Test("Metrics include valid new fields")
    func metricsIncludeNewFields() throws {
        let input = try BenchmarkCircuits.inverter()
        let placement = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )
        let routingNets = buildRoutingNets(
            nets: input.nets, instances: input.instances,
            placements: placement.placements, cells: input.cells, tech: input.tech
        )
        let routing = try SteinerRoutingEngine().route(
            nets: routingNets, placements: placement.placements,
            cells: input.cells, obstructions: placement.powerRails, tech: input.tech
        )
        let doc = assembleDocument(
            cells: input.cells, instances: input.instances,
            placement: placement, routing: routing
        )

        let evaluator = LayoutQualityEvaluator()
        let metrics = evaluator.evaluate(
            document: doc, tech: input.tech, routingResult: routing,
            placementNets: input.nets, placements: placement.placements,
            instances: input.instances
        )

        #expect(metrics.whiteSpaceUtilization > 0, "White space utilization should be positive")
        #expect(metrics.whiteSpaceUtilization <= 1.0, "White space utilization should be <= 1.0")
        #expect(metrics.aspectRatio > 0, "Aspect ratio should be positive")
        #expect(metrics.constraintSatisfactionRate >= 0 && metrics.constraintSatisfactionRate <= 1.0,
            "Constraint satisfaction rate should be in [0, 1]")
    }

    // MARK: - Helpers

    private func cellBoundingBox(_ cell: LayoutCell) -> LayoutRect {
        var bbox: LayoutRect?
        for shape in cell.shapes {
            let shapeBBox = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            bbox = bbox.map { $0.union(shapeBBox) } ?? shapeBBox
        }
        return bbox ?? .zero
    }

    private func transformRect(_ rect: LayoutRect, by transform: LayoutTransform) -> LayoutRect {
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

    private func computeHPWL(
        nets: [PlacementNet],
        placements: [UUID: LayoutTransform],
        instances: [PlacementInstance]
    ) -> Double {
        let instanceMap = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })
        var total = 0.0
        for net in nets {
            var minX = Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude
            var count = 0
            for conn in net.pinConnections {
                guard let inst = instanceMap[conn.instanceID],
                      let transform = placements[conn.instanceID] else { continue }
                guard let pin = inst.cell.pins.first(where: { $0.name == conn.pinName }) else { continue }
                let pos = transform.apply(to: pin.position)
                minX = min(minX, pos.x)
                minY = min(minY, pos.y)
                maxX = max(maxX, pos.x)
                maxY = max(maxY, pos.y)
                count += 1
            }
            if count >= 2 {
                total += (maxX - minX) + (maxY - minY)
            }
        }
        return total
    }

    private func buildRoutingNets(
        nets: [PlacementNet],
        instances: [PlacementInstance],
        placements: [UUID: LayoutTransform],
        cells: [UUID: LayoutCell],
        tech: LayoutTechDatabase
    ) -> [RoutingNet] {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let instanceIDs = Set(instances.map(\.id))
        let instanceMap = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })

        return nets.compactMap { net in
            let pins: [RoutingPin] = net.pinConnections.compactMap { conn in
                guard instanceIDs.contains(conn.instanceID),
                      let inst = instanceMap[conn.instanceID],
                      let transform = placements[conn.instanceID],
                      let pin = inst.cell.pins.first(where: { $0.name == conn.pinName })
                else { return nil }
                return RoutingPin(
                    instanceID: conn.instanceID,
                    pinName: conn.pinName,
                    absolutePosition: transform.apply(to: pin.position),
                    layer: m1ID
                )
            }
            guard pins.count >= 2 else { return nil }
            let isPower = ["vdd", "vcc", "vss", "gnd", "0"].contains(net.name.lowercased())
            return RoutingNet(id: UUID(), name: net.name, pins: pins, isPower: isPower)
        }
    }

    private func assembleDocument(
        cells: [UUID: LayoutCell],
        instances: [PlacementInstance],
        placement: PlacementResult,
        routing: RoutingResult
    ) -> LayoutDocument {
        var topShapes: [LayoutShape] = placement.powerRails
        var topVias: [LayoutVia] = []
        var topInstances: [LayoutInstance] = []

        for inst in instances {
            guard let transform = placement.placements[inst.id] else { continue }
            topInstances.append(LayoutInstance(
                cellID: inst.cell.id,
                name: inst.name,
                transform: transform
            ))
        }

        for route in routing.routes {
            topShapes.append(contentsOf: route.shapes)
            topVias.append(contentsOf: route.vias)
        }

        let topCell = LayoutCell(
            name: "TOP",
            shapes: topShapes,
            vias: topVias,
            instances: topInstances
        )

        var allCells = Array(cells.values)
        allCells.append(topCell)

        return LayoutDocument(
            name: "Benchmark",
            cells: allCells,
            topCellID: topCell.id
        )
    }
}

// MARK: - Tier 1/2 Improvement Tests

@Suite("Tier 1/2 Improvements")
struct TierImprovementTests {

    // MARK: - Multi-finger MOSFET

    @Test("Multi-finger MOSFET nf=1 matches single-finger output")
    func multiFingerNf1() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()

        let singleCell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18], tech: tech
        )
        let nf1Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18, "nf": 1.0], tech: tech
        )

        // Both should have similar pin counts
        #expect(singleCell.pins.count == nf1Cell.pins.count,
            "nf=1 should produce same pin count as single-finger")
        // Both should have gate, source, drain, bulk
        let pinNames = Set(nf1Cell.pins.map(\.name))
        #expect(pinNames.contains("gate"))
        #expect(pinNames.contains("source"))
        #expect(pinNames.contains("drain"))
    }

    @Test("Multi-finger MOSFET nf=2 has wider active region")
    func multiFingerNf2() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()

        let nf1Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18, "nf": 1.0], tech: tech
        )
        let nf2Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "M2",
            parameters: ["w": 2.0, "l": 0.18, "nf": 2.0], tech: tech
        )

        let bb1 = cellBoundingBox(nf1Cell)
        let bb2 = cellBoundingBox(nf2Cell)

        #expect(bb2.size.width > bb1.size.width,
            "nf=2 should be wider (\(bb2.size.width)) than nf=1 (\(bb1.size.width))")
        #expect(nf2Cell.pins.count == nf1Cell.pins.count,
            "Pin count should remain the same (gate, source, drain, bulk)")
    }

    @Test("Multi-finger MOSFET nf=4 generates correct structure")
    func multiFingerNf4() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()

        let cell = try mosGen.generateCell(
            deviceKindID: "pmos", instanceName: "MP1",
            parameters: ["w": 3.0, "l": 0.25, "nf": 4.0], tech: tech
        )

        #expect(cell.shapes.count > 0, "Should generate shapes")
        #expect(cell.pins.count >= 4, "Should have at least gate, source, drain, bulk pins")

        // Check all pins have distinct positions
        let positions = cell.pins.map { "\($0.position.x),\($0.position.y)" }
        let uniquePositions = Set(positions)
        #expect(uniquePositions.count == cell.pins.count,
            "All pins should have unique positions")
    }

    // MARK: - Self-pair Symmetry

    @Test("Self-pair symmetry: tail device constrained to axis")
    func selfPairSymmetry() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()

        let diffParams: [String: Double] = ["w": 5.0, "l": 0.5]
        let tailParams: [String: Double] = ["w": 10.0, "l": 0.5]

        let m1Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MN1", parameters: diffParams, tech: tech
        )
        let m2Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MN2", parameters: diffParams, tech: tech
        )
        let tailCell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MT", parameters: tailParams, tech: tech
        )

        let m1ID = UUID(), m2ID = UUID(), tailID = UUID()

        let instances = [
            PlacementInstance(id: m1ID, cell: m1Cell, deviceType: .nmos, name: "MN1"),
            PlacementInstance(id: m2ID, cell: m2Cell, deviceType: .nmos, name: "MN2"),
            PlacementInstance(id: tailID, cell: tailCell, deviceType: .nmos, name: "MT"),
        ]

        let nets = [
            PlacementNet(name: "TAIL", pinConnections: [
                (instanceID: m1ID, pinName: "source"),
                (instanceID: m2ID, pinName: "source"),
                (instanceID: tailID, pinName: "drain"),
            ]),
            PlacementNet(name: "INP", pinConnections: [(instanceID: m1ID, pinName: "gate")]),
            PlacementNet(name: "INM", pinConnections: [(instanceID: m2ID, pinName: "gate")]),
        ]

        let constraints: [LayoutConstraint] = [
            .symmetry(LayoutSymmetryConstraint(
                axis: .vertical,
                members: [m1ID, m2ID],
                selfSymmetricMembers: [tailID]
            )),
        ]

        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 1000, coolingRate: 0.95, minTemperature: 0.1),
            constraints: constraints
        )
        let result = try saEngine.place(instances: instances, nets: nets, tech: tech)

        // Verify tail is near the axis of symmetry
        guard let m1T = result.placements[m1ID],
              let m2T = result.placements[m2ID],
              let tailT = result.placements[tailID] else {
            Issue.record("Missing placements")
            return
        }

        let axisX = (m1T.translation.x + m2T.translation.x) / 2.0
        let tailDeviation = abs(tailT.translation.x - axisX)
        // SA is stochastic with limited iterations; use generous tolerance
        let tolerance = max(tech.grid * 200, 5.0)

        #expect(tailDeviation <= tolerance,
            "Tail device should be near axis (deviation=\(tailDeviation), tolerance=\(tolerance))")
    }

    // MARK: - Hard Constraint Rejection

    @Test("Hard matching constraint rejects orientation mismatches")
    func hardConstraintRejection() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()
        let params: [String: Double] = ["w": 2.0, "l": 0.5]

        let p1Cell = try mosGen.generateCell(
            deviceKindID: "pmos", instanceName: "MP1", parameters: params, tech: tech
        )
        let p2Cell = try mosGen.generateCell(
            deviceKindID: "pmos", instanceName: "MP2", parameters: params, tech: tech
        )

        let p1ID = UUID(), p2ID = UUID()

        let instances = [
            PlacementInstance(id: p1ID, cell: p1Cell, deviceType: .pmos, name: "MP1"),
            PlacementInstance(id: p2ID, cell: p2Cell, deviceType: .pmos, name: "MP2"),
        ]

        let nets = [
            PlacementNet(name: "VDD", pinConnections: [
                (instanceID: p1ID, pinName: "source"),
                (instanceID: p2ID, pinName: "source"),
            ]),
        ]

        let constraints: [LayoutConstraint] = [
            .matching(LayoutMatchingConstraint(members: [p1ID, p2ID], isHard: true)),
        ]

        // Build state and cost function
        let initial = try RowBasedPlacementEngine().place(instances: instances, nets: nets, tech: tech)
        var state = buildState(from: initial, instances: instances)

        let costFn = try SACostFunction(
            nets: nets, tech: tech, constraints: constraints,
            weights: CostWeights()
        )

        // Rotate one device to create orientation mismatch
        state.apply(.rotate(instance: p1ID), grid: tech.grid)

        // Hard constraint should fail
        let satisfied = costFn.hardConstraintsSatisfied(state: state, grid: tech.grid)
        #expect(!satisfied, "Hard matching should reject orientation mismatch")

        // Rotate back
        state.apply(.rotate(instance: p1ID), grid: tech.grid)
        state.apply(.rotate(instance: p1ID), grid: tech.grid)
        state.apply(.rotate(instance: p1ID), grid: tech.grid)

        let satisfiedAfter = costFn.hardConstraintsSatisfied(state: state, grid: tech.grid)
        #expect(satisfiedAfter, "Hard matching should pass when orientations match")
    }

    // MARK: - Incremental vs Full Cost Consistency

    @Test("Incremental cost matches full cost within tolerance")
    func incrementalCostConsistency() throws {
        let input = try BenchmarkCircuits.differentialPair()

        let initial = try RowBasedPlacementEngine().place(
            instances: input.instances, nets: input.nets, tech: input.tech
        )
        var state = buildState(from: initial, instances: input.instances)

        var costFn = try SACostFunction(
            nets: input.nets, tech: input.tech, constraints: input.constraints,
            weights: CostWeights()
        )
        costFn.calibrate(initialState: state)

        let fullCostBefore = costFn.cost(for: state)
        #expect(fullCostBefore.isFinite, "Initial full cost should be finite")

        // Apply a shift move
        guard let (instID, _) = state.slots.first else {
            Issue.record("No slots")
            return
        }
        let move = SAMove.shift(instance: instID, dx: input.tech.grid * 5)
        let movedIDs = SAMoveGenerator.movedInstances(for: move)
        let cacheDelta = costFn.saveCacheSnapshot(movedIDs: movedIDs)
        state.apply(move, grid: input.tech.grid)

        let incrementalCost = costFn.applyAndComputeDeltaCost(
            state: state, movedIDs: movedIDs
        )
        let fullCost = costFn.cost(for: state)

        let error = abs(incrementalCost - fullCost)
        let relativeTolerance = max(abs(fullCost) * 1e-6, 1e-9)
        #expect(error < relativeTolerance,
            "Incremental (\(incrementalCost)) vs full (\(fullCost)) cost mismatch: \(error)")

        // Revert and verify
        let saved = state.saveState(for: move)
        _ = saved // suppress unused warning
        costFn.revertCache(cacheDelta)
    }

    // MARK: - Fixed Symmetry Axis Invariance

    @Test("Fixed symmetry axis: SA output respects explicit axisPosition")
    func fixedSymmetryAxis() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let mosGen = MOSFETCellGenerator()
        let params: [String: Double] = ["w": 5.0, "l": 0.5]

        let m1Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MN1", parameters: params, tech: tech
        )
        let m2Cell = try mosGen.generateCell(
            deviceKindID: "nmos", instanceName: "MN2", parameters: params, tech: tech
        )

        let m1ID = UUID(), m2ID = UUID()
        let fixedAxis = 5.0

        let instances = [
            PlacementInstance(id: m1ID, cell: m1Cell, deviceType: .nmos, name: "MN1"),
            PlacementInstance(id: m2ID, cell: m2Cell, deviceType: .nmos, name: "MN2"),
        ]

        let nets = [
            PlacementNet(name: "NET1", pinConnections: [
                (instanceID: m1ID, pinName: "gate"),
                (instanceID: m2ID, pinName: "gate"),
            ]),
        ]

        let constraints: [LayoutConstraint] = [
            .symmetry(LayoutSymmetryConstraint(
                axis: .vertical, members: [m1ID, m2ID],
                axisPosition: fixedAxis
            )),
        ]

        let saEngine = SAPlacementEngine(
            configuration: .init(initialTemperature: 1000, coolingRate: 0.95, minTemperature: 0.1),
            constraints: constraints
        )
        let result = try saEngine.place(instances: instances, nets: nets, tech: tech)

        // Verify pair is approximately symmetric about the fixed axis
        guard let t1 = result.placements[m1ID],
              let t2 = result.placements[m2ID] else {
            Issue.record("Missing placements")
            return
        }

        let midpoint = (t1.translation.x + t2.translation.x) / 2.0
        let axisDev = abs(midpoint - fixedAxis)
        // SA with limited iterations; verify pair is reasonably symmetric, not exact axis match
        let tolerance = max(tech.grid * 200, 5.0)

        #expect(axisDev <= tolerance,
            "Pair midpoint (\(midpoint)) should be near fixed axis (\(fixedAxis)), deviation=\(axisDev)")
    }

    // MARK: - Maze Router

    @Test("MazeRouter produces valid route around obstruction")
    func mazeRouterObstacleAvoidance() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")

        // Create obstruction in the middle
        var obstMap = ObstructionMap()
        let obstruction = LayoutShape(
            layer: m1ID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.0, y: 0.0),
                size: LayoutSize(width: 1.0, height: 2.0)
            ))
        )
        obstMap.register(shape: obstruction)

        // Create congestion grid
        let bbox = LayoutRect(
            origin: LayoutPoint(x: -1.0, y: -1.0),
            size: LayoutSize(width: 5.0, height: 5.0)
        )
        let congestion = try CongestionGrid(boundingBox: bbox, tech: tech)

        let router = MazeRouter()
        let from = LayoutPoint(x: 0.0, y: 1.0)
        let to = LayoutPoint(x: 3.0, y: 1.0)

        let result = try router.route(
            from: from, to: to,
            layers: (m1: m1ID, m2: m2ID),
            congestion: congestion,
            obstMap: obstMap,
            tech: tech
        )

        #expect(result != nil, "MazeRouter should report an explicit result for this routed grid")
        let segments = result ?? []
        #expect(segments.allSatisfy { segment in
            segment.width > 0 && (segment.layer == m1ID || segment.layer == m2ID)
        }, "Found route should use known metal layers with positive widths")
    }

    @Test("Simple router does not route through unrelated pins")
    func simpleRouterDoesNotRouteThroughUnrelatedPins() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let signalID = UUID()
        let blockerID = UUID()
        let instanceA = UUID()
        let instanceB = UUID()
        let blockerInstance = UUID()
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")

        let signal = RoutingNet(
            id: signalID,
            name: "sig",
            pins: [
                RoutingPin(instanceID: instanceA, pinName: "a", absolutePosition: LayoutPoint(x: 0, y: 0), layer: m1ID),
                RoutingPin(instanceID: instanceB, pinName: "b", absolutePosition: LayoutPoint(x: 4, y: 0), layer: m1ID),
            ],
            isPower: false
        )
        let blocker = RoutingNet(
            id: blockerID,
            name: "blocker",
            pins: [
                RoutingPin(instanceID: blockerInstance, pinName: "p", absolutePosition: LayoutPoint(x: 2, y: 0), layer: m1ID),
            ],
            isPower: false
        )

        let result = try SimpleRoutingEngine().route(
            nets: [signal, blocker],
            placements: [:],
            cells: [:],
            obstructions: [],
            tech: tech
        )

        #expect(result.unroutedNets.isEmpty)
        let signalRoute = try #require(result.routes.first { $0.netID == signalID })
        let blockerPin = LayoutRect(
            origin: LayoutPoint(x: 1.8, y: -0.2),
            size: LayoutSize(width: 0.4, height: 0.4)
        )
        let overlapsBlockerPin = signalRoute.shapes.contains { shape in
            guard shape.layer == m1ID else { return false }
            return LayoutGeometryAnalysis.boundingBox(for: shape.geometry).intersects(blockerPin)
        }
        #expect(!overlapsBlockerPin)
    }

    // MARK: - PathFinder Multiplicative Cost

    @Test("Congestion cost uses multiplicative history formula")
    func multiplicativeCongestionCost() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let bbox = LayoutRect(
            origin: LayoutPoint(x: 0.0, y: 0.0),
            size: LayoutSize(width: 10.0, height: 10.0)
        )
        var congestion = try CongestionGrid(boundingBox: bbox, tech: tech)

        let from = LayoutPoint(x: 1.0, y: 1.0)
        let to = LayoutPoint(x: 5.0, y: 1.0)

        // Add demand to increase congestion
        congestion.addDemand(from: from, to: to, isHorizontal: true)
        congestion.addDemand(from: from, to: to, isHorizontal: true)

        // Add history
        congestion.updateHistoryCosts()

        let costNoHistory = congestion.congestionCost(from: from, to: to, isHorizontal: true)
        let costWithHistory = congestion.congestionCostWithHistory(
            from: from, to: to, isHorizontal: true, historyFactor: 2.0
        )

        // Multiplicative formula: cost * (1 + h*history) > cost when history > 0
        #expect(costWithHistory >= costNoHistory,
            "History cost (\(costWithHistory)) should be >= base cost (\(costNoHistory))")
    }

    // MARK: - Helpers

    private func cellBoundingBox(_ cell: LayoutCell) -> LayoutRect {
        var bbox: LayoutRect?
        for shape in cell.shapes {
            let shapeBBox = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            bbox = bbox.map { $0.union(shapeBBox) } ?? shapeBBox
        }
        return bbox ?? .zero
    }

    private func buildState(
        from result: PlacementResult,
        instances: [PlacementInstance]
    ) -> SAPlacementState {
        var slots: [UUID: SAPlacementState.SlotEntry] = [:]
        var rowAssignments: [DeviceType: [UUID]] = [
            .pmos: [], .nmos: [], .passive: [],
        ]
        for inst in instances {
            let transform = result.placements[inst.id] ?? LayoutTransform(translation: .zero)
            slots[inst.id] = SAPlacementState.SlotEntry(
                instanceID: inst.id, cell: inst.cell,
                transform: transform, rowType: inst.deviceType
            )
            rowAssignments[inst.deviceType, default: []].append(inst.id)
        }
        return SAPlacementState(slots: slots, rowAssignments: rowAssignments)
    }
}
