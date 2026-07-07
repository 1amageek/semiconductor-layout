public struct LayoutActionDomainSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let domainID: String
    public let ownerPackages: [String]
    public let operations: [LayoutActionDomainOperation]

    public init(
        schemaVersion: Int = 1,
        domainID: String,
        ownerPackages: [String],
        operations: [LayoutActionDomainOperation]
    ) {
        self.schemaVersion = schemaVersion
        self.domainID = domainID
        self.ownerPackages = ownerPackages
        self.operations = operations
    }
}

