import Foundation

/// Containment semantics of a marquee (box) selection.
public enum LayoutMarqueeMode: Sendable, Hashable {
    /// Selects shapes whose bounding box lies entirely inside the marquee
    /// — the conventional left-to-right "window" drag.
    case window
    /// Selects shapes whose bounding box intersects the marquee — the
    /// conventional right-to-left "crossing" drag.
    case crossing
}
