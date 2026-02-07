import Foundation
import LayoutCore
import LayoutTech

/// Generates MOSFET device cells with proper physical layers.
///
/// Supported devices: nmos, pmos (any suffix).
/// Required parameters: `w` (gate width, µm), `l` (gate length, µm).
///
/// Generated layers per device:
/// - ACTIVE: diffusion region (W × activeLength)
/// - POLY: gate crossing ACTIVE with extension beyond
/// - NIMP or PIMP: implant enclosing ACTIVE
/// - NWELL: well enclosing ACTIVE (PMOS only)
/// - CONTACT: source/drain contacts
/// - M1: metal connection bars for each terminal
/// - Pins: drain, gate, source, bulk on M1
public struct MOSFETCellGenerator: DeviceCellGenerator {
    public var supportedDeviceKindIDs: [String] {
        ["nmos", "pmos"]
    }

    public init() {}

    public func generateCell(
        deviceKindID: String,
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> LayoutCell {
        let isPMOS = deviceKindID.hasPrefix("pmos")

        guard let w = parameters["w"] else {
            throw AutoGenError.missingParameter(device: instanceName, parameter: "w")
        }
        guard let l = parameters["l"] else {
            throw AutoGenError.missingParameter(device: instanceName, parameter: "l")
        }

        // Layer IDs
        let activeID = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let polyID   = LayoutLayerID(name: "POLY", purpose: "drawing")
        let impID    = isPMOS
            ? LayoutLayerID(name: "PIMP", purpose: "drawing")
            : LayoutLayerID(name: "NIMP", purpose: "drawing")
        let contID   = LayoutLayerID(name: "CONTACT", purpose: "cut")
        let m1ID     = LayoutLayerID(name: "M1", purpose: "drawing")

        // Design rules
        guard let activeRules = tech.ruleSet(for: activeID) else {
            throw AutoGenError.missingLayerRule("ACTIVE")
        }
        guard let polyRules = tech.ruleSet(for: polyID) else {
            throw AutoGenError.missingLayerRule("POLY")
        }
        guard let contDef = tech.contactDefinition(for: "CONT_ACTIVE") else {
            throw AutoGenError.missingContactDefinition("CONT_ACTIVE")
        }
        guard let m1Rules = tech.ruleSet(for: m1ID) else {
            throw AutoGenError.missingLayerRule("M1")
        }

        let impEnclosure = tech.enclosureRule(outer: impID, inner: activeID)?.minEnclosure ?? 0.14
        let grid = tech.grid

        // Contact geometry
        let contSize = contDef.cutSize.width
        let contEnc = contDef.enclosure.bottom  // enclosure on ACTIVE side
        let m1Enc = contDef.enclosure.top        // enclosure on M1 side

        // Poly extends beyond active on each side
        let polyExtension = max(polyRules.minWidth, 0.20)

        // Active region dimensions
        // Width of active region = device W (gate width direction is vertical here)
        // Length of active region = source contact + spacing + gate L + spacing + drain contact
        let contactRegionLength = contSize + 2 * contEnc
        let sdSpacing = max(activeRules.minSpacing, contDef.cutSpacing)
        let activeLength = contactRegionLength + sdSpacing + l + sdSpacing + contactRegionLength
        let activeWidth = w

        // Snap to grid
        let activeL = snap(activeLength, grid: grid)
        let activeW = snap(activeWidth, grid: grid)

        var shapes: [LayoutShape] = []
        var pins: [LayoutPin] = []
        var labels: [LayoutLabel] = []

        // Origin: active region at (0, 0)
        let activeRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: activeL, height: activeW)
        )

        // 1. ACTIVE shape
        shapes.append(LayoutShape(
            layer: activeID,
            geometry: .rect(activeRect)
        ))

        // 2. Implant (NIMP or PIMP) enclosing ACTIVE
        let impRect = activeRect.expanded(by: impEnclosure, impEnclosure)
        shapes.append(LayoutShape(
            layer: impID,
            geometry: .rect(impRect)
        ))

        // 3. NWELL (PMOS only)
        if isPMOS {
            let nwellID = LayoutLayerID(name: "NWELL", purpose: "drawing")
            let nwellEnc = tech.enclosureRule(outer: nwellID, inner: activeID)?.minEnclosure ?? 0.18
            let nwellRect = activeRect.expanded(by: nwellEnc, nwellEnc)
            shapes.append(LayoutShape(
                layer: nwellID,
                geometry: .rect(nwellRect)
            ))
        }

        // 4. POLY gate
        let polyX = snap(contactRegionLength + sdSpacing, grid: grid)
        let polyRect = LayoutRect(
            origin: LayoutPoint(x: polyX, y: -polyExtension),
            size: LayoutSize(width: snap(l, grid: grid), height: activeW + 2 * polyExtension)
        )
        shapes.append(LayoutShape(
            layer: polyID,
            geometry: .rect(polyRect)
        ))

        // 5. Source contacts (left side of active)
        let sourceContX = snap(contEnc, grid: grid)
        let sourceContacts = generateContacts(
            regionX: sourceContX,
            regionWidth: contSize,
            regionY: snap(contEnc, grid: grid),
            regionHeight: activeW - 2 * contEnc,
            contSize: contSize,
            contSpacing: contDef.cutSpacing,
            contLayer: contID,
            grid: grid
        )
        shapes.append(contentsOf: sourceContacts)

        // 6. Drain contacts (right side of active)
        let drainContX = snap(activeL - contactRegionLength + contEnc, grid: grid)
        let drainContacts = generateContacts(
            regionX: drainContX,
            regionWidth: contSize,
            regionY: snap(contEnc, grid: grid),
            regionHeight: activeW - 2 * contEnc,
            contSize: contSize,
            contSpacing: contDef.cutSpacing,
            contLayer: contID,
            grid: grid
        )
        shapes.append(contentsOf: drainContacts)

        // 7. M1 bars for source and drain
        let m1Width = max(m1Rules.minWidth, contSize + 2 * m1Enc)
        let sourceM1Rect = LayoutRect(
            origin: LayoutPoint(x: snap(sourceContX - m1Enc, grid: grid), y: 0),
            size: LayoutSize(width: snap(m1Width, grid: grid), height: activeW)
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(sourceM1Rect)))

        let drainM1Rect = LayoutRect(
            origin: LayoutPoint(x: snap(drainContX - m1Enc, grid: grid), y: 0),
            size: LayoutSize(width: snap(m1Width, grid: grid), height: activeW)
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(drainM1Rect)))

        // 8. Gate M1 connection (above active, on poly)
        let gateContY = snap(activeW + polyExtension * 0.3, grid: grid)
        let gateM1Rect = LayoutRect(
            origin: LayoutPoint(x: polyRect.origin.x, y: gateContY),
            size: LayoutSize(width: polyRect.size.width, height: snap(m1Width, grid: grid))
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(gateM1Rect)))

        // Gate contact (poly to M1)
        if let polyContDef = tech.contactDefinition(for: "CONT_POLY") {
            let gateContRect = LayoutRect(
                origin: LayoutPoint(
                    x: snap(polyRect.origin.x + (polyRect.size.width - polyContDef.cutSize.width) / 2, grid: grid),
                    y: snap(gateContY + (m1Width - polyContDef.cutSize.height) / 2, grid: grid)
                ),
                size: polyContDef.cutSize
            )
            shapes.append(LayoutShape(layer: contID, geometry: .rect(gateContRect)))
        }

        // 9. Pins
        let sourcePinPos = LayoutPoint(
            x: sourceM1Rect.center.x,
            y: sourceM1Rect.center.y
        )
        pins.append(LayoutPin(
            name: "source",
            position: sourcePinPos,
            size: LayoutSize(width: m1Width, height: activeW),
            layer: m1ID,
            role: .source
        ))

        let drainPinPos = LayoutPoint(
            x: drainM1Rect.center.x,
            y: drainM1Rect.center.y
        )
        pins.append(LayoutPin(
            name: "drain",
            position: drainPinPos,
            size: LayoutSize(width: m1Width, height: activeW),
            layer: m1ID,
            role: .drain
        ))

        let gatePinPos = LayoutPoint(
            x: gateM1Rect.center.x,
            y: gateM1Rect.center.y
        )
        pins.append(LayoutPin(
            name: "gate",
            position: gatePinPos,
            size: gateM1Rect.size,
            layer: m1ID,
            role: .gate
        ))

        // Bulk pin at bottom center — with M1 pad and contact
        let bulkX = snap(activeRect.center.x - m1Width / 2, grid: grid)
        let bulkY = snap(impRect.minY - m1Width, grid: grid)
        let bulkM1Rect = LayoutRect(
            origin: LayoutPoint(x: bulkX, y: bulkY),
            size: LayoutSize(width: snap(m1Width, grid: grid), height: snap(m1Width, grid: grid))
        )
        shapes.append(LayoutShape(layer: m1ID, geometry: .rect(bulkM1Rect)))

        let bulkPinPos = bulkM1Rect.center
        pins.append(LayoutPin(
            name: "bulk",
            position: bulkPinPos,
            size: bulkM1Rect.size,
            layer: m1ID,
            role: .bulk
        ))

        // 10. Labels
        labels.append(LayoutLabel(
            text: instanceName,
            position: activeRect.center,
            layer: m1ID
        ))

        return LayoutCell(
            name: "\(instanceName)_\(deviceKindID)",
            shapes: shapes,
            labels: labels,
            pins: pins
        )
    }

    // MARK: - Helpers

    private func generateContacts(
        regionX: Double,
        regionWidth: Double,
        regionY: Double,
        regionHeight: Double,
        contSize: Double,
        contSpacing: Double,
        contLayer: LayoutLayerID,
        grid: Double
    ) -> [LayoutShape] {
        var contacts: [LayoutShape] = []
        let pitch = contSize + contSpacing
        let count = max(1, Int(floor((regionHeight + contSpacing) / pitch)))
        let totalHeight = Double(count) * contSize + Double(count - 1) * contSpacing
        let startY = regionY + (regionHeight - totalHeight) / 2

        for i in 0..<count {
            let y = snap(startY + Double(i) * pitch, grid: grid)
            let rect = LayoutRect(
                origin: LayoutPoint(x: regionX, y: y),
                size: LayoutSize(width: contSize, height: contSize)
            )
            contacts.append(LayoutShape(layer: contLayer, geometry: .rect(rect)))
        }
        return contacts
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }
}
