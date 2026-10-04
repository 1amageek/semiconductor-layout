public enum LayoutPinDirection: String, Hashable, Sendable, Codable {
    case input
    case output
    case inout_ = "inout"
    case feedthrough
}
