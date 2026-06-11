import Foundation
import LayoutCore

/// Per-layer incremental state for the density check.
///
/// The full check sums per-shape clipped areas in document order with a
/// `reduce(0.0, +)`. Adding `+0.0` leaves any IEEE double unchanged and
/// every clipped area is non-negative, so caching each occurrence's clipped
/// area per window (omitting zero contributions) and re-summing the cached
/// terms over the full layer shape list in document order reproduces the
/// full-run double bit-exactly. An edit therefore only re-clips the edited
/// shapes against the touched windows and re-runs the cheap summation.
struct LayerDensityState {
    /// Density windows derived from the design's overall bounding box, in
    /// the emission order of the full check.
    var windows: [LayoutRect] = []

    /// Per-window cache of each occurrence's clipped area. Occurrences
    /// contributing zero area may be absent: a missing entry sums as
    /// `+0.0`, which is the identity.
    var clippedAreaByWindow: [[FlatShapeKey: Double]] = []

    /// Current verdict per window index; windows without a violation hold
    /// no entry.
    var violationByWindow: [Int: LayoutViolation] = [:]
}
