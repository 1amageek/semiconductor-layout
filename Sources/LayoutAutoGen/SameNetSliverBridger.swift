import Foundation
import LayoutCore
import LayoutTech

/// Merges same-net sliver gaps left behind by routing.
///
/// Two shapes of the SAME net on the same layer may either touch (they
/// merge into one mask feature) or keep the layer's full min spacing;
/// a gap in between is a spacing violation no reroute can fix, because
/// the connectivity that put both shapes there is legitimate. The
/// physical repair is to close the gap: same-net metal may always be
/// widened into its own net. This pass finds axis-aligned same-net
/// pairs whose facing edges overlap and are closer than min spacing,
/// and inserts a bridge rect covering the gap so the shapes merge.
///
/// Diagonal (corner-to-corner) slivers are left alone — an axis-aligned
/// bridge cannot merge them — and the caller's final DRC keeps reporting
/// them. Nothing is waived here; the bridge is real geometry the DRC
/// re-judges.
public struct SameNetSliverBridger: Sendable {

    public init() {}

    /// Bridges same-net sliver gaps in `cellID` (or the top cell) of
    /// `document`. Returns the number of bridges inserted.
    @discardableResult
    public func bridge(
        document: inout LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) -> Int {
        guard let targetCellID = cellID ?? document.topCellID,
              let cellIndex = document.cells.firstIndex(where: { $0.id == targetCellID }) else {
            return 0
        }
        var cell = document.cells[cellIndex]
        var inserted = 0

        // Grouping by (layer, net) keeps the scan quadratic only within
        // one net's shapes on one layer, which routing keeps small.
        struct GroupKey: Hashable {
            let layerName: String
            let layerPurpose: String
            let netID: UUID
        }
        var groups: [GroupKey: [LayoutShape]] = [:]
        for shape in cell.shapes {
            guard let netID = shape.netID else { continue }
            guard case .rect = shape.geometry else { continue }
            let key = GroupKey(
                layerName: shape.layer.name,
                layerPurpose: shape.layer.purpose,
                netID: netID
            )
            groups[key, default: []].append(shape)
        }

        let tolerance = 1.0e-9
        for (_, shapes) in groups {
            guard shapes.count >= 2 else { continue }
            guard let rules = tech.ruleSet(for: shapes[0].layer), rules.minSpacing > 0 else { continue }
            let minSpacing = rules.minSpacing

            for i in shapes.indices {
                for j in shapes.indices where j > i {
                    guard case .rect(let a) = shapes[i].geometry,
                          case .rect(let b) = shapes[j].geometry else { continue }
                    guard let bridgeRect = Self.bridgeRect(
                        a,
                        b,
                        minSpacing: minSpacing,
                        tolerance: tolerance
                    ) else { continue }
                    cell.shapes.append(LayoutShape(
                        layer: shapes[i].layer,
                        netID: shapes[i].netID,
                        geometry: .rect(bridgeRect)
                    ))
                    inserted += 1
                }
            }
        }

        guard inserted > 0 else { return 0 }
        document.cells[cellIndex] = cell
        return inserted
    }

    /// The gap-covering rect between two rects whose facing edges
    /// overlap and sit at a positive gap below `minSpacing`; nil when
    /// the pair touches, keeps legal spacing, or only meets diagonally.
    static func bridgeRect(
        _ a: LayoutRect,
        _ b: LayoutRect,
        minSpacing: Double,
        tolerance: Double
    ) -> LayoutRect? {
        let aMaxX = a.origin.x + a.size.width
        let bMaxX = b.origin.x + b.size.width
        let aMaxY = a.origin.y + a.size.height
        let bMaxY = b.origin.y + b.size.height

        let gapX = max(b.origin.x - aMaxX, a.origin.x - bMaxX)
        let gapY = max(b.origin.y - aMaxY, a.origin.y - bMaxY)

        let overlapMinY = max(a.origin.y, b.origin.y)
        let overlapMaxY = min(aMaxY, bMaxY)
        let overlapMinX = max(a.origin.x, b.origin.x)
        let overlapMaxX = min(aMaxX, bMaxX)

        if gapX > tolerance, gapX < minSpacing - tolerance, gapY <= tolerance,
           overlapMaxY - overlapMinY > tolerance {
            let left = min(aMaxX, bMaxX)
            return LayoutRect(
                origin: LayoutPoint(x: left, y: overlapMinY),
                size: LayoutSize(width: gapX, height: overlapMaxY - overlapMinY)
            )
        }
        if gapY > tolerance, gapY < minSpacing - tolerance, gapX <= tolerance,
           overlapMaxX - overlapMinX > tolerance {
            let bottom = min(aMaxY, bMaxY)
            return LayoutRect(
                origin: LayoutPoint(x: overlapMinX, y: bottom),
                size: LayoutSize(width: overlapMaxX - overlapMinX, height: gapY)
            )
        }
        return nil
    }
}
