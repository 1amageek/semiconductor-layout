import Foundation
import LayoutCore

public enum FinishNetRoutePolicy: String, Codable, Sendable, Equatable {
    case explicitSegment
    case openNetAutoRoute
}

public struct FinishNetCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let netID: UUID
    public let layer: LayoutLayerID
    public let start: LayoutPoint
    public let end: LayoutPoint
    public let width: Double
    public let firstShapeID: UUID?
    public let secondShapeID: UUID?
    public let technologyPath: String?
    public let reportPath: String?
    public let routePolicy: FinishNetRoutePolicy?
    public let properties: [String: String]

    public init(
        cellID: UUID,
        netID: UUID,
        layer: LayoutLayerID,
        start: LayoutPoint,
        end: LayoutPoint,
        width: Double,
        firstShapeID: UUID? = nil,
        secondShapeID: UUID? = nil,
        technologyPath: String? = nil,
        reportPath: String? = nil,
        routePolicy: FinishNetRoutePolicy? = nil,
        properties: [String: String] = [:]
    ) {
        self.cellID = cellID
        self.netID = netID
        self.layer = layer
        self.start = start
        self.end = end
        self.width = width
        self.firstShapeID = firstShapeID
        self.secondShapeID = secondShapeID
        self.technologyPath = technologyPath
        self.reportPath = reportPath
        self.routePolicy = routePolicy
        self.properties = properties
    }
}
