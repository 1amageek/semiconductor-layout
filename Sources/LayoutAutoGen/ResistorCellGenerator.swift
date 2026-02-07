import Foundation
import LayoutCore
import LayoutTech

/// Generates resistor cells using poly strip with contacts at each end.
///
/// Supported devices: resistor.
/// Required parameters: `r` (resistance, ohms).
///
/// Uses a fixed sheet resistance to calculate poly strip length.
/// Generated layers: POLY, CONTACT, M1, pins (pos, neg).
public struct ResistorCellGenerator: DeviceCellGenerator {
    /// Sheet resistance in ohms/square for poly resistor.
    public var sheetResistance: Double

    /// Width of the poly strip in µm.
    public var polyWidth: Double

    public var supportedDeviceKindIDs: [String] {
        ["resistor"]
    }

    public init(sheetResistance: Double = 200.0, polyWidth: Double = 0.40) {
        self.sheetResistance = sheetResistance
        self.polyWidth = polyWidth
    }

    public func generateCell(
        deviceKindID: String,
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> LayoutCell {
        guard let r = parameters["r"] else {
            throw AutoGenError.missingParameter(device: instanceName, parameter: "r")
        }

        let polyID = LayoutLayerID(name: "POLY", purpose: "drawing")
        let contID = LayoutLayerID(name: "CONTACT", purpose: "cut")
        let m1ID   = LayoutLayerID(name: "M1", purpose: "drawing")

        guard let contDef = tech.contactDefinition(for: "CONT_POLY") else {
            throw AutoGenError.missingContactDefinition("CONT_POLY")
        }
        guard let m1Rules = tech.ruleSet(for: m1ID) else {
            throw AutoGenError.missingLayerRule("M1")
        }

        let grid = tech.grid

        // Calculate poly length from resistance: R = Rsh × L / W → L = R × W / Rsh
        let squares = r / sheetResistance
        let polyLength = snap(max(squares * polyWidth, polyWidth), grid: grid)
        let contSize = contDef.cutSize.width
        let contEnc = contDef.enclosure.bottom
        let m1Enc = contDef.enclosure.top
        let contactRegion = contSize + 2 * contEnc

        // Total cell length: contact region + poly body + contact region
        let cellLength = snap(contactRegion + polyLength + contactRegion, grid: grid)
        let cellHeight = snap(polyWidth, grid: grid)

        var shapes: [LayoutShape] = []
        var pins: [LayoutPin] = []

        // 1. Poly strip spanning full length
        let polyRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: cellLength, height: cellHeight)
        )
        shapes.append(LayoutShape(layer: polyID, geometry: .rect(polyRect)))

        // 2. Left contact (neg terminal)
        let leftContX = snap(contEnc, grid: grid)
        let leftContY = snap((cellHeight - contSize) / 2, grid: grid)
        let leftContRect = LayoutRect(
            origin: LayoutPoint(x: leftContX, y: leftContY),
            size: contDef.cutSize
        )
        shapes.append(LayoutShape(layer: contID, geometry: .rect(leftContRect)))

        // 3. Right contact (pos terminal)
        let rightContX = snap(cellLength - contactRegion + contEnc, grid: grid)
        let rightContRect = LayoutRect(
            origin: LayoutPoint(x: rightContX, y: leftContY),
            size: contDef.cutSize
        )
        shapes.append(LayoutShape(layer: contID, geometry: .rect(rightContRect)))

        // 4. M1 pads
        let m1Width = max(m1Rules.minWidth, contSize + 2 * m1Enc)
        let m1Height = max(m1Rules.minWidth, contSize + 2 * m1Enc)

        let leftM1Rect = LayoutRect(
            origin: LayoutPoint(
                x: snap(leftContX - m1Enc, grid: grid),
                y: snap(leftContY - m1Enc, grid: grid)
            ),
            size: LayoutSize(width: snap(m1Width, grid: grid), height: snap(m1Height, grid: grid))
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(leftM1Rect)))

        let rightM1Rect = LayoutRect(
            origin: LayoutPoint(
                x: snap(rightContX - m1Enc, grid: grid),
                y: snap(rightContY(leftContY, m1Enc: m1Enc), grid: grid)
            ),
            size: LayoutSize(width: snap(m1Width, grid: grid), height: snap(m1Height, grid: grid))
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(rightM1Rect)))

        // 5. Pins
        pins.append(LayoutPin(
            name: "neg",
            position: leftM1Rect.center,
            size: leftM1Rect.size,
            layer: m1ID,
            role: .signal
        ))

        pins.append(LayoutPin(
            name: "pos",
            position: rightM1Rect.center,
            size: rightM1Rect.size,
            layer: m1ID,
            role: .signal
        ))

        return LayoutCell(
            name: "\(instanceName)_resistor",
            shapes: shapes,
            labels: [
                LayoutLabel(text: instanceName, position: polyRect.center, layer: m1ID)
            ],
            pins: pins
        )
    }

    private func rightContY(_ leftContY: Double, m1Enc: Double) -> Double {
        leftContY - m1Enc
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }
}
