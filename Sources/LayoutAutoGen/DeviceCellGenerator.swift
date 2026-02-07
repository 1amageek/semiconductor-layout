import Foundation
import LayoutCore
import LayoutTech

public protocol DeviceCellGenerator: Sendable {
    var supportedDeviceKindIDs: [String] { get }

    func generateCell(
        deviceKindID: String,
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> LayoutCell
}
