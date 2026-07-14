public struct LayoutExtractionTransformRecord: Sendable, Hashable, Codable {
    public let transformID: String
    public let kind: String
    public let policyID: String?
    public let inputObjectIDs: [LayoutExtractionObjectID]
    public let outputObjectIDs: [LayoutExtractionObjectID]
    public let digest: String

    public init(
        transformID: String,
        kind: String,
        policyID: String? = nil,
        inputObjectIDs: [LayoutExtractionObjectID],
        outputObjectIDs: [LayoutExtractionObjectID],
        digest: String
    ) {
        self.transformID = transformID
        self.kind = kind
        self.policyID = policyID
        self.inputObjectIDs = inputObjectIDs.sorted()
        self.outputObjectIDs = outputObjectIDs.sorted()
        self.digest = digest
    }
}
