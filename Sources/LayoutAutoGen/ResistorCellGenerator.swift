import Foundation
import LayoutCore
import LayoutTech

/// Generates resistor cells using poly strip with contacts at each end.
///
/// Supported devices: resistor.
/// Required parameters: `r` (resistance, ohms).
/// Optional parameters: `w` (poly width, µm; defaults to polyWidth).
///
/// Uses a fixed sheet resistance to calculate poly strip length.
/// Generated layers: POLY, RESI (salicide block), CONTACT, M1, pins (pos, neg).
public struct ResistorCellGenerator: DeviceCellGenerator {
    /// Sheet resistance in ohms/square for poly resistor.
    public var sheetResistance: Double

    /// Default width of the poly strip in µm.
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
        let resiID = LayoutLayerID(name: "RESI", purpose: "drawing")
        let contID = LayoutLayerID(name: "CONTACT", purpose: "cut")
        let m1ID   = LayoutLayerID(name: "M1", purpose: "drawing")

        guard let contDef = tech.contactDefinition(for: "CONT_POLY") else {
            throw AutoGenError.missingContactDefinition("CONT_POLY")
        }
        guard let m1Rules = tech.ruleSet(for: m1ID) else {
            throw AutoGenError.missingLayerRule("M1")
        }

        let grid = tech.grid

        // Width: use explicit parameter or default
        let w = snap(parameters["w"] ?? polyWidth, grid: grid)

        // Calculate poly length from resistance: R = Rsh × L / W → L = R × W / Rsh
        let squares = r / sheetResistance
        let polyLength = snap(max(squares * w, w), grid: grid)
        let contSize = contDef.cutSize.width
        let contEnc = contDef.enclosure.bottom
        let m1Enc = contDef.enclosure.top
        let contSpacing = contDef.cutSpacing
        let contactRegion = contSize + 2 * contEnc

        // Total cell length: contact region + poly body + contact region
        let cellLength = snap(contactRegion + polyLength + contactRegion, grid: grid)
        let cellHeight = snap(w, grid: grid)

        var shapes: [LayoutShape] = []
        var pins: [LayoutPin] = []

        // 1. Poly strip spanning full length
        let polyRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: cellLength, height: cellHeight)
        )
        shapes.append(LayoutShape(layer: polyID, geometry: .rect(polyRect)))

        // 2. RESI (salicide block) — covers resistor body only, not contact regions
        let resiEnclosure = tech.enclosureRule(outer: resiID, inner: polyID)?.minEnclosure ?? 0.10
        let resiStartX = snap(contactRegion, grid: grid)
        let resiEndX = snap(cellLength - contactRegion, grid: grid)
        let resiRect = LayoutRect(
            origin: LayoutPoint(
                x: snap(resiStartX - resiEnclosure, grid: grid),
                y: snap(-resiEnclosure, grid: grid)
            ),
            size: LayoutSize(
                width: snap(resiEndX - resiStartX + 2 * resiEnclosure, grid: grid),
                height: snap(cellHeight + 2 * resiEnclosure, grid: grid)
            )
        )
        shapes.append(LayoutShape(layer: resiID, geometry: .rect(resiRect)))

        // 3. Left contacts (neg terminal) — arrayed
        let leftContX = snap(contEnc, grid: grid)
        let leftContacts = ContactArrayHelper.generateContacts1D(
            regionX: leftContX,
            regionY: snap(max(0, (cellHeight - contSize) / 2), grid: grid),
            regionHeight: max(contSize, cellHeight - 2 * contEnc),
            contSize: contSize,
            contSpacing: contSpacing,
            contLayer: contID,
            grid: grid
        )
        shapes.append(contentsOf: leftContacts)

        // 4. Right contacts (pos terminal) — arrayed
        let rightContX = snap(cellLength - contactRegion + contEnc, grid: grid)
        let rightContacts = ContactArrayHelper.generateContacts1D(
            regionX: rightContX,
            regionY: snap(max(0, (cellHeight - contSize) / 2), grid: grid),
            regionHeight: max(contSize, cellHeight - 2 * contEnc),
            contSize: contSize,
            contSpacing: contSpacing,
            contLayer: contID,
            grid: grid
        )
        shapes.append(contentsOf: rightContacts)

        // 5. M1 pads
        let m1Width = max(m1Rules.minWidth, contSize + 2 * m1Enc)
        let m1Height = max(m1Rules.minWidth, contSize + 2 * m1Enc)
        let leftContY = snap(max(0, (cellHeight - contSize) / 2), grid: grid)

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
                y: snap(leftContY - m1Enc, grid: grid)
            ),
            size: LayoutSize(width: snap(m1Width, grid: grid), height: snap(m1Height, grid: grid))
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(rightM1Rect)))

        // 6. Pins
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

    private func snap(_ value: Double, grid: Double) -> Double {
        ContactArrayHelper.snap(value, grid: grid)
    }
}
