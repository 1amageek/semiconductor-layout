import Foundation

public struct DeviceExtractionResult: Hashable, Sendable, Codable {
    public var netlist: ComparisonNetlist
    public var issues: [DeviceExtractionIssue]
    public var summary: DeviceExtractionSummary

    public init(
        netlist: ComparisonNetlist,
        issues: [DeviceExtractionIssue] = [],
        summary: DeviceExtractionSummary? = nil
    ) {
        self.netlist = netlist
        self.issues = issues
        self.summary = summary ?? DeviceExtractionSummary(issues: issues)
    }

    private enum CodingKeys: String, CodingKey {
        case netlist
        case issues
        case summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        netlist = try container.decode(ComparisonNetlist.self, forKey: .netlist)
        issues = try container.decode([DeviceExtractionIssue].self, forKey: .issues)
        summary = try container.decode(DeviceExtractionSummary.self, forKey: .summary)
    }
}
