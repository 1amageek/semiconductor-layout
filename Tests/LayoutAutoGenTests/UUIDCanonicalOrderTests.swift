import Foundation
import Testing
@testable import LayoutVerify

/// The verdict types document their ID ordering as `uuidString` order;
/// the hot paths implement it with allocation-free byte comparison. This
/// property test pins the two orders to each other so the bit-exact
/// live-equals-batch contract cannot silently drift.
@Suite("UUID canonical order")
struct UUIDCanonicalOrderTests {

    @Test func byteOrderMatchesUUIDStringOrderOnRandomPairs() {
        var generator = SplitMix64(seed: 0x5EED_C0DE_2026_0004)
        for _ in 0..<10_000 {
            let a = UUID(uuid: randomUUIDBytes(&generator))
            let b = UUID(uuid: randomUUIDBytes(&generator))
            #expect(
                a.isCanonicallyOrderedBefore(b) == (a.uuidString < b.uuidString),
                "byte order must reproduce uuidString order for \(a) vs \(b)"
            )
        }
    }

    @Test func equalUUIDsAreNotOrderedBeforeEachOther() {
        let id = UUID()
        #expect(!id.isCanonicallyOrderedBefore(id))
    }

    @Test func singleByteDifferencesOrderInBothDirections() {
        // Walk every byte position with values that straddle the hex
        // digit/letter boundary ('9' < 'A' must hold as 0x09 < 0x0A).
        let base: [UInt8] = Array(repeating: 0x99, count: 16)
        for position in 0..<16 {
            for (low, high) in [(UInt8(0x09), UInt8(0x0A)), (0x00, 0xFF), (0x9F, 0xA0)] {
                var lowBytes = base
                var highBytes = base
                lowBytes[position] = low
                highBytes[position] = high
                let a = UUID(uuid: uuidTuple(lowBytes))
                let b = UUID(uuid: uuidTuple(highBytes))
                #expect(a.isCanonicallyOrderedBefore(b) && !b.isCanonicallyOrderedBefore(a))
                #expect(a.uuidString < b.uuidString, "fixture must agree with string order")
            }
        }
    }

    private func randomUUIDBytes(_ generator: inout SplitMix64) -> uuid_t {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return uuidTuple(bytes)
    }

    private func uuidTuple(_ bytes: [UInt8]) -> uuid_t {
        precondition(bytes.count == 16)
        return (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }
}
