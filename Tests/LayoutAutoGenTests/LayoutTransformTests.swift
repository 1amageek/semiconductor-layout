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

    @Test("Legacy orthogonal rotation remains available")
    func legacyOrthogonalRotationRemainsAvailable() {
        var transform = LayoutTransform(rotationDegrees: 46)
        #expect(transform.rotation == .deg90)

        transform.rotation = .deg180
        #expect(transform.rotationDegrees == 180)
    }
}
