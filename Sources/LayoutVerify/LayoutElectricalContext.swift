/// The owner whose preparation defines electrical conductor geometry.
public enum LayoutElectricalContext: String, Sendable, Equatable, Hashable, Codable {
    /// All selected non-cut source geometry conducts without MOS recognition.
    case geometric
    /// DeviceExtractor owns ACTIVE/POLY channel separation and material selection.
    case deviceAwareMOS
}
