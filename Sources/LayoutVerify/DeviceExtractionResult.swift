import Foundation

public struct DeviceExtractionResult: Hashable, Sendable, Codable {
    public var netlist: ComparisonNetlist
    public var issues: [DeviceExtractionIssue]

    public init(netlist: ComparisonNetlist, issues: [DeviceExtractionIssue] = []) {
        self.netlist = netlist
        self.issues = issues
    }
}
