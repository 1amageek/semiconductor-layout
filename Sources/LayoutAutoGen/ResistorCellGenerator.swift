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
        try DeviceParameterValidation.requireSupported(deviceKindID, supported: supportedDeviceKindIDs)
        let context = try makeContext(
            instanceName: instanceName,
            parameters: parameters,
            tech: tech
        )
        let base = makeBaseShapes(context)
        let contacts = makeContactShapes(context)
        let metal = makeMetalAndPins(context)

        return LayoutCell(
            name: "\(instanceName)_resistor",
            shapes: base.shapes + contacts + metal.shapes,
            labels: [
                LayoutLabel(text: instanceName, position: base.polyRect.center, layer: context.m1ID)
            ],
            pins: metal.pins
        )
    }

    private struct ResistorCellContext {
        let polyID: LayoutLayerID
        let resiID: LayoutLayerID
        let contID: LayoutLayerID
        let m1ID: LayoutLayerID
        let grid: Double
        let width: Double
        let polyLength: Double
        let contSize: Double
        let contEnc: Double
        let m1Enc: Double
        let contSpacing: Double
        let contactRegion: Double
        let cellLength: Double
        let cellHeight: Double
        let resiEnclosure: Double
        let m1Width: Double
        let m1Height: Double
    }

    private func makeContext(
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> ResistorCellContext {
        let r = try DeviceParameterValidation.requirePositive(parameters, "r", device: instanceName)
        let configuredSheetResistance = try DeviceParameterValidation.requirePositiveValue(
            sheetResistance,
            "sheetResistance",
            device: instanceName
        )
        let configuredPolyWidth = try DeviceParameterValidation.requirePositiveValue(
            polyWidth,
            "polyWidth",
            device: instanceName
        )

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
        let rawWidth = parameters["w"] ?? configuredPolyWidth
        let w = snap(
            try DeviceParameterValidation.requirePositiveValue(rawWidth, "w", device: instanceName),
            grid: grid
        )

        // Calculate poly length from resistance: R = Rsh × L / W → L = R × W / Rsh
        let squares = r / configuredSheetResistance
        let polyLength = snap(max(squares * w, w), grid: grid)
        let contSize = contDef.cutSize.width
        let contEnc = contDef.enclosure.bottom
        let m1Enc = contDef.enclosure.top
        let contSpacing = contDef.cutSpacing
        let contactRegion = contSize + 2 * contEnc
        let cellLength = snap(contactRegion + polyLength + contactRegion, grid: grid)
        let cellHeight = snap(w, grid: grid)
        let resiEnclosure = try tech.requiredEnclosureRule(outer: resiID, inner: polyID).minEnclosure
        let m1Width = max(m1Rules.minWidth, contSize + 2 * m1Enc)
        let m1Height = max(m1Rules.minWidth, contSize + 2 * m1Enc)

        return ResistorCellContext(
            polyID: polyID,
            resiID: resiID,
            contID: contID,
            m1ID: m1ID,
            grid: grid,
            width: w,
            polyLength: polyLength,
            contSize: contSize,
            contEnc: contEnc,
            m1Enc: m1Enc,
            contSpacing: contSpacing,
            contactRegion: contactRegion,
            cellLength: cellLength,
            cellHeight: cellHeight,
            resiEnclosure: resiEnclosure,
            m1Width: m1Width,
            m1Height: m1Height
        )
    }

    private func makeBaseShapes(
        _ context: ResistorCellContext
    ) -> (shapes: [LayoutShape], polyRect: LayoutRect) {
        var shapes: [LayoutShape] = []

        // 1. Poly strip spanning full length
        let polyRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: context.cellLength, height: context.cellHeight)
        )
        shapes.append(LayoutShape(layer: context.polyID, geometry: .rect(polyRect)))

        // 2. RESI (salicide block) — covers resistor body only, not contact regions
        let resiStartX = snap(context.contactRegion, grid: context.grid)
        let resiEndX = snap(context.cellLength - context.contactRegion, grid: context.grid)
        let resiRect = LayoutRect(
            origin: LayoutPoint(
                x: snap(resiStartX - context.resiEnclosure, grid: context.grid),
                y: snap(-context.resiEnclosure, grid: context.grid)
            ),
            size: LayoutSize(
                width: snap(resiEndX - resiStartX + 2 * context.resiEnclosure, grid: context.grid),
                height: snap(context.cellHeight + 2 * context.resiEnclosure, grid: context.grid)
            )
        )
        shapes.append(LayoutShape(layer: context.resiID, geometry: .rect(resiRect)))

        return (shapes, polyRect)
    }

    private func makeContactShapes(_ context: ResistorCellContext) -> [LayoutShape] {
        let leftContX = snap(context.contEnc, grid: context.grid)
        let leftContacts = ContactArrayHelper.generateContacts1D(
            regionX: leftContX,
            regionY: contactY(context),
            regionHeight: contactRegionHeight(context),
            contSize: context.contSize,
            contSpacing: context.contSpacing,
            contLayer: context.contID,
            grid: context.grid
        )

        let rightContX = snap(
            context.cellLength - context.contactRegion + context.contEnc,
            grid: context.grid
        )
        let rightContacts = ContactArrayHelper.generateContacts1D(
            regionX: rightContX,
            regionY: contactY(context),
            regionHeight: contactRegionHeight(context),
            contSize: context.contSize,
            contSpacing: context.contSpacing,
            contLayer: context.contID,
            grid: context.grid
        )

        return leftContacts + rightContacts
    }

    private func makeMetalAndPins(
        _ context: ResistorCellContext
    ) -> (shapes: [LayoutShape], pins: [LayoutPin]) {
        let leftContX = snap(context.contEnc, grid: context.grid)
        let rightContX = snap(
            context.cellLength - context.contactRegion + context.contEnc,
            grid: context.grid
        )
        let leftContY = contactY(context)
        let leftM1Rect = LayoutRect(
            origin: LayoutPoint(
                x: snap(leftContX - context.m1Enc, grid: context.grid),
                y: snap(leftContY - context.m1Enc, grid: context.grid)
            ),
            size: LayoutSize(
                width: snap(context.m1Width, grid: context.grid),
                height: snap(context.m1Height, grid: context.grid)
            )
        )

        let rightM1Rect = LayoutRect(
            origin: LayoutPoint(
                x: snap(rightContX - context.m1Enc, grid: context.grid),
                y: snap(leftContY - context.m1Enc, grid: context.grid)
            ),
            size: LayoutSize(
                width: snap(context.m1Width, grid: context.grid),
                height: snap(context.m1Height, grid: context.grid)
            )
        )

        let shapes = [
            LayoutShape(layer: context.m1ID, geometry: .rect(leftM1Rect)),
            LayoutShape(layer: context.m1ID, geometry: .rect(rightM1Rect)),
        ]
        let pins = [
            LayoutPin(
                name: "neg",
                position: leftM1Rect.center,
                size: leftM1Rect.size,
                layer: context.m1ID,
                role: .signal
            ),
            LayoutPin(
                name: "pos",
                position: rightM1Rect.center,
                size: rightM1Rect.size,
                layer: context.m1ID,
                role: .signal
            ),
        ]
        return (shapes, pins)
    }

    private func contactY(_ context: ResistorCellContext) -> Double {
        snap(max(0, (context.cellHeight - context.contSize) / 2), grid: context.grid)
    }

    private func contactRegionHeight(_ context: ResistorCellContext) -> Double {
        max(context.contSize, context.cellHeight - 2 * context.contEnc)
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        ContactArrayHelper.snap(value, grid: grid)
    }
}
