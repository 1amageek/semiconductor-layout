/// Failure of integer stroke projection, independent of its consuming domain.
enum RectilinearPathProjectionError: Error, Equatable, Sendable {
    case invalidGridGeometry
    case unsupportedGeometry
    case cancelled
}
