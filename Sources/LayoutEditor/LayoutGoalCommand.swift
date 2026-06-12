import Foundation
import LayoutCore

/// The goal-level operations of the editor — the surface a human keymap
/// and an AI agent share. Every case maps to one deterministic, verified
/// editor operation; replaying a recorded sequence on the same document
/// reproduces the same geometry and the same verdicts.
public enum LayoutGoalCommand: Sendable, Equatable, Codable {
    /// Repair every repairable violation to a fixed point (N1).
    case fixAllViolations
    /// Complete one open net, verification-gated (N3).
    case finishNet(UUID)
    /// Complete every finishable net to a fixed point (N3).
    case finishAllNets
    /// Derive net assignments from text labels (N2).
    case annotateNetsFromLabels
    /// Place one unrealized intent device by its reference ID (N2).
    case placeIntentDevice(deviceID: String, at: LayoutPoint)
    /// Bind every placed intent instance's terminals to nets named after
    /// the LVS reference — the label-less autonomy path (C5).
    case bindIntentTerminals
    /// Select the active (routing/drawing) layer. Recorded so a replayed
    /// script carries ALL state its later commands depend on.
    case setActiveLayer(LayoutLayerID)
}
