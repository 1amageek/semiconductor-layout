public struct LayoutRuleProgramNode: Hashable, Sendable, Codable {
    public let nodeID: String
    public let operation: String
    public let inputLayerIDs: [String]
    public let parameters: [String: String]

    public init(
        nodeID: String,
        operation: String,
        inputLayerIDs: [String] = [],
        parameters: [String: String] = [:]
    ) {
        self.nodeID = nodeID
        self.operation = operation
        // Operand order is semantic for asymmetric operations such as
        // difference, enclosure, and directional edge filters. Keep the
        // compiler-provided order in the canonical program.
        self.inputLayerIDs = inputLayerIDs
        self.parameters = parameters
    }
}
