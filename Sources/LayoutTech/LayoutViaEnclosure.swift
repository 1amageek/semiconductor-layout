import Foundation

public struct LayoutViaEnclosure: Hashable, Sendable, Codable {
    public var top: Double
    public var bottom: Double

    public init(top: Double, bottom: Double) {
        self.top = top
        self.bottom = bottom
    }
}
