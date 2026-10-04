import Foundation
import LayoutCore
import LayoutVerify

/// Coordinate adapter for grid editing; LayoutGeometry owns the rotation.
enum LayoutEditorGridGeometry {
    static func rectangle(from start: LayoutPoint, to end: LayoutPoint,
        scale: Double, sourceID: UUID
    ) throws -> LayoutRect {
        guard scale.isFinite, scale > 0 else { throw LayoutConductorCaptureError.invalidCoordinateUnits }
        func coordinate(_ value: Double) throws -> Int32 {
            let candidate = (value * scale).rounded()
            guard let number = Int32(exactly: candidate), Double(number) / scale == value else {
                throw LayoutConductorCaptureError.invalidGridGeometry(sourceID)
            }
            return number
        }
        let x1 = try coordinate(start.x), x2 = try coordinate(end.x)
        let y1 = try coordinate(start.y), y2 = try coordinate(end.y)
        let minX = min(x1, x2), minY = min(y1, y2)
        guard let width = Int32(exactly: Int64(max(x1, x2)) - Int64(minX)),
              let height = Int32(exactly: Int64(max(y1, y2)) - Int64(minY)), width > 0, height > 0 else {
            throw LayoutConductorCaptureError.invalidGridGeometry(sourceID)
        }
        return .init(origin: .init(x: Double(minX) / scale, y: Double(minY) / scale),
            size: .init(width: Double(width) / scale, height: Double(height) / scale))
    }

    static func rotated(_ geometry: LayoutGeometry, around pivot: LayoutPoint,
        clockwise: Bool, scale: Double, sourceID: UUID
    ) throws -> LayoutGeometry {
        guard scale.isFinite, scale > 0 else { throw LayoutConductorCaptureError.invalidCoordinateUnits }
        func integer(_ value: Double) throws -> Double {
            let candidate = (value * scale).rounded()
            guard let number = Int32(exactly: candidate), Double(number) / scale == value else {
                throw LayoutConductorCaptureError.invalidGridGeometry(sourceID)
            }
            return Double(number)
        }
        func point(_ value: LayoutPoint) throws -> LayoutPoint {
            try .init(x: integer(value.x), y: integer(value.y))
        }
        // Int32 inputs, endpoint sums and the two pivot arithmetic steps are
        // bounded by 2^34, below Double's exact integer limit of 2^53.
        let integral: LayoutGeometry
        switch geometry {
        case .rect(let rect):
            integral = try .rect(.init(origin: point(rect.origin), size: .init(width: integer(rect.size.width), height: integer(rect.size.height))))
        case .polygon(let polygon): integral = try .polygon(.init(points: polygon.points.map(point)))
        case .path(let path):
            let width = try integer(path.width)
            if case .custom(let begin, let end) = path.endCap {
                _ = try integer(begin)
                _ = try integer(end)
            }
            integral = try .path(.init(points: path.points.map(point), width: width, endCap: path.endCap))
        }
        let rotated = try integral.rotated90(around: point(pivot), clockwise: clockwise)
        func output(_ value: Double) throws -> Double {
            guard let number = Int32(exactly: value) else { throw LayoutConductorCaptureError.invalidGridGeometry(sourceID) }
            return Double(number) / scale
        }
        func outputPoint(_ value: LayoutPoint) throws -> LayoutPoint { try .init(x: output(value.x), y: output(value.y)) }
        switch rotated {
        case .rect(let rect):
            _ = try outputPoint(.init(x: rect.maxX, y: rect.maxY))
            return try .rect(.init(origin: outputPoint(rect.origin), size: .init(width: output(rect.size.width), height: output(rect.size.height))))
        case .polygon(let polygon): return try .polygon(.init(points: polygon.points.map(outputPoint)))
        case .path(let path):
            return try .path(.init(points: path.points.map(outputPoint), width: output(path.width), endCap: path.endCap))
        }
    }
}
