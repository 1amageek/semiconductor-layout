import Foundation
import LayoutVerify

/// The live, whole-picture verdict: per axis, what is clean, what has
/// findings, what is stale, and what is NOT being verified at all.
/// "Looks clean" is never implied — absence of checking is stated.
public struct LayoutTrustReport: Sendable, Equatable {
    public enum AxisVerdict: Sendable, Equatable {
        /// Verified and clean.
        case clean
        /// Verified with this many findings.
        case findings(Int)
        /// Not being verified, with the reason (off, no reference, ...).
        case unavailable(String)
    }

    public var drc: AxisVerdict
    /// DRC kinds whose verdict is deferred (e.g. antenna until commit).
    public var staleDRCKinds: [String]
    public var connectivity: AxisVerdict
    public var constraints: AxisVerdict
    public var lvs: AxisVerdict
    public var electrical: AxisVerdict
    /// In-place gesture edits have outrun verification.
    public var verificationPending: Bool

    public var hasOpenFindings: Bool {
        func count(_ verdict: AxisVerdict) -> Int {
            if case .findings(let n) = verdict { return n }
            return 0
        }
        return count(drc) + count(connectivity) + count(constraints)
            + count(lvs) + count(electrical) > 0
    }
}
