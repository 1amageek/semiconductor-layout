import Foundation

/// Fill pattern for layer visualization in the layout editor.
///
/// Each semiconductor layer uses a combination of color and pattern
/// so overlapping layers remain visually distinguishable.
public enum LayoutFillPattern: String, Hashable, Sendable, Codable, CaseIterable {
    /// Solid fill (no pattern).
    case solid
    /// Forward diagonal lines (/).
    case forwardDiagonal
    /// Backward diagonal lines (\).
    case backwardDiagonal
    /// Crosshatch (X pattern).
    case crosshatch
    /// Horizontal lines.
    case horizontal
    /// Vertical lines.
    case vertical
    /// Grid (+ pattern).
    case grid
    /// Dot pattern.
    case dots
}
