public struct LayoutExtractionTerminal: Sendable, Hashable, Codable {
    public let index: Int
    public let role: String?
    public let netID: LayoutExtractionObjectID

    public init(index: Int, role: String? = nil, netID: LayoutExtractionObjectID) {
        self.index = index
        self.role = role
        self.netID = netID
    }
}
