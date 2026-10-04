public enum LayoutPathGeometryError: Error, Equatable, Sendable {
    case invalidValue
    case degenerateSegment
    case immediateReversal
    case unsupportedCircularOutline
    case invalidRetraction
}
