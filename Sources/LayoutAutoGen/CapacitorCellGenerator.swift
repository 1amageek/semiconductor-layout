import Foundation
import LayoutCore
import LayoutTech

/// Generates MOS capacitor cells (ACTIVE + POLY overlap).
///
/// Supported devices: capacitor.
/// Required parameters: `c` (capacitance, farads).
///
/// Uses oxide capacitance density to calculate required area.
/// Generated layers: ACTIVE, NWELL, NIMP, POLY, CONTACT, M1, pins (pos, neg).
public struct CapacitorCellGenerator: DeviceCellGenerator {
    /// Oxide capacitance density in F/µm².
    public var oxideCapDensity: Double

    public var supportedDeviceKindIDs: [String] {
        ["capacitor"]
    }

    public init(oxideCapDensity: Double = 8.6e-15) {
        self.oxideCapDensity = oxideCapDensity
    }

    public func generateCell(
        deviceKindID: String,
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> LayoutCell {
        guard let c = parameters["c"] else {
            throw AutoGenError.missingParameter(device: instanceName, parameter: "c")
        }

        let activeID = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let polyID   = LayoutLayerID(name: "POLY", purpose: "drawing")
        let contID   = LayoutLayerID(name: "CONTACT", purpose: "cut")
        let m1ID     = LayoutLayerID(name: "M1", purpose: "drawing")
        let nimpID   = LayoutLayerID(name: "NIMP", purpose: "drawing")
        let nwellID  = LayoutLayerID(name: "NWELL", purpose: "drawing")

        guard let contActiveDef = tech.contactDefinition(for: "CONT_ACTIVE") else {
            throw AutoGenError.missingContactDefinition("CONT_ACTIVE")
        }
        guard let contPolyDef = tech.contactDefinition(for: "CONT_POLY") else {
            throw AutoGenError.missingContactDefinition("CONT_POLY")
        }
        guard let m1Rules = tech.ruleSet(for: m1ID) else {
            throw AutoGenError.missingLayerRule("M1")
        }

        let grid = tech.grid
        let impEnclosure = try tech.requiredEnclosureRule(outer: nimpID, inner: activeID).minEnclosure
        let nwellEnclosure = try tech.requiredEnclosureRule(outer: nwellID, inner: activeID).minEnclosure

        // Calculate overlap area: C = Cox × A → A = C / Cox
        let areaUm2 = c / oxideCapDensity
        let side = snap(max(sqrt(areaUm2), 0.50), grid: grid)

        // Active-side contact geometry (CONT_ACTIVE)
        let actContSize = contActiveDef.cutSize.width
        let actContEnc = contActiveDef.enclosure.bottom
        let actM1Enc = contActiveDef.enclosure.top
        let actContSpacing = contActiveDef.cutSpacing
        let activeContactRegion = actContSize + 2 * actContEnc

        // Poly-side contact geometry (CONT_POLY)
        let polyContSize = contPolyDef.cutSize.width
        let polyContEnc = contPolyDef.enclosure.bottom
        let polyM1Enc = contPolyDef.enclosure.top
        let polyContSpacing = contPolyDef.cutSpacing
        let polyContactRegion = polyContSize + 2 * polyContEnc

        // Layout: [active contact region] [overlap region] [poly contact region]
        let overlapSize = side
        let cellWidth = snap(activeContactRegion + overlapSize + polyContactRegion, grid: grid)
        let cellHeight = snap(overlapSize, grid: grid)

        var shapes: [LayoutShape] = []
        var pins: [LayoutPin] = []

        // 1. ACTIVE region (left part: active contact + overlap)
        let activeRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: snap(activeContactRegion + overlapSize, grid: grid), height: cellHeight)
        )
        shapes.append(LayoutShape(layer: activeID, geometry: .rect(activeRect)))

        // 2. N-Implant enclosing ACTIVE
        let impRect = activeRect.expanded(by: impEnclosure, impEnclosure)
        shapes.append(LayoutShape(layer: nimpID, geometry: .rect(impRect)))

        // 3. NWELL enclosing ACTIVE (for accumulation-mode MOS capacitor)
        let nwellRect = activeRect.expanded(by: nwellEnclosure, nwellEnclosure)
        shapes.append(LayoutShape(layer: nwellID, geometry: .rect(nwellRect)))

        // 4. POLY region (overlap + poly contact)
        let polyX = snap(activeContactRegion, grid: grid)
        let polyRect = LayoutRect(
            origin: LayoutPoint(x: polyX, y: 0),
            size: LayoutSize(width: snap(overlapSize + polyContactRegion, grid: grid), height: cellHeight)
        )
        shapes.append(LayoutShape(layer: polyID, geometry: .rect(polyRect)))

        // 5. Active contacts (left, neg terminal - bottom plate) — arrayed
        let actContX = snap(actContEnc, grid: grid)
        let actContacts = ContactArrayHelper.generateContacts1D(
            regionX: actContX,
            regionY: snap(actContEnc, grid: grid),
            regionHeight: max(actContSize, cellHeight - 2 * actContEnc),
            contSize: actContSize,
            contSpacing: actContSpacing,
            contLayer: contID,
            grid: grid
        )
        shapes.append(contentsOf: actContacts)

        // 6. Poly contacts (right, pos terminal - top plate) — arrayed
        let polyContX = snap(cellWidth - polyContactRegion + polyContEnc, grid: grid)
        let polyContacts = ContactArrayHelper.generateContacts1D(
            regionX: polyContX,
            regionY: snap(polyContEnc, grid: grid),
            regionHeight: max(polyContSize, cellHeight - 2 * polyContEnc),
            contSize: polyContSize,
            contSpacing: polyContSpacing,
            contLayer: contID,
            grid: grid
        )
        shapes.append(contentsOf: polyContacts)

        // 7. M1 pads (sized to each contact's M1 enclosure)
        let negM1Width = max(m1Rules.minWidth, actContSize + 2 * actM1Enc)
        let negM1Height = max(m1Rules.minWidth, actContSize + 2 * actM1Enc)
        let actContY = snap(actContEnc, grid: grid)

        let negM1 = LayoutRect(
            origin: LayoutPoint(
                x: snap(actContX - actM1Enc, grid: grid),
                y: snap(actContY - actM1Enc, grid: grid)
            ),
            size: LayoutSize(width: snap(negM1Width, grid: grid), height: snap(negM1Height, grid: grid))
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(negM1)))

        let posM1Width = max(m1Rules.minWidth, polyContSize + 2 * polyM1Enc)
        let posM1Height = max(m1Rules.minWidth, polyContSize + 2 * polyM1Enc)
        let polyContY = snap(polyContEnc, grid: grid)

        let posM1 = LayoutRect(
            origin: LayoutPoint(
                x: snap(polyContX - polyM1Enc, grid: grid),
                y: snap(polyContY - polyM1Enc, grid: grid)
            ),
            size: LayoutSize(width: snap(posM1Width, grid: grid), height: snap(posM1Height, grid: grid))
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(posM1)))

        // 8. Pins
        pins.append(LayoutPin(
            name: "neg",
            position: negM1.center,
            size: negM1.size,
            layer: m1ID,
            role: .signal
        ))
        pins.append(LayoutPin(
            name: "pos",
            position: posM1.center,
            size: posM1.size,
            layer: m1ID,
            role: .signal
        ))

        return LayoutCell(
            name: "\(instanceName)_capacitor",
            shapes: shapes,
            labels: [
                LayoutLabel(text: instanceName, position: activeRect.center, layer: m1ID)
            ],
            pins: pins
        )
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        ContactArrayHelper.snap(value, grid: grid)
    }
}
