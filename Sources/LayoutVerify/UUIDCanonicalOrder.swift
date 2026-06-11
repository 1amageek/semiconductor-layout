import Foundation

extension UUID {
    /// Allocation-free equivalent of `lhs.uuidString < rhs.uuidString`.
    ///
    /// The canonical UUID string is the 16 raw bytes rendered as uppercase
    /// hex in byte order with dashes at fixed positions. Uppercase hex
    /// digits are ASCII-monotonic in nibble value and the dashes can never
    /// be a first point of difference, so lexicographic byte comparison
    /// reproduces the string order exactly — the verdict types stay
    /// bit-identical while sorting stops allocating two strings per
    /// comparison on the hot assembly paths.
    func isCanonicallyOrderedBefore(_ other: UUID) -> Bool {
        let a = self.uuid
        let b = other.uuid
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        if a.2 != b.2 { return a.2 < b.2 }
        if a.3 != b.3 { return a.3 < b.3 }
        if a.4 != b.4 { return a.4 < b.4 }
        if a.5 != b.5 { return a.5 < b.5 }
        if a.6 != b.6 { return a.6 < b.6 }
        if a.7 != b.7 { return a.7 < b.7 }
        if a.8 != b.8 { return a.8 < b.8 }
        if a.9 != b.9 { return a.9 < b.9 }
        if a.10 != b.10 { return a.10 < b.10 }
        if a.11 != b.11 { return a.11 < b.11 }
        if a.12 != b.12 { return a.12 < b.12 }
        if a.13 != b.13 { return a.13 < b.13 }
        if a.14 != b.14 { return a.14 < b.14 }
        return a.15 < b.15
    }
}
