import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

extension LayoutDRCService {
    func evaluationScale(for tech: LayoutTechDatabase) -> Double {
        (exactGeometry?.coordinateUnits ?? tech.units).scale.databaseUnitsPerMicrometer
    }

    func ruleCoordinate(_ value: Double, dbu: Double) throws -> Int32 {
        if exactGeometry != nil { return try ExactDRCGeometry.coordinate(value, dbu: dbu) }
        let scaled = (value * dbu).rounded()
        guard scaled.isFinite, let result = Int32(exactly: scaled) else {
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: nil)
        }
        return result
    }

    func geometryToRegion(_ geometry: LayoutGeometry, dbu: Double) throws -> Region {
        if let exactGeometry { return try exactGeometry.region(for: geometry) }
        guard let boundary = geometryToIRBoundary(geometry, dbu: dbu) else {
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: nil)
        }
        return Region(polygons: [boundary])
    }

    /// Physical contact includes shared edges and corners, preserving staged antenna semantics.
    func geometriesTouch(_ first: LayoutGeometry, _ second: LayoutGeometry, dbu: Double) throws -> Bool {
        guard exactGeometry != nil else { return LayoutGeometryAnalysis.intersects(first, second) }
        let a = try geometryToRegion(first, dbu: dbu), b = try geometryToRegion(second, dbu: dbu)
        return try regionsTouch(a, b)
    }

    /// Consumes already-admitted integer coverage without a display-geometry round trip.
    func regionsTouch(_ a: Region, _ b: Region) throws -> Bool {
        if try !a.intersection(b).isEmpty { return true }
        // Boundary-inclusive containment also detects zero-area endpoint contact.
        if a.polygons.contains(where: { $0.points.contains(where: b.contains) }) { return true }
        return b.polygons.contains { $0.points.contains(where: a.contains) }
    }

    func validateActiveThresholds(tech: LayoutTechDatabase) throws {
        guard let exactGeometry else { return }
        let dbu = evaluationScale(for: tech)
        let activeLayers = Set(exactGeometry.entries.map { $0.shape.layer })
        func distance(_ value: Double) throws { _ = try ExactDRCGeometry.coordinate(value, dbu: dbu) }
        func area(_ value: Double) throws {
            let scaled = value * dbu * dbu, rounded = scaled.rounded()
            guard value.isFinite, scaled.isFinite, abs(scaled - rounded) <= scaled.ulp * 4,
                  Int64(exactly: rounded) != nil else {
                throw ExactDRCGeometryError.invalidGridGeometry(sourceID: nil)
            }
        }
        for layer in activeLayers {
            guard let rules = tech.ruleSet(for: layer) else { continue }
            if rules.minWidth > 0 { try distance(rules.minWidth) }
            if rules.minSpacing > 0 { try distance(rules.minSpacing) }
            if rules.minArea > 0 { try area(rules.minArea) }
            if let value = rules.minNotch, value > 0 { try distance(value) }
            if let value = rules.minEnclosedArea, value > 0 { try area(value) }
            if let width = rules.wideWidthThreshold, let spacing = rules.wideSpacing,
               width > 0, spacing > 0 { try distance(width / 2); try distance(spacing) }
            if rules.minDensity > 0 || rules.maxDensity < 1 {
                if let window = rules.densityWindow { try distance(window.width); try distance(window.height) }
                if let step = rules.densityStep { try distance(step) }
            }
        }
        for rule in tech.spacingRules where activeLayers.contains(rule.primaryLayer)
            && activeLayers.contains(rule.secondaryLayer) && rule.minSpacing > 0 { try distance(rule.minSpacing) }
        for rule in tech.enclosureRules where activeLayers.contains(rule.outerLayer)
            && activeLayers.contains(rule.innerLayer) && rule.minEnclosure > 0 { try distance(rule.minEnclosure) }
        for rule in tech.extensionRules where activeLayers.contains(rule.extendingLayer)
            && activeLayers.contains(rule.enclosedLayer) && rule.minExtension > 0 { try distance(rule.minExtension) }
    }
}
