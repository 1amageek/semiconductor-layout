import Foundation
import LayoutAutoGen
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify
import Testing

@Suite("MOSFET rule-admitted gate contact landings", .timeLimit(.minutes(1)))
struct MOSFETContactEnclosureTests {
    @Test func shortSingleFingerGateCoversEntireConfiguredContact() throws {
        let technology = LayoutTechDatabase.sampleProcess()
        let cell = try generate(kind: "nmos", fingers: 1, length: 0.18, technology: technology)
        let gate = try #require(cell.pins.first { $0.name == "gate" })
        let gateRect = pinRect(gate)
        let cuts = rectangles(cell, layer: "CONTACT").filter { covers(gateRect, $0) }
        let cut = try #require(cuts.first)
        #expect(cuts.count == 1)
        let polys = rectangles(cell, layer: "POLY")
        #expect(polys.contains { covers($0, cut) })
    }

    @Test(arguments: ["nmos", "pmos"], [1, 3])
    func exactRulesChannelAndTerminalsSurviveGDS(kind: String, fingers: Int) throws {
        let technology = LayoutTechDatabase.sampleProcess()
        // Below, equal to and above the minimum POLY landing width (0.38 um).
        for length in [0.18, 0.38, 0.50] {
            let cell = try generate(kind: kind, fingers: fingers, length: length, technology: technology)
            try checkGeometry(cell, fingers: fingers, technology: technology)
            let document = LayoutDocument(name: cell.name, cells: [cell], topCellID: cell.id)
            try checkDevice(document, kind: kind, fingers: fingers, length: length, technology: technology)
            let before = try DeviceExtractor().captureConductors(document: document, tech: technology)
            try checkCapture(before, expectedCuts: rectangles(cell, layer: "CONTACT").count)
            var restored = try roundTrip(document, technology: technology)
            let index = try #require(restored.cells.firstIndex { $0.id == restored.topCellID })
            #expect(restored.cells[index].shapes.count == cell.shapes.count)
            try checkGeometry(restored.cells[index], fingers: fingers, technology: technology, gate: cell.pins.first { $0.name == "gate" }, units: restored.units)
            // GDS mask geometry is unchanged; terminal roles are caller-owned annotations.
            restored.cells[index].pins = cell.pins
            try checkDevice(restored, kind: kind, fingers: fingers, length: length, technology: technology)
            let after = try DeviceExtractor().captureConductors(document: restored, tech: technology)
            try checkCapture(after, expectedCuts: rectangles(cell, layer: "CONTACT").count)
            #expect(after.hierarchy.shapes.count == before.hierarchy.shapes.count)
            #expect(after.footprints.map(\.layer) == before.footprints.map(\.layer))
            #expect(after.footprints.map(\.band) == before.footprints.map(\.band))
        }
    }

    @Test(arguments: ["nmos", "pmos"], [1, 3])
    func rectangularCutUsesActualHeightAndOutwardEnclosures(kind: String, fingers: Int) throws {
        var technology = LayoutTechDatabase.sampleProcess()
        let index = try #require(technology.contacts.firstIndex { $0.id == "CONT_POLY" })
        technology.contacts[index].cutSize.height = 0.30
        technology.contacts[index].enclosure.bottom = 0.0801
        technology.contacts[index].enclosure.top = 0.0601
        let cell = try generate(kind: kind, fingers: fingers, length: 0.18, technology: technology)
        try checkGeometry(cell, fingers: fingers, technology: technology)
        try checkDevice(LayoutDocument(name: cell.name, cells: [cell], topCellID: cell.id),
                        kind: kind, fingers: fingers, length: 0.18, technology: technology)
    }

    @Test func missingGateContactRuleFailsExplicitly() throws {
        var technology = LayoutTechDatabase.sampleProcess()
        technology.contacts.removeAll { $0.id == "CONT_POLY" }
        do {
            _ = try generate(kind: "nmos", fingers: 1, length: 0.18, technology: technology)
            Issue.record("Missing CONT_POLY was admitted")
        } catch AutoGenError.missingContactDefinition(let name) {
            #expect(name == "CONT_POLY")
        }
    }

    @Test(arguments: ["zero-width", "nonfinite-height", "negative-enclosure", "nonfinite-enclosure", "off-grid-cut", "wrong-bottom", "wrong-top", "wrong-cut", "zero-grid"])
    func invalidRequiredGateRulesFailExplicitly(_ condition: String) throws {
        var technology = LayoutTechDatabase.sampleProcess()
        let index = try #require(technology.contacts.firstIndex { $0.id == "CONT_POLY" })
        switch condition {
        case "zero-width": technology.contacts[index].cutSize.width = 0
        case "nonfinite-height": technology.contacts[index].cutSize.height = .infinity
        case "negative-enclosure": technology.contacts[index].enclosure.bottom = -0.01
        case "nonfinite-enclosure": technology.contacts[index].enclosure.top = .nan
        case "off-grid-cut": technology.contacts[index].cutSize.width = 0.2201
        case "wrong-bottom": technology.contacts[index].bottomLayer = .init(name: "ACTIVE", purpose: "drawing")
        case "wrong-top": technology.contacts[index].topLayer = .init(name: "M2", purpose: "drawing")
        case "wrong-cut": technology.contacts[index].cutLayer = .init(name: "VIA1", purpose: "cut")
        case "zero-grid": technology.grid = 0
        default: Issue.record("Unknown gate-rule test condition")
        }
        do {
            _ = try generate(kind: "nmos", fingers: 1, length: 0.18, technology: technology)
            Issue.record("Invalid gate rule was admitted: \(condition)")
        } catch AutoGenError.placementFailed { }
    }

    private func generate(kind: String, fingers: Int, length: Double, technology: LayoutTechDatabase) throws -> LayoutCell {
        try MOSFETCellGenerator().generateCell(deviceKindID: kind, instanceName: "M1",
            parameters: ["w": 2, "l": length, "nf": Double(fingers)], tech: technology)
    }

    private func checkGeometry(_ cell: LayoutCell, fingers: Int, technology: LayoutTechDatabase, gate suppliedGate: LayoutPin? = nil, units: LayoutUnits = .defaultUnits) throws {
        let gate = try #require(suppliedGate ?? cell.pins.first { $0.name == "gate" })
        let polys = rectangles(cell, layer: "POLY"), actives = rectangles(cell, layer: "ACTIVE")
        let metals = rectangles(cell, layer: "M1"), cuts = rectangles(cell, layer: "CONTACT")
        let gateCuts = cuts.filter { covers(pinRect(gate), $0) }
        #expect(gateCuts.count == fingers)
        #expect(polys.count == fingers * 2)
        for cut in cuts {
            let isGate = gateCuts.contains(cut)
            let rule = try #require(technology.contactDefinition(for: isGate ? "CONT_POLY" : "CONT_ACTIVE"))
            let widthDBU = try coordinateDBU(cut.maxX, units: units) - coordinateDBU(cut.minX, units: units)
            let heightDBU = try coordinateDBU(cut.maxY, units: units) - coordinateDBU(cut.minY, units: units)
            let expectedWidthDBU = try coordinateDBU(rule.cutSize.width, units: units)
            let expectedHeightDBU = try coordinateDBU(rule.cutSize.height, units: units)
            #expect(widthDBU == expectedWidthDBU)
            #expect(heightDBU == expectedHeightDBU)
            let bottoms = isGate ? polys : actives
            #expect(bottoms.contains { covers($0, cut) })
            #expect(metals.contains { covers($0, cut) })
            #expect(bottoms.contains { covers($0, cut.expanded(by: rule.enclosure.bottom, rule.enclosure.bottom)) })
            #expect(metals.contains { covers($0, cut.expanded(by: rule.enclosure.top, rule.enclosure.top)) })
            if isGate {
                let landing = try #require(polys.first { polygon in
                    covers(polygon, cut.expanded(by: rule.enclosure.bottom, rule.enclosure.bottom))
                        && actives.allSatisfy { !overlaps($0, polygon) }
                })
                #expect(actives.allSatisfy { !overlaps($0, landing) })
                #expect(polys.contains { $0 != landing && overlaps($0, landing) })
            }
        }
    }

    private func checkDevice(_ document: LayoutDocument, kind: String, fingers: Int, length: Double, technology: LayoutTechDatabase) throws {
        let result = try DeviceExtractor().extract(document: document, tech: technology)
        #expect(result.issues.isEmpty)
        #expect(result.netlist.devices.count == 1)
        let device = try #require(result.netlist.devices.first)
        #expect(device.kind == (kind == "nmos" ? .nmos : .pmos))
        #expect(close(device.parameters.width, 2))
        #expect(close(device.parameters.length, length))
        #expect(device.parameters.multiplier == fingers)
        #expect(Set(device.terminals.values).count == 4)
        for role in ComparisonTerminalRole.allCases {
            let terminal = try #require(device.terminals[role])
            #expect(result.netlist.ports[role.rawValue] == terminal)
        }
    }

    private func checkCapture(_ snapshot: LayoutConductorSnapshot, expectedCuts: Int) throws {
        #expect(snapshot.shortComponentIndices.isEmpty)
        #expect(snapshot.opens.isEmpty)
        #expect(snapshot.components.count == 4)
        #expect(snapshot.pins.count == 4)
        #expect(snapshot.pins.allSatisfy { $0.componentIndices.count == 1 })
        let cuts = snapshot.footprints.indices.filter { snapshot.footprints[$0].isCut }
        #expect(cuts.count == expectedCuts)
        for cutIndex in cuts {
            let cut = snapshot.footprints[cutIndex]
            let contacts = snapshot.contacts.compactMap { contact -> Int? in
                if contact.firstFootprint == cutIndex { return contact.secondFootprint }
                if contact.secondFootprint == cutIndex { return contact.firstFootprint }
                return nil
            }
            let bottomNames = Set(contacts.map { snapshot.footprints[$0].layer.name }).intersection(["ACTIVE", "POLY"])
            #expect(bottomNames.count == 1)
            let bottom = try #require(bottomNames.first)
            for layer in [bottom, "M1"] {
                let bands = contacts.map { snapshot.footprints[$0] }.filter { $0.layer.name == layer }.map(\.band)
                #expect(!bands.isEmpty)
                // Exact partition boundaries refute any uncovered portion of the cut.
                let xs = Array(Set([cut.band.minX, cut.band.maxX] + bands.flatMap { [$0.minX, $0.maxX] }))
                    .filter { $0 >= cut.band.minX && $0 <= cut.band.maxX }.sorted()
                let ys = Array(Set([cut.band.minY, cut.band.maxY] + bands.flatMap { [$0.minY, $0.maxY] }))
                    .filter { $0 >= cut.band.minY && $0 <= cut.band.maxY }.sorted()
                for xi in 0..<(xs.count - 1) {
                    for yi in 0..<(ys.count - 1) {
                        #expect(bands.contains { $0.minX <= xs[xi] && $0.maxX >= xs[xi + 1]
                            && $0.minY <= ys[yi] && $0.maxY >= ys[yi + 1] })
                    }
                }
            }
        }
    }

    private func roundTrip(_ document: LayoutDocument, technology: LayoutTechDatabase) throws -> LayoutDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mos-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Temporary GDS cleanup failed: \(error)") }
        }
        let output = directory.appendingPathComponent("actual.gds")
        let converter = MaskDataFormatConverter(tech: technology)
        try converter.exportDocument(document, to: output, format: .gds)
        return try converter.importFromData(Data(contentsOf: output), format: .gds)
    }

    private func rectangles(_ cell: LayoutCell, layer: String) -> [LayoutRect] {
        cell.shapes.compactMap { shape in
            guard shape.layer.name == layer else { return nil }
            switch shape.geometry {
            case .rect(let rectangle): return rectangle
            case .polygon(let polygon):
                var points = polygon.points
                if points.first == points.last { points.removeLast() }
                guard points.count == 4 else { Issue.record("Expected rectangular mask boundary"); return nil }
                guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                      let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
                let corners: Set<LayoutPoint> = [.init(x: minX, y: minY), .init(x: maxX, y: minY),
                    .init(x: maxX, y: maxY), .init(x: minX, y: maxY)]
                guard Set(points) == corners, points.indices.allSatisfy({ index in
                    let next = points[(index + 1) % points.count]
                    return points[index].x == next.x || points[index].y == next.y
                }) else { Issue.record("Mask boundary is not an axis-aligned rectangle"); return nil }
                return LayoutRect(origin: .init(x: minX, y: minY),
                    size: .init(width: maxX - minX, height: maxY - minY))
            case .path: Issue.record("Expected rectangular mask boundary"); return nil
            }
        }
    }

    private func pinRect(_ pin: LayoutPin) -> LayoutRect {
        LayoutRect(origin: .init(x: pin.position.x - pin.size.width / 2,
                               y: pin.position.y - pin.size.height / 2), size: pin.size)
    }

    private func coordinateDBU(_ coordinate: Double, units: LayoutUnits) throws -> Int64 {
        let scaled = coordinate * units.scale.databaseUnitsPerMicrometer
        let rounded = scaled.rounded(.toNearestOrEven)
        try #require(scaled.isFinite && abs(scaled - rounded) <= max(scaled.ulp, rounded.ulp) * 4)
        return try units.scale.databaseUnits(forMicrometers: coordinate)
    }

    private func close(_ first: Double, _ second: Double) -> Bool {
        abs(first - second) <= max(first.ulp, second.ulp) * 8
    }

    private func covers(_ outer: LayoutRect, _ inner: LayoutRect) -> Bool {
        (outer.minX <= inner.minX || close(outer.minX, inner.minX))
            && (outer.minY <= inner.minY || close(outer.minY, inner.minY))
            && (outer.maxX >= inner.maxX || close(outer.maxX, inner.maxX))
            && (outer.maxY >= inner.maxY || close(outer.maxY, inner.maxY))
    }

    private func overlaps(_ first: LayoutRect, _ second: LayoutRect) -> Bool {
        max(first.minX, second.minX) < min(first.maxX, second.maxX)
            && max(first.minY, second.minY) < min(first.maxY, second.maxY)
    }
}
