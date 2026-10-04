import Foundation
import LayoutCore
import LayoutIR

extension LayoutConnectivityExtractor {
    /// Converts the admitted centered source rectangle before deriving bounds.
    /// Integer transforms preserve the source lattice without cancellation at zero.
    static func integerPinPolygon(_ pin: LayoutPin, transforms: [LayoutTransform],
        databaseUnitsPerMicrometer dbu: Double, isCancelled: () -> Bool
    ) throws -> [IRPoint] {
        func failure() -> LayoutConductorCaptureError { .invalidGridGeometry(pin.id) }
        func integer(_ scaled: Double) throws -> Int64 {
            let rounded = scaled.rounded()
            guard scaled.isFinite, abs(scaled - rounded) <= scaled.ulp * 4,
                  let value = Int64(exactly: rounded) else { throw failure() }
            return value
        }
        func add(_ first: Int64, _ second: Int64) throws -> Int64 {
            let (value, overflow) = first.addingReportingOverflow(second)
            guard !overflow else { throw failure() }; return value
        }
        func negate(_ value: Int64) throws -> Int64 {
            guard value != .min else { throw failure() }; return -value
        }
        let x = try integer(pin.position.x * dbu), y = try integer(pin.position.y * dbu)
        let width = try integer(pin.size.width * dbu), height = try integer(pin.size.height * dbu)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else { throw failure() }
        let left = try add(x, -width / 2), right = try add(x, width / 2)
        let bottom = try add(y, -height / 2), top = try add(y, height / 2)
        var points: [IRPoint] = []
        for (initialX, initialY) in [(left, bottom), (right, bottom), (right, top), (left, top)] {
            if isCancelled() { throw LayoutConductorCaptureError.cancelled }
            var px = initialX, py = initialY
            for transform in transforms.reversed() {
                if isCancelled() { throw LayoutConductorCaptureError.cancelled }
                if transform.mirrorX { px = try negate(px) }
                if transform.mirrorY { py = try negate(py) }
                guard let exactX = Double(exactly: px), let exactY = Double(exactly: py) else { throw failure() }
                px = try integer(exactX * transform.magnification)
                py = try integer(exactY * transform.magnification)
                switch transform.rotationDegrees.truncatingRemainder(dividingBy: 360) {
                case 0: break
                case 90, -270: (px, py) = (try negate(py), px)
                case 180, -180: (px, py) = (try negate(px), try negate(py))
                case 270, -90: (px, py) = (py, try negate(px))
                default: throw LayoutConductorCaptureError.unsupportedGeometry(pin.id)
                }
                px = try add(px, integer(transform.translation.x * dbu))
                py = try add(py, integer(transform.translation.y * dbu))
            }
            guard let ix = Int32(exactly: px), let iy = Int32(exactly: py) else { throw failure() }
            points.append(IRPoint(x: ix, y: iy))
        }
        return points
    }
}
