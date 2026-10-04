import Foundation
import LayoutCore

/// Streams the exact union pieces of an admitted orthogonal, square-miter stroke.
enum RectilinearPathFootprint {
    static func emit(_ path: LayoutPath, sourceID: UUID, isCancelled: () -> Bool,
                     rectangle: (LayoutRect) throws -> Void) throws {
        typealias Failure = LayoutConductorCaptureError
        guard path.points.count >= 2, path.width.isFinite, path.width > 0 else {
            throw Failure.invalidGridGeometry(sourceID)
        }
        guard path.endCap != .round else { throw Failure.unsupportedGeometry(sourceID) }
        let half = path.width / 2
        guard half > 0 else { throw Failure.invalidGridGeometry(sourceID) }
        var previousHorizontal: Bool?, previousDirection: Double?
        for index in 1..<path.points.count {
            if isCancelled() { throw Failure.cancelled }
            let first = path.points[index - 1], second = path.points[index]
            guard first.x.isFinite, first.y.isFinite, second.x.isFinite, second.y.isFinite else {
                throw Failure.invalidGridGeometry(sourceID)
            }
            let horizontal = first.y == second.y, vertical = first.x == second.x
            guard horizontal != vertical else { throw Failure.unsupportedGeometry(sourceID) }
            let direction = (horizontal ? second.x > first.x : second.y > first.y) ? 1.0 : -1.0
            if let axis = previousHorizontal, let previous = previousDirection {
                if axis == horizontal {
                    guard previous == direction else { throw Failure.unsupportedGeometry(sourceID) }
                } else {
                    try rectangle(.init(origin: .init(x: first.x - half, y: first.y - half),
                                        size: .init(width: path.width, height: path.width)))
                }
            }
            let begin = index == 1 && path.endCap == .extend ? half : 0
            let end = index == path.points.count - 1 && path.endCap == .extend ? half : 0
            if horizontal {
                let a = first.x - direction * begin, b = second.x + direction * end
                try rectangle(.init(origin: .init(x: min(a, b), y: first.y - half),
                                    size: .init(width: abs(b - a), height: path.width)))
            } else {
                let a = first.y - direction * begin, b = second.y + direction * end
                try rectangle(.init(origin: .init(x: first.x - half, y: min(a, b)),
                                    size: .init(width: path.width, height: abs(b - a))))
            }
            previousHorizontal = horizontal; previousDirection = direction
        }
    }
}
