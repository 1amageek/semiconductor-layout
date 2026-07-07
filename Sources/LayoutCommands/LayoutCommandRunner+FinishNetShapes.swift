import Foundation
import LayoutCore

extension LayoutCommandRunner {
    func finishNetShapes(_ payload: FinishNetCommand) throws -> [LayoutShape] {
        guard let firstShapeID = payload.firstShapeID else {
            throw LayoutCommandError.missingRequiredArgument("finishNet.firstShapeID")
        }
        let corner = LayoutPoint(x: payload.end.x, y: payload.start.y)
        var shapes: [LayoutShape] = []
        if let horizontal = routeSegmentShape(
            id: firstShapeID,
            from: payload.start,
            to: corner,
            payload: payload
        ) {
            shapes.append(horizontal)
        }
        if let vertical = routeSegmentShape(
            id: payload.secondShapeID ?? firstShapeID,
            from: corner,
            to: payload.end,
            payload: payload
        ) {
            if payload.secondShapeID == nil && !shapes.isEmpty {
                throw LayoutCommandError.missingRouteShapeID("vertical")
            }
            shapes.append(vertical)
        }
        guard !shapes.isEmpty else {
            throw LayoutCommandError.invalidShapeGeometry(kind: "route")
        }
        return shapes
    }

    private func routeSegmentShape(
        id: UUID,
        from start: LayoutPoint,
        to end: LayoutPoint,
        payload: FinishNetCommand
    ) -> LayoutShape? {
        if abs(start.x - end.x) < 1e-12 && abs(start.y - end.y) < 1e-12 {
            return nil
        }
        let width = payload.width
        let rect: LayoutRect
        if abs(start.y - end.y) <= abs(start.x - end.x) {
            let minX = min(start.x, end.x)
            rect = LayoutRect(
                origin: LayoutPoint(x: minX - width / 2, y: start.y - width / 2),
                size: LayoutSize(width: abs(start.x - end.x) + width, height: width)
            )
        } else {
            let minY = min(start.y, end.y)
            rect = LayoutRect(
                origin: LayoutPoint(x: start.x - width / 2, y: minY - width / 2),
                size: LayoutSize(width: width, height: abs(start.y - end.y) + width)
            )
        }
        return LayoutShape(
            id: id,
            layer: payload.layer,
            netID: payload.netID,
            geometry: .rect(rect),
            properties: payload.properties
        )
    }
}
