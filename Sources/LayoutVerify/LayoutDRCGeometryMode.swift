/// Geometry contract used by a DRC run.
public enum LayoutDRCGeometryMode: String, Hashable, Sendable, Codable {
    /// Interactive mode may use legacy geometry paths for exploratory feedback.
    case development
    /// Signoff mode accepts only geometry supported by the exact rectilinear kernel.
    case exactOnly
}
