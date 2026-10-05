import Foundation

public enum LayoutIOError: Error, Sendable {
    case fileNotFound(String)
    case readFailed(String)
    case writeFailed(String)
    case unsupportedFormat(LayoutFileFormat)
    case conversionFailed(String)
    case incompatibleStandardCellMask(String)
    case unsupportedStandardCellMask(String)
    case missingStandardCellLibrary
    case unresolvedCellMaster(String)
    case unresolvedTerminal(component: String, pin: String)
    case unsupportedSourcePin(String)
}

extension LayoutIOError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "File not found: \(path)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        case .unsupportedFormat(let format): return "Unsupported format: \(format.rawValue)"
        case .conversionFailed(let msg): return "Conversion failed: \(msg)"
        case .unsupportedStandardCellMask(let reason): return "Unsupported retained standard-cell mask: \(reason)"
        case .incompatibleStandardCellMask(let reason): return "Incompatible retained standard-cell mask: \(reason)"
        case .missingStandardCellLibrary: return "DEF components require a retained standard-cell LEF library."
        case .unresolvedCellMaster(let name): return "Missing or ambiguous standard-cell master: \(name)"
        case .unresolvedTerminal(let component, let pin): return "Unresolved source terminal: \(component):\(pin)"
        case .unsupportedSourcePin(let reason): return "Unsupported source pin: \(reason)"
        }
    }
}
