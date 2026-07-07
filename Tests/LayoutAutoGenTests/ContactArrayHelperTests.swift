import Testing
import LayoutCore
import LayoutTech
import LayoutVerify
@testable import LayoutAutoGen

@Suite("Contact array rule spacing")
struct ContactArrayHelperTests {
    @Test func oneDimensionalArrayDoesNotLoseSpacingThroughGridSnapping() {
        let contact = LayoutLayerID(name: "CONTACT", purpose: "cut")
        let shapes = ContactArrayHelper.generateContacts1D(
            regionX: 0,
            regionY: 0.005,
            regionHeight: 1.2,
            contSize: 0.22,
            contSpacing: 0.25,
            contLayer: contact,
            grid: 0.01
        )

        #expect(minimumAxisSpacing(shapes, axis: .y) >= 0.25)
    }

    @Test func twoDimensionalArrayDoesNotLoseSpacingThroughGridSnapping() {
        let contact = LayoutLayerID(name: "CONTACT", purpose: "cut")
        let shapes = ContactArrayHelper.generateContacts2D(
            regionX: 0.005,
            regionY: 0.005,
            regionWidth: 1.2,
            regionHeight: 1.2,
            contSize: 0.22,
            contSpacing: 0.25,
            contLayer: contact,
            grid: 0.01
        )

        #expect(minimumAxisSpacing(shapes, axis: .x) >= 0.25)
        #expect(minimumAxisSpacing(shapes, axis: .y) >= 0.25)
    }

    @Test func generatedMOSFETContactArraysPassContactSpacingDRC() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            parameters: ["w": 3.0, "l": 0.18],
            tech: tech
        )
        let document = LayoutDocument(name: "mos", cells: [cell], topCellID: cell.id)
        let result = LayoutDRCService().run(document: document, tech: tech)

        #expect(!result.violations.contains {
            $0.kind == .minSpacing && $0.layer == LayoutLayerID(name: "CONTACT", purpose: "cut")
        })
    }

    @Test func generatedMultiFingerMOSFETsPassSampleProcessDRC() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let generator = MOSFETCellGenerator()
        let cells = [
            try generator.generateCell(
                deviceKindID: "nmos",
                instanceName: "MN2",
                parameters: ["w": 2.0, "l": 0.18, "nf": 2.0],
                tech: tech
            ),
            try generator.generateCell(
                deviceKindID: "pmos",
                instanceName: "MP4",
                parameters: ["w": 3.0, "l": 0.25, "nf": 4.0],
                tech: tech
            )
        ]

        for cell in cells {
            let document = LayoutDocument(name: cell.name, cells: [cell], topCellID: cell.id)
            let result = LayoutDRCService().run(document: document, tech: tech)

            #expect(result.violations.isEmpty, "\(cell.name) should be DRC clean, got \(result.violations)")
        }
    }

    private enum Axis {
        case x
        case y
    }

    private func minimumAxisSpacing(_ shapes: [LayoutShape], axis: Axis) -> Double {
        let rects = shapes.compactMap { shape -> LayoutRect? in
            guard case .rect(let rect) = shape.geometry else {
                return nil
            }
            return rect
        }
        var minimum = Double.greatestFiniteMagnitude
        for lhsIndex in rects.indices {
            for rhsIndex in rects.indices where rhsIndex > lhsIndex {
                let lhs = rects[lhsIndex]
                let rhs = rects[rhsIndex]
                let spacing: Double
                switch axis {
                case .x:
                    spacing = max(rhs.origin.x - lhs.maxX, lhs.origin.x - rhs.maxX)
                case .y:
                    spacing = max(rhs.origin.y - lhs.maxY, lhs.origin.y - rhs.maxY)
                }
                if spacing >= 0 {
                    minimum = min(minimum, spacing)
                }
            }
        }
        return minimum
    }
}
