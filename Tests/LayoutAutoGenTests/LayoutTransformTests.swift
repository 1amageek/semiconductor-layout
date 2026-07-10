import Foundation
import Testing
import LayoutCore

@Suite("Layout Transform")
struct LayoutTransformTests {

    @Test("Transform applies magnification and arbitrary rotation")
    func appliesMagnificationAndArbitraryRotation() {
        let transform = LayoutTransform(
            translation: LayoutPoint(x: 1, y: 1),
            rotationDegrees: 30,
            magnification: 2
        )

        let transformed = transform.apply(to: LayoutPoint(x: 2, y: 0))

        #expect(abs(transformed.x - 4.464101615137754) < 1e-12)
        #expect(abs(transformed.y - 3.0) < 1e-12)
    }

    @Test("Orthogonal rotation projection remains available")
    func orthogonalRotationProjectionRemainsAvailable() {
        var transform = LayoutTransform(rotationDegrees: 46)
        #expect(transform.rotation == .deg90)

        transform.rotation = .deg180
        #expect(transform.rotationDegrees == 180)
    }

    @Test("Decoding requires the exact rotation field")
    func decodingRequiresExactRotationField() throws {
        let data = Data(
            #"{"translation":{"x":0,"y":0},"rotation":"deg90","magnification":1,"mirrorX":false,"mirrorY":false}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LayoutTransform.self, from: data)
        }
    }

    @Test("Checked inverse rejects zero magnification")
    func checkedInverseRejectsZeroMagnification() {
        let transform = LayoutTransform(magnification: 0)

        #expect(throws: LayoutCoreError.nonInvertibleTransform(magnification: 0)) {
            _ = try transform.checkedInverseApply(to: .zero)
        }
    }

    @Test("Inverse apply rejects zero magnification")
    func inverseApplyRejectsZeroMagnification() {
        let transform = LayoutTransform(magnification: 0)

        #expect(throws: LayoutCoreError.nonInvertibleTransform(magnification: 0)) {
            _ = try transform.inverseApply(to: .zero)
        }
    }
}
