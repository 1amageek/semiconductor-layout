import Foundation
import LayoutCore

/// Per-layer incremental state for the density check.
///
/// Density is the boolean-merged (union) clipped area over the window
/// area, computed by the same `mergedClippedArea` the full check uses.
/// The integer dbu-space union is canonical — independent of shape order
/// and of zero-contribution shapes — so re-deriving only the windows an
/// edit touches reproduces the full-run verdicts exactly.
struct LayerDensityState {
    /// Density windows derived from the design's overall bounding box, in
    /// the emission order of the full check.
    var windows: [LayoutRect] = []

    /// Current verdict per window index; windows without a violation hold
    /// no entry.
    var violationByWindow: [Int: LayoutViolation] = [:]
}
