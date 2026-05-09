import Foundation
import LayoutCore

/// Quantitative quality metrics for an auto-generated layout.
public struct LayoutQualityMetrics: Sendable, Codable {
    /// Sum of all routed segment lengths in micrometers.
    public var totalWirelength: Double
    /// Half-perimeter wirelength estimated from placement (before routing).
    public var hpwl: Double
    /// Total number of vias in the layout.
    public var viaCount: Int
    /// Bounding box area in µm².
    public var totalArea: Double
    /// Layout bounding box.
    public var boundingBox: LayoutRect
    /// Total number of DRC violations.
    public var drcViolationCount: Int
    /// DRC violation breakdown by kind (rawValue string key).
    public var drcViolationsByKind: [String: Int]
    /// Fraction of nets successfully routed (0.0–1.0).
    public var routingCompletionRate: Double
    /// Number of nets with completed routes.
    public var routedNetCount: Int
    /// Total number of nets attempted.
    public var totalNetCount: Int
    /// Names of nets that could not be routed.
    public var unroutedNets: [String]
    /// Fraction of layout constraints satisfied (0.0–1.0).
    public var constraintSatisfactionRate: Double
    /// Peak congestion ratio across all routing grid cells.
    public var peakCongestion: Double
    /// Number of routing grid cells that exceed capacity.
    public var overcongestedCellCount: Int
    /// Device area / bounding box area (0.0–1.0).
    public var whiteSpaceUtilization: Double
    /// Bounding box width / height.
    public var aspectRatio: Double

    public init(
        totalWirelength: Double = 0,
        hpwl: Double = 0,
        viaCount: Int = 0,
        totalArea: Double = 0,
        boundingBox: LayoutRect = .zero,
        drcViolationCount: Int = 0,
        drcViolationsByKind: [String: Int] = [:],
        routingCompletionRate: Double = 1.0,
        routedNetCount: Int = 0,
        totalNetCount: Int = 0,
        unroutedNets: [String] = [],
        constraintSatisfactionRate: Double = 1.0,
        peakCongestion: Double = 0,
        overcongestedCellCount: Int = 0,
        whiteSpaceUtilization: Double = 0,
        aspectRatio: Double = 1.0
    ) {
        self.totalWirelength = totalWirelength
        self.hpwl = hpwl
        self.viaCount = viaCount
        self.totalArea = totalArea
        self.boundingBox = boundingBox
        self.drcViolationCount = drcViolationCount
        self.drcViolationsByKind = drcViolationsByKind
        self.routingCompletionRate = routingCompletionRate
        self.routedNetCount = routedNetCount
        self.totalNetCount = totalNetCount
        self.unroutedNets = unroutedNets
        self.constraintSatisfactionRate = constraintSatisfactionRate
        self.peakCongestion = peakCongestion
        self.overcongestedCellCount = overcongestedCellCount
        self.whiteSpaceUtilization = whiteSpaceUtilization
        self.aspectRatio = aspectRatio
    }
}

/// Comparison result between baseline and improved layout metrics.
public struct MetricsComparison: Sendable {
    /// Positive values indicate improvement (reduction).
    public var wirelengthImprovement: Double
    public var areaImprovement: Double
    public var viaCountImprovement: Double
    public var drcImprovement: Double
    public var routingCompletionImprovement: Double

    /// Human-readable summary of improvements.
    public var summary: String {
        var lines: [String] = []
        lines.append("Wirelength: \(formatPercent(wirelengthImprovement))")
        lines.append("Area: \(formatPercent(areaImprovement))")
        lines.append("Via count: \(formatPercent(viaCountImprovement))")
        lines.append("DRC violations: \(formatPercent(drcImprovement))")
        lines.append("Routing completion: \(formatPercent(routingCompletionImprovement))")
        return lines.joined(separator: "\n")
    }

    private func formatPercent(_ value: Double) -> String {
        if value > 0 {
            return String(format: "+%.1f%%", value * 100)
        } else if value < 0 {
            return String(format: "%.1f%%", value * 100)
        }
        return "0.0%"
    }
}
