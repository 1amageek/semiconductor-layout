import Foundation

public enum LayoutIOError: Error, Sendable {
    case fileNotFound(String)
    case readFailed(String)
    case writeFailed(String)
    case unsupportedFormat(LayoutFileFormat)
    case conversionFailed(String)
}

extension LayoutIOError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "File not found: \(path)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        case .unsupportedFormat(let format): return "Unsupported format: \(format.rawValue)"
        case .conversionFailed(let msg): return "Conversion failed: \(msg)"
        }
    }
}
