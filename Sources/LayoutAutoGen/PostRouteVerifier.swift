import LayoutCore

/// Verification oracle invoked on the assembled document after each
/// routing pass of a repair loop.
///
/// Implementations return only violations that must be repaired; advisory
/// findings stay out so the loop neither rips up nets for warnings nor
/// reports them as unresolved. Returned IDs must reference the document's
/// shapes, vias, and nets so the loop can attribute violations to routes.
public protocol PostRouteVerifier: Sendable {
    func verify(document: LayoutDocument) throws -> [PostRouteViolation]
}
