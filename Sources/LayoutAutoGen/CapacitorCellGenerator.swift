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
        try DeviceParameterValidation.requireSupported(deviceKindID, supported: supportedDeviceKindIDs)
        let context = try makeContext(
            instanceName: instanceName,
            parameters: parameters,
            tech: tech
        )
        let deviceShapes = makeDeviceShapes(context)
        let contacts = makeContactShapes(context)
        let metal = makeMetalAndPins(context)

        return LayoutCell(
            name: "\(instanceName)_capacitor",
            shapes: deviceShapes.shapes + contacts + metal.shapes,
            labels: [
                LayoutLabel(text: instanceName, position: deviceShapes.activeRect.center, layer: context.m1ID)
            ],
            pins: metal.pins
        )
    }

    private struct CapacitorCellContext {
        let activeID: LayoutLayerID
        let polyID: LayoutLayerID
        let contID: LayoutLayerID
        let m1ID: LayoutLayerID
        let nimpID: LayoutLayerID
        let nwellID: LayoutLayerID
        let grid: Double
        let overlapSize: Double
        let cellWidth: Double
        let cellHeight: Double
        let activeContactRegion: Double
        let polyContactRegion: Double
        let actContSize: Double
        let actContEnc: Double
        let actM1Enc: Double
        let actContSpacing: Double
        let polyContSize: Double
        let polyContEnc: Double
        let polyM1Enc: Double
        let polyContSpacing: Double
        let impEnclosure: Double
        let nwellEnclosure: Double
        let m1MinWidth: Double
    }

    private struct CapacitorLayerContext {
        let activeID: LayoutLayerID
        let polyID: LayoutLayerID
        let contID: LayoutLayerID
        let m1ID: LayoutLayerID
        let nimpID: LayoutLayerID
        let nwellID: LayoutLayerID
        let contActiveDef: LayoutContactDefinition
        let contPolyDef: LayoutContactDefinition
        let m1Rules: LayoutLayerRuleSet
        let impEnclosure: Double
        let nwellEnclosure: Double
    }

    private func makeContext(
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> CapacitorCellContext {
        let c = try DeviceParameterValidation.requirePositive(parameters, "c", device: instanceName)
        let configuredOxideCapDensity = try DeviceParameterValidation.requirePositiveValue(
            oxideCapDensity,
            "oxideCapDensity",
            device: instanceName
        )

        let layerContext = try makeLayerContext(tech: tech)
        return makeContext(
            capacitance: c,
            oxideCapDensity: configuredOxideCapDensity,
            layerContext: layerContext,
            grid: tech.grid
        )
    }

    private func makeLayerContext(tech: LayoutTechDatabase) throws -> CapacitorLayerContext {
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

        let impEnclosure = try tech.requiredEnclosureRule(outer: nimpID, inner: activeID).minEnclosure
        let nwellEnclosure = try tech.requiredEnclosureRule(outer: nwellID, inner: activeID).minEnclosure

        return CapacitorLayerContext(
            activeID: activeID,
            polyID: polyID,
            contID: contID,
            m1ID: m1ID,
            nimpID: nimpID,
            nwellID: nwellID,
            contActiveDef: contActiveDef,
            contPolyDef: contPolyDef,
            m1Rules: m1Rules,
            impEnclosure: impEnclosure,
            nwellEnclosure: nwellEnclosure
        )
    }

    private func makeContext(
        capacitance: Double,
        oxideCapDensity: Double,
        layerContext: CapacitorLayerContext,
        grid: Double
    ) -> CapacitorCellContext {
        // Calculate overlap area: C = Cox × A → A = C / Cox
        let areaUm2 = capacitance / oxideCapDensity
        let side = snap(max(sqrt(areaUm2), 0.50), grid: grid)

        // Active-side contact geometry (CONT_ACTIVE)
        let actContSize = layerContext.contActiveDef.cutSize.width
        let actContEnc = layerContext.contActiveDef.enclosure.bottom
        let actM1Enc = layerContext.contActiveDef.enclosure.top
        let actContSpacing = layerContext.contActiveDef.cutSpacing
        let activeContactRegion = actContSize + 2 * actContEnc

        // Poly-side contact geometry (CONT_POLY)
        let polyContSize = layerContext.contPolyDef.cutSize.width
        let polyContEnc = layerContext.contPolyDef.enclosure.bottom
        let polyM1Enc = layerContext.contPolyDef.enclosure.top
        let polyContSpacing = layerContext.contPolyDef.cutSpacing
        let polyContactRegion = polyContSize + 2 * polyContEnc

        // Layout: [active contact region] [overlap region] [poly contact region]
        let overlapSize = side
        let cellWidth = snap(activeContactRegion + overlapSize + polyContactRegion, grid: grid)
        let cellHeight = snap(overlapSize, grid: grid)

        return CapacitorCellContext(
            activeID: layerContext.activeID,
            polyID: layerContext.polyID,
            contID: layerContext.contID,
            m1ID: layerContext.m1ID,
            nimpID: layerContext.nimpID,
            nwellID: layerContext.nwellID,
            grid: grid,
            overlapSize: overlapSize,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            activeContactRegion: activeContactRegion,
            polyContactRegion: polyContactRegion,
            actContSize: actContSize,
            actContEnc: actContEnc,
            actM1Enc: actM1Enc,
            actContSpacing: actContSpacing,
            polyContSize: polyContSize,
            polyContEnc: polyContEnc,
            polyM1Enc: polyM1Enc,
            polyContSpacing: polyContSpacing,
            impEnclosure: layerContext.impEnclosure,
            nwellEnclosure: layerContext.nwellEnclosure,
            m1MinWidth: layerContext.m1Rules.minWidth
        )
    }

    private func makeDeviceShapes(
        _ context: CapacitorCellContext
    ) -> (shapes: [LayoutShape], activeRect: LayoutRect) {
        var shapes: [LayoutShape] = []
        // 1. ACTIVE region (left part: active contact + overlap)
        let activeRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(
                width: snap(context.activeContactRegion + context.overlapSize, grid: context.grid),
                height: context.cellHeight
            )
        )
        shapes.append(LayoutShape(layer: context.activeID, geometry: .rect(activeRect)))

        // 2. N-Implant enclosing ACTIVE
        let impRect = activeRect.expanded(by: context.impEnclosure, context.impEnclosure)
        shapes.append(LayoutShape(layer: context.nimpID, geometry: .rect(impRect)))

        // 3. NWELL enclosing ACTIVE (for accumulation-mode MOS capacitor)
        let nwellRect = activeRect.expanded(by: context.nwellEnclosure, context.nwellEnclosure)
        shapes.append(LayoutShape(layer: context.nwellID, geometry: .rect(nwellRect)))

        // 4. POLY region (overlap + poly contact)
        let polyX = snap(context.activeContactRegion, grid: context.grid)
        let polyRect = LayoutRect(
            origin: LayoutPoint(x: polyX, y: 0),
            size: LayoutSize(
                width: snap(context.overlapSize + context.polyContactRegion, grid: context.grid),
                height: context.cellHeight
            )
        )
        shapes.append(LayoutShape(layer: context.polyID, geometry: .rect(polyRect)))
        return (shapes, activeRect)
    }

    private func makeContactShapes(_ context: CapacitorCellContext) -> [LayoutShape] {
        let actContX = snap(context.actContEnc, grid: context.grid)
        let actContacts = ContactArrayHelper.generateContacts1D(
            regionX: actContX,
            regionY: snap(context.actContEnc, grid: context.grid),
            regionHeight: max(context.actContSize, context.cellHeight - 2 * context.actContEnc),
            contSize: context.actContSize,
            contSpacing: context.actContSpacing,
            contLayer: context.contID,
            grid: context.grid
        )

        let polyContX = snap(
            context.cellWidth - context.polyContactRegion + context.polyContEnc,
            grid: context.grid
        )
        let polyContacts = ContactArrayHelper.generateContacts1D(
            regionX: polyContX,
            regionY: snap(context.polyContEnc, grid: context.grid),
            regionHeight: max(context.polyContSize, context.cellHeight - 2 * context.polyContEnc),
            contSize: context.polyContSize,
            contSpacing: context.polyContSpacing,
            contLayer: context.contID,
            grid: context.grid
        )
        return actContacts + polyContacts
    }

    private func makeMetalAndPins(
        _ context: CapacitorCellContext
    ) -> (shapes: [LayoutShape], pins: [LayoutPin]) {
        let actContX = snap(context.actContEnc, grid: context.grid)
        let polyContX = snap(
            context.cellWidth - context.polyContactRegion + context.polyContEnc,
            grid: context.grid
        )
        let negM1Width = max(context.m1MinWidth, context.actContSize + 2 * context.actM1Enc)
        let negM1Height = max(context.m1MinWidth, context.actContSize + 2 * context.actM1Enc)
        let actContY = snap(context.actContEnc, grid: context.grid)

        let negM1 = LayoutRect(
            origin: LayoutPoint(
                x: snap(actContX - context.actM1Enc, grid: context.grid),
                y: snap(actContY - context.actM1Enc, grid: context.grid)
            ),
            size: LayoutSize(
                width: snap(negM1Width, grid: context.grid),
                height: snap(negM1Height, grid: context.grid)
            )
        )

        let posM1Width = max(context.m1MinWidth, context.polyContSize + 2 * context.polyM1Enc)
        let posM1Height = max(context.m1MinWidth, context.polyContSize + 2 * context.polyM1Enc)
        let polyContY = snap(context.polyContEnc, grid: context.grid)

        let posM1 = LayoutRect(
            origin: LayoutPoint(
                x: snap(polyContX - context.polyM1Enc, grid: context.grid),
                y: snap(polyContY - context.polyM1Enc, grid: context.grid)
            ),
            size: LayoutSize(
                width: snap(posM1Width, grid: context.grid),
                height: snap(posM1Height, grid: context.grid)
            )
        )

        let shapes = [
            LayoutShape(layer: context.m1ID, geometry: .rect(negM1)),
            LayoutShape(layer: context.m1ID, geometry: .rect(posM1)),
        ]
        let pins = [
            LayoutPin(
                name: "neg",
                position: negM1.center,
                size: negM1.size,
                layer: context.m1ID,
                role: .signal
            ),
            LayoutPin(
                name: "pos",
                position: posM1.center,
                size: posM1.size,
                layer: context.m1ID,
                role: .signal
            ),
        ]
        return (shapes, pins)
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        ContactArrayHelper.snap(value, grid: grid)
    }
}
