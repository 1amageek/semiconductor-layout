import Foundation

public enum LayoutPinRole: String, Sendable, Codable {
    case signal
    case power
    case ground
    case gate
    case source
    case drain
    case bulk
}
