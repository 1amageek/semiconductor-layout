import LayoutCore

/// Repair candidates require successful verification of the owning generation.
public enum LayoutRepairVerificationError: Error, Sendable {
    case verificationFailed([LayoutDRCDiagnostic])
}
