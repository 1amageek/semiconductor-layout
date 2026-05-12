import Foundation
import LayoutCore
import LayoutTech

/// Grid-based routing congestion tracker.
///
/// Divides the placement area into cells and tracks horizontal/vertical
/// wire demand vs capacity in each cell.
struct CongestionGrid: Sendable {
    struct GridCell: Sendable {
        var hCapacity: Int
        var vCapacity: Int
        var hDemand: Int = 0
        var vDemand: Int = 0
        var historyCost: Double = 0.0

        var hCongestion: Double {
            hCapacity > 0 ? Double(hDemand) / Double(hCapacity) : 0
        }
        var vCongestion: Double {
            vCapacity > 0 ? Double(vDemand) / Double(vCapacity) : 0
        }
        var isOvercongested: Bool {
            hDemand > hCapacity || vDemand > vCapacity
        }
        var maxCongestion: Double {
            max(hCongestion, vCongestion)
        }
    }

    private(set) var cells: [[GridCell]]
    let cellSize: Double
    let origin: LayoutPoint
    let rows: Int
    let cols: Int

    init(boundingBox: LayoutRect, tech: LayoutTechDatabase) throws {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Rules = try tech.requiredRuleSet(for: m1ID)
        let m2Rules = try tech.requiredRuleSet(for: m2ID)
        let m1Pitch = m1Rules.minWidth + m1Rules.minSpacing
        let m2Pitch = m2Rules.minWidth + m2Rules.minSpacing

        // Cell size: ~10 track pitches
        self.cellSize = max(m1Pitch, m2Pitch) * 10
        self.origin = boundingBox.origin

        let width = max(boundingBox.size.width, cellSize)
        let height = max(boundingBox.size.height, cellSize)
        self.cols = max(Int(ceil(width / cellSize)), 1)
        self.rows = max(Int(ceil(height / cellSize)), 1)

        // Capacity: number of tracks that fit in each cell
        let hCapacity = max(Int(cellSize / m1Pitch), 1)
        let vCapacity = max(Int(cellSize / m2Pitch), 1)

        let defaultCell = GridCell(hCapacity: hCapacity, vCapacity: vCapacity)
        self.cells = Array(repeating: Array(repeating: defaultCell, count: cols), count: rows)
    }

    /// Adds routing demand for a segment.
    mutating func addDemand(from: LayoutPoint, to: LayoutPoint, isHorizontal: Bool) {
        let affectedCells = cellsAlong(from: from, to: to)
        for (r, c) in affectedCells {
            if isHorizontal {
                cells[r][c].hDemand += 1
            } else {
                cells[r][c].vDemand += 1
            }
        }
    }

    /// Removes routing demand for a segment.
    mutating func removeDemand(from: LayoutPoint, to: LayoutPoint, isHorizontal: Bool) {
        let affectedCells = cellsAlong(from: from, to: to)
        for (r, c) in affectedCells {
            if isHorizontal {
                cells[r][c].hDemand = max(0, cells[r][c].hDemand - 1)
            } else {
                cells[r][c].vDemand = max(0, cells[r][c].vDemand - 1)
            }
        }
    }

    /// Returns the congestion cost for a segment (sum of congestion along path).
    func congestionCost(from: LayoutPoint, to: LayoutPoint, isHorizontal: Bool) -> Double {
        let affectedCells = cellsAlong(from: from, to: to)
        var cost = 0.0
        for (r, c) in affectedCells {
            let cell = cells[r][c]
            cost += isHorizontal ? cell.hCongestion : cell.vCongestion
        }
        return cost
    }

    /// Returns true if any cell is overcongested.
    func hasOvercongestion() -> Bool {
        cells.contains { row in row.contains { $0.isOvercongested } }
    }

    /// Returns indices of overcongested cells.
    func overcongestedCells() -> [(row: Int, col: Int)] {
        var result: [(row: Int, col: Int)] = []
        for r in 0..<rows {
            for c in 0..<cols {
                if cells[r][c].isOvercongested {
                    result.append((row: r, col: c))
                }
            }
        }
        return result
    }

    // MARK: - History Cost (Pathfinder-style)

    /// Increments history cost for all overcongested cells.
    ///
    /// Called once per rip-up/reroute iteration. Cells that remain overcongested
    /// accumulate higher history costs, discouraging future routes from using them.
    mutating func updateHistoryCosts(factor: Double = 1.0) {
        for r in 0..<rows {
            for c in 0..<cols {
                if cells[r][c].isOvercongested {
                    cells[r][c].historyCost += factor
                }
            }
        }
    }

    /// Returns congestion cost including accumulated history for a segment.
    ///
    /// Uses multiplicative formula: `baseCost * (1 + historyFactor * historyCost)`
    /// so that history amplifies congestion rather than adding a flat offset.
    /// Adds a present-congestion penalty for overcongested cells (demand > capacity).
    func congestionCostWithHistory(
        from: LayoutPoint,
        to: LayoutPoint,
        isHorizontal: Bool,
        historyFactor: Double = 0.5,
        presentPenalty: Double = 2.0
    ) -> Double {
        let affectedCells = cellsAlong(from: from, to: to)
        var cost = 0.0
        for (r, c) in affectedCells {
            let cell = cells[r][c]
            let baseCost = isHorizontal ? cell.hCongestion : cell.vCongestion
            // Multiplicative history: history amplifies base congestion
            var cellCost = baseCost * (1.0 + historyFactor * cell.historyCost)
            // Present penalty for overcongested cells
            let demand = isHorizontal ? cell.hDemand : cell.vDemand
            let capacity = isHorizontal ? cell.hCapacity : cell.vCapacity
            if demand > capacity {
                cellCost += presentPenalty * Double(demand - capacity)
            }
            cost += cellCost
        }
        return cost
    }

    /// Returns congestion cost including history for a single grid cell at (row, col).
    ///
    /// Used by MazeRouter for per-cell cost queries during A* search.
    func cellCostWithHistory(
        row: Int,
        col: Int,
        isHorizontal: Bool,
        historyFactor: Double = 0.5,
        presentPenalty: Double = 2.0
    ) -> Double {
        guard row >= 0, row < rows, col >= 0, col < cols else { return .infinity }
        let cell = cells[row][col]
        let baseCost = isHorizontal ? cell.hCongestion : cell.vCongestion
        var cellCost = baseCost * (1.0 + historyFactor * cell.historyCost)
        let demand = isHorizontal ? cell.hDemand : cell.vDemand
        let capacity = isHorizontal ? cell.hCapacity : cell.vCapacity
        if demand > capacity {
            cellCost += presentPenalty * Double(demand - capacity)
        }
        return cellCost
    }

    /// Converts a layout point to grid cell coordinates (row, col).
    func gridCoordinates(for point: LayoutPoint) -> (row: Int, col: Int) {
        let col = max(0, min(cols - 1, Int((point.x - origin.x) / cellSize)))
        let row = max(0, min(rows - 1, Int((point.y - origin.y) / cellSize)))
        return (row, col)
    }

    /// Converts grid cell coordinates (row, col) to a layout point (center of cell).
    func layoutPoint(row: Int, col: Int) -> LayoutPoint {
        LayoutPoint(
            x: origin.x + (Double(col) + 0.5) * cellSize,
            y: origin.y + (Double(row) + 0.5) * cellSize
        )
    }

    // MARK: - Metrics API

    /// Returns the peak congestion ratio across all cells.
    func peakCongestion() -> Double {
        var peak = 0.0
        for row in cells {
            for cell in row {
                peak = max(peak, cell.maxCongestion)
            }
        }
        return peak
    }

    /// Returns the number of overcongested cells.
    func overcongestedCellCount() -> Int {
        var count = 0
        for row in cells {
            for cell in row {
                if cell.isOvercongested {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - Private

    /// Returns grid cell indices that a segment passes through.
    private func cellsAlong(from: LayoutPoint, to: LayoutPoint) -> [(Int, Int)] {
        let minX = min(from.x, to.x)
        let maxX = max(from.x, to.x)
        let minY = min(from.y, to.y)
        let maxY = max(from.y, to.y)

        let colStart = max(0, Int((minX - origin.x) / cellSize))
        let colEnd = min(cols - 1, Int((maxX - origin.x) / cellSize))
        let rowStart = max(0, Int((minY - origin.y) / cellSize))
        let rowEnd = min(rows - 1, Int((maxY - origin.y) / cellSize))

        guard rowStart <= rowEnd, colStart <= colEnd else { return [] }

        var result: [(Int, Int)] = []
        for r in rowStart...rowEnd {
            for c in colStart...colEnd {
                result.append((r, c))
            }
        }
        return result
    }
}
