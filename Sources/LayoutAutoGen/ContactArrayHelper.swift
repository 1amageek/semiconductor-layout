import Foundation
import LayoutCore
import LayoutTech

/// Shared utilities for contact array generation used by all device cell generators.
enum ContactArrayHelper {

    /// Snaps a value to the nearest grid point.
    static func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }

    /// Snaps a spacing requirement upward so manufacturing-grid rounding cannot
    /// reduce an already-minimum pitch below the rule.
    static func snapUp(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded(.up) * grid
    }

    /// Generates a 1D contact array along the Y axis within a fixed-X column.
    ///
    /// Contacts are centered within the available region height and evenly spaced
    /// using the minimum cut spacing from the contact definition.
    ///
    /// - Parameters:
    ///   - regionX: X coordinate of the contact column.
    ///   - regionY: Bottom Y of the available region.
    ///   - regionHeight: Height of the available region.
    ///   - contSize: Width and height of each contact cut.
    ///   - contSpacing: Minimum spacing between adjacent contacts.
    ///   - contLayer: Layer ID for the contact cuts.
    ///   - grid: Manufacturing grid for snapping.
    /// - Returns: Array of LayoutShape representing the contact cuts.
    static func generateContacts1D(
        regionX: Double,
        regionY: Double,
        regionHeight: Double,
        contSize: Double,
        contSpacing: Double,
        contLayer: LayoutLayerID,
        grid: Double
    ) -> [LayoutShape] {
        var contacts: [LayoutShape] = []
        let pitch = snapUp(contSize + contSpacing, grid: grid)
        let effectiveSpacing = pitch - contSize
        let count = max(1, Int(floor((regionHeight + effectiveSpacing) / pitch)))
        let totalHeight = contSize + Double(count - 1) * pitch
        let startY = snap(regionY + (regionHeight - totalHeight) / 2, grid: grid)
        let x = snap(regionX, grid: grid)

        for i in 0..<count {
            let y = snap(startY + Double(i) * pitch, grid: grid)
            let rect = LayoutRect(
                origin: LayoutPoint(x: x, y: y),
                size: LayoutSize(width: contSize, height: contSize)
            )
            contacts.append(LayoutShape(layer: contLayer, geometry: .rect(rect)))
        }
        return contacts
    }

    /// Generates a 2D contact array (X x Y) within a rectangular region.
    ///
    /// Used for well/substrate taps where multiple columns and rows of contacts
    /// are needed to provide low-resistance connections.
    ///
    /// - Parameters:
    ///   - regionX: Left X of the available region.
    ///   - regionY: Bottom Y of the available region.
    ///   - regionWidth: Width of the available region.
    ///   - regionHeight: Height of the available region.
    ///   - contSize: Width and height of each contact cut.
    ///   - contSpacing: Minimum spacing between adjacent contacts.
    ///   - contLayer: Layer ID for the contact cuts.
    ///   - grid: Manufacturing grid for snapping.
    /// - Returns: Array of LayoutShape representing the contact cuts.
    static func generateContacts2D(
        regionX: Double,
        regionY: Double,
        regionWidth: Double,
        regionHeight: Double,
        contSize: Double,
        contSpacing: Double,
        contLayer: LayoutLayerID,
        grid: Double
    ) -> [LayoutShape] {
        var contacts: [LayoutShape] = []
        let pitch = snapUp(contSize + contSpacing, grid: grid)
        let effectiveSpacing = pitch - contSize

        let colCount = max(1, Int(floor((regionWidth + effectiveSpacing) / pitch)))
        let rowCount = max(1, Int(floor((regionHeight + effectiveSpacing) / pitch)))

        let totalWidth = contSize + Double(colCount - 1) * pitch
        let totalHeight = contSize + Double(rowCount - 1) * pitch

        let startX = snap(regionX + (regionWidth - totalWidth) / 2, grid: grid)
        let startY = snap(regionY + (regionHeight - totalHeight) / 2, grid: grid)

        for row in 0..<rowCount {
            let y = snap(startY + Double(row) * pitch, grid: grid)
            for col in 0..<colCount {
                let x = snap(startX + Double(col) * pitch, grid: grid)
                let rect = LayoutRect(
                    origin: LayoutPoint(x: x, y: y),
                    size: LayoutSize(width: contSize, height: contSize)
                )
                contacts.append(LayoutShape(layer: contLayer, geometry: .rect(rect)))
            }
        }
        return contacts
    }
}
