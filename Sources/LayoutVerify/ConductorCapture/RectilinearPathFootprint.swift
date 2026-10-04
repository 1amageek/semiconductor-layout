import Foundation
import LayoutCore

/// Streams integer union pieces of an admitted orthogonal, square-miter stroke.
enum RectilinearPathFootprint {
    static func emit(_ path: LayoutPath, sourceID: UUID, coordinate: (Double) throws -> Int32,
                     isCancelled: () -> Bool,
                     rectangle: (Int32, Int32, Int32, Int32) throws -> Void) throws {
        typealias Failure = LayoutConductorCaptureError
        guard path.points.count >= 2, path.width.isFinite, path.width > 0 else {
            throw Failure.invalidGridGeometry(sourceID)
        }
        guard path.endCap != .round else { throw Failure.unsupportedGeometry(sourceID) }
        let width = Int64(try coordinate(path.width))
        guard width > 0, width.isMultiple(of: 2) else { throw Failure.invalidGridGeometry(sourceID) }
        let half = width / 2
        let extensions: (begin: Int64, end: Int64)
        switch path.endCap {
        case .truncate: extensions = (0, 0)
        case .extend: extensions = (half, half)
        case .custom(let begin, let end):
            extensions = (Int64(try coordinate(begin)), Int64(try coordinate(end)))
        case .round: throw Failure.unsupportedGeometry(sourceID)
        }

        func segment(_ index: Int) throws -> (x: Int64, y: Int64, nextX: Int64, nextY: Int64,
                                              horizontal: Bool, direction: Int64, length: Int64) {
            let first = path.points[index - 1], second = path.points[index]
            guard first.x.isFinite, first.y.isFinite, second.x.isFinite, second.y.isFinite else {
                throw Failure.invalidGridGeometry(sourceID)
            }
            let horizontal = first.y == second.y, vertical = first.x == second.x
            guard horizontal != vertical else { throw Failure.unsupportedGeometry(sourceID) }
            let x = Int64(try coordinate(first.x)), y = Int64(try coordinate(first.y))
            let nextX = Int64(try coordinate(second.x)), nextY = Int64(try coordinate(second.y))
            let delta = horizontal ? nextX - x : nextY - y
            guard delta != 0 else { throw Failure.invalidGridGeometry(sourceID) }
            return (x, y, nextX, nextY, horizontal, delta > 0 ? 1 : -1, abs(delta))
        }
        // Int32 primitives keep all length, cap and endpoint intermediates within Int64.
        // Final endpoints are checked before emitting any individual rectangle.
        func emitRectangle(_ minX: Int64, _ minY: Int64, _ maxX: Int64, _ maxY: Int64) throws {
            guard minX < maxX, minY < maxY,
                  let x = Int32(exactly: minX), let y = Int32(exactly: minY),
                  let endX = Int32(exactly: maxX), let endY = Int32(exactly: maxY) else {
                throw Failure.invalidGridGeometry(sourceID)
            }
            try rectangle(x, y, endX, endY)
        }
        let firstSegment = try segment(1), lastSegment = try segment(path.points.count - 1)
        guard extensions.begin > -firstSegment.length, extensions.end > -lastSegment.length,
              path.points.count != 2 || firstSegment.length + extensions.begin + extensions.end > 0 else {
            throw Failure.invalidGridGeometry(sourceID)
        }
        // A retracted cap entering the first/last miter requires clipping, not rectangle union.
        if path.points.count > 2 {
            let firstTurns = firstSegment.horizontal != (path.points[1].y == path.points[2].y)
            let lastTurns = (path.points[path.points.count - 3].y == path.points[path.points.count - 2].y)
                != lastSegment.horizontal
            guard !(firstTurns && extensions.begin < 0 && firstSegment.length + extensions.begin < half),
                  !(lastTurns && extensions.end < 0 && lastSegment.length + extensions.end < half) else {
                throw Failure.unsupportedGeometry(sourceID)
            }
        }
        var previousHorizontal: Bool?, previousDirection: Int64?
        for index in 1..<path.points.count {
            if isCancelled() { throw Failure.cancelled }
            let current = try segment(index)
            if let axis = previousHorizontal, let previous = previousDirection {
                if axis == current.horizontal {
                    guard previous == current.direction else { throw Failure.unsupportedGeometry(sourceID) }
                } else {
                    try emitRectangle(current.x - half, current.y - half, current.x + half, current.y + half)
                }
            }
            let begin = index == 1 ? extensions.begin : 0
            let end = index == path.points.count - 1 ? extensions.end : 0
            if current.horizontal {
                let a = current.x - current.direction * begin, b = current.nextX + current.direction * end
                try emitRectangle(min(a, b), current.y - half, max(a, b), current.y + half)
            } else {
                let a = current.y - current.direction * begin, b = current.nextY + current.direction * end
                try emitRectangle(current.x - half, min(a, b), current.x + half, max(a, b))
            }
            previousHorizontal = current.horizontal; previousDirection = current.direction
        }
    }
}
