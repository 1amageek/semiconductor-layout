import Foundation
import Testing
import LayoutCore

@Suite("Canonical pin direction", .timeLimit(.minutes(1)))
struct LayoutPinDirectionTests {
    @Test(arguments: [LayoutPinDirection.input, .output, .inout_, .feedthrough])
    func directionIsValueOwnedThroughJSONAndTransform(_ direction: LayoutPinDirection) throws {
        let pin = LayoutPin(name: "P", position: .init(x: 1, y: 2), size: .init(width: 0.6, height: 0.2),
            layer: .init(name: "M1", purpose: "drawing"), direction: direction)
        let decoded = try JSONDecoder().decode(LayoutPin.self, from: JSONEncoder().encode(pin))
        #expect(decoded == pin)
        #expect(decoded.transformed(by: [.init(rotationDegrees: 90, mirrorY: true)]).direction == direction)
        #expect(LayoutPin(name: "native", position: .zero, size: .init(width: 1, height: 1), layer: pin.layer).direction == nil)
    }
}
