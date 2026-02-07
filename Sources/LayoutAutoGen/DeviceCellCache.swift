import Foundation
import LayoutCore
import LayoutTech

public struct DeviceCellCache: Sendable {
    private var cache: [String: LayoutCell] = [:]

    public init() {}

    /// Returns a cached cell or generates a new one.
    ///
    /// Cells are cached by (deviceKindID, parameters). The `instanceName` is only
    /// used when generating a new cell — subsequent calls with the same device kind
    /// and parameters return the cached cell regardless of instance name.
    /// Instance-specific naming is handled by `LayoutInstance.name`, not the cell.
    public mutating func cellFor(
        deviceKindID: String,
        instanceName: String,
        parameters: [String: Double],
        generator: DeviceCellGenerator,
        tech: LayoutTechDatabase
    ) throws -> LayoutCell {
        let key = cacheKey(deviceKindID: deviceKindID, parameters: parameters)
        if let cached = cache[key] {
            return cached
        }
        // Use deviceKindID as canonical cell name to avoid caching
        // instance-specific names that would be misleading for reused cells.
        let canonicalName = deviceKindID
        let cell = try generator.generateCell(
            deviceKindID: deviceKindID,
            instanceName: canonicalName,
            parameters: parameters,
            tech: tech
        )
        cache[key] = cell
        return cell
    }

    private func cacheKey(deviceKindID: String, parameters: [String: Double]) -> String {
        let sortedParams = parameters.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return "\(deviceKindID):\(sortedParams)"
    }
}
