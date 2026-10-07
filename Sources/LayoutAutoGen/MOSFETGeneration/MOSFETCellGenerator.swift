import Foundation
import LayoutCore
import LayoutTech

/// Generates MOSFET device cells with proper physical layers.
///
/// Supported devices: nmos, pmos (any suffix).
/// Required parameters: `w` (gate width, µm), `l` (gate length, µm).
/// Optional parameters: `nf` (number of fingers, default 1).
///
/// Generated layers per device:
/// - ACTIVE: diffusion region (W x activeLength)
/// - POLY: gate crossing ACTIVE with extension beyond
/// - NIMP or PIMP: implant enclosing ACTIVE
/// - NWELL: well enclosing ACTIVE + tap (PMOS only)
/// - CONTACT: source/drain/gate/bulk contacts
/// - M1: metal connection bars for each terminal
/// - Well/Substrate tap: opposite-implant ACTIVE + contacts for bulk connection
/// - Pins: drain, gate, source, bulk on M1
///
/// Multi-finger layout (nf > 1):
/// ```
/// [Source][Gate1][SharedSD][Gate2][SharedSD]...[GateN][Drain]
/// ```
/// All source/drain regions with even index (0, 2, ...) connect to source,
/// odd index (1, 3, ...) connect to drain. A horizontal M1 bus bar connects
/// all gate contacts outside the active region.
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
        let isPMOS = try DeviceParameterValidation.requireMOSKind(deviceKindID)
        let w = try DeviceParameterValidation.requirePositive(parameters, "w", device: instanceName)
        let l = try DeviceParameterValidation.requirePositive(parameters, "l", device: instanceName)
        let nf = try DeviceParameterValidation.requirePositiveInteger(
            parameters,
            "nf",
            defaultValue: 1,
            device: instanceName
        )

        let context = try MOSFETContext(
            isPMOS: isPMOS,
            w: w,
            l: l,
            nf: nf,
            tech: tech
        )

        if nf == 1 {
            return try generateSingleFinger(
                context: context,
                deviceKindID: deviceKindID,
                instanceName: instanceName
            )
        } else {
            return try generateMultiFinger(
                context: context,
                deviceKindID: deviceKindID,
                instanceName: instanceName
            )
        }
    }

    // MARK: - Shared context extracted from tech rules

    /// Holds all design-rule-derived parameters needed by both single-finger
    /// and multi-finger generators, avoiding redundant rule lookups.
    private struct MOSFETContext {
        let isPMOS: Bool
        let w: Double
        let l: Double
        let nf: Int
        let grid: Double

        // Layer IDs
        let activeID: LayoutLayerID
        let polyID: LayoutLayerID
        let impID: LayoutLayerID
        let tapImpID: LayoutLayerID
        let contID: LayoutLayerID
        let m1ID: LayoutLayerID

        // Design rules
        let activeRules: LayoutLayerRuleSet
        let polyRules: LayoutLayerRuleSet
        let m1Rules: LayoutLayerRuleSet
        let contDef: LayoutContactDefinition
        let polyContDef: LayoutContactDefinition
        let impEnclosure: Double
        let tech: LayoutTechDatabase

        // Contact geometry
        let contSize: Double
        let contEnc: Double
        let m1Enc: Double
        let contSpacing: Double
        let polyContEnc: Double
        let polyExtension: Double
        let contactRegionLength: Double
        let sdSpacing: Double
        let m1Width: Double

        init(isPMOS: Bool, w: Double, l: Double, nf: Int, tech: LayoutTechDatabase) throws {
            let layerContext = try Self.makeLayerContext(isPMOS: isPMOS, tech: tech)
            try Self.admitGateRules(layerContext, tech: tech)
            self.isPMOS = isPMOS
            self.w = w
            self.l = l
            self.nf = nf
            self.tech = tech
            self.grid = tech.grid

            activeID = layerContext.activeID
            polyID = layerContext.polyID
            impID = layerContext.impID
            tapImpID = layerContext.tapImpID
            contID = layerContext.contID
            m1ID = layerContext.m1ID
            activeRules = layerContext.activeRules
            polyRules = layerContext.polyRules
            contDef = layerContext.contDef
            m1Rules = layerContext.m1Rules
            polyContDef = layerContext.polyContDef
            impEnclosure = layerContext.impEnclosure

            contSize = layerContext.contDef.cutSize.width
            contEnc = layerContext.contDef.enclosure.bottom
            m1Enc = layerContext.contDef.enclosure.top
            contSpacing = layerContext.contDef.cutSpacing
            polyContEnc = layerContext.polyContDef.enclosure.bottom
            polyExtension = ContactArrayHelper.snapUp(
                max(
                    layerContext.polyRules.minWidth,
                    0.20,
                    layerContext.polyContDef.enclosure.bottom
                        + layerContext.polyContDef.cutSize.height
                        + layerContext.polyContDef.enclosure.bottom
                ),
                grid: tech.grid
            )
            contactRegionLength = contSize + 2 * contEnc
            sdSpacing = max(layerContext.activeRules.minSpacing, layerContext.contDef.cutSpacing)
            m1Width = max(layerContext.m1Rules.minWidth, contSize + 2 * layerContext.contDef.enclosure.top)
        }

        private struct LayerContext {
            let activeID: LayoutLayerID
            let polyID: LayoutLayerID
            let impID: LayoutLayerID
            let tapImpID: LayoutLayerID
            let contID: LayoutLayerID
            let m1ID: LayoutLayerID
            let activeRules: LayoutLayerRuleSet
            let polyRules: LayoutLayerRuleSet
            let contDef: LayoutContactDefinition
            let m1Rules: LayoutLayerRuleSet
            let polyContDef: LayoutContactDefinition
            let impEnclosure: Double
        }

        private static func makeLayerContext(isPMOS: Bool, tech: LayoutTechDatabase) throws -> LayerContext {
            let activeID = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
            let polyID = LayoutLayerID(name: "POLY", purpose: "drawing")
            let impID = isPMOS
                ? LayoutLayerID(name: "PIMP", purpose: "drawing")
                : LayoutLayerID(name: "NIMP", purpose: "drawing")
            let tapImpID = isPMOS
                ? LayoutLayerID(name: "NIMP", purpose: "drawing")
                : LayoutLayerID(name: "PIMP", purpose: "drawing")
            let contID = LayoutLayerID(name: "CONTACT", purpose: "cut")
            let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
            return LayerContext(
                activeID: activeID,
                polyID: polyID,
                impID: impID,
                tapImpID: tapImpID,
                contID: contID,
                m1ID: m1ID,
                activeRules: try requireLayerRule(tech, activeID, name: "ACTIVE"),
                polyRules: try requireLayerRule(tech, polyID, name: "POLY"),
                contDef: try requireContactDefinition(tech, "CONT_ACTIVE"),
                m1Rules: try requireLayerRule(tech, m1ID, name: "M1"),
                polyContDef: try requireContactDefinition(tech, "CONT_POLY"),
                impEnclosure: try tech.requiredEnclosureRule(outer: impID, inner: activeID).minEnclosure
            )
        }

        private static func admitGateRules(_ context: LayerContext, tech: LayoutTechDatabase) throws {
            let contact = context.polyContDef
            guard contact.cutLayer == context.contID, contact.bottomLayer == context.polyID,
                  contact.topLayer == context.m1ID else {
                throw AutoGenError.placementFailed("CONT_POLY must name CONTACT, POLY and M1 materials")
            }
            for (field, value) in [("grid", tech.grid), ("CONT_POLY.cutWidth", contact.cutSize.width),
                                  ("CONT_POLY.cutHeight", contact.cutSize.height),
                                  ("POLY.minWidth", context.polyRules.minWidth), ("M1.minWidth", context.m1Rules.minWidth)] {
                guard value.isFinite, value > 0 else {
                    throw AutoGenError.placementFailed("Invalid positive gate rule " + field)
                }
            }
            for (field, value) in [("CONT_POLY.bottomEnclosure", contact.enclosure.bottom),
                                  ("CONT_POLY.topEnclosure", contact.enclosure.top),
                                  ("M1.minSpacing", context.m1Rules.minSpacing)] {
                guard value.isFinite, value >= 0 else {
                    throw AutoGenError.placementFailed("Invalid nonnegative gate rule " + field)
                }
            }
            for dimension in [contact.cutSize.width, contact.cutSize.height] {
                let steps = dimension / tech.grid
                guard steps.isFinite, abs(steps - steps.rounded()) <= steps.ulp * 4 else {
                    throw AutoGenError.placementFailed("CONT_POLY cut dimensions must be exact on the manufacturing grid")
                }
            }
        }

        private static func requireLayerRule(
            _ tech: LayoutTechDatabase,
            _ layerID: LayoutLayerID,
            name: String
        ) throws -> LayoutLayerRuleSet {
            guard let rule = tech.ruleSet(for: layerID) else {
                throw AutoGenError.missingLayerRule(name)
            }
            return rule
        }

        private static func requireContactDefinition(
            _ tech: LayoutTechDatabase,
            _ contactID: String
        ) throws -> LayoutContactDefinition {
            guard let contact = tech.contactDefinition(for: contactID) else {
                throw AutoGenError.missingContactDefinition(contactID)
            }
            return contact
        }
    }

    // MARK: - Single-Finger Generation

    private func generateSingleFinger(
        context c: MOSFETContext,
        deviceKindID: String,
        instanceName: String
    ) throws -> LayoutCell {
        let base = makeSingleFingerBaseLayout(context: c)
        let terminals = makeSingleFingerTerminalLayout(
            context: c,
            activeL: base.activeL,
            activeW: base.activeW
        )
        let gate = try makeSingleFingerGateLayout(
            context: c,
            polyRect: base.polyRect,
            gateContY: base.gateContY,
            activeW: base.activeW
        )
        let tap = makeSingleFingerTapLayout(
            context: c,
            activeL: base.activeL,
            activeW: base.activeW
        )

        var shapes = base.shapes
        shapes += terminals.shapes
        shapes += gate.shapes
        shapes += tap.shapes
        if c.isPMOS {
            shapes.append(try makePMOSWellShape(context: c, activeRect: base.activeRect, tapActiveRect: tap.tapActiveRect))
        }

        let pins = makeSingleFingerPins(
            context: c,
            activeW: base.activeW,
            sourceM1Rect: terminals.sourceM1Rect,
            drainM1Rect: terminals.drainM1Rect,
            gateM1Rect: gate.gateM1Rect,
            tapM1Rect: tap.tapM1Rect
        )
        let labels = [
            LayoutLabel(
                text: instanceName,
                position: base.activeRect.center,
                layer: c.m1ID
            )
        ]

        return LayoutCell(
            name: "\(instanceName)_\(deviceKindID)",
            shapes: shapes,
            labels: labels,
            pins: pins
        )
    }

    private struct SingleFingerBaseLayout {
        let activeL: Double
        let activeW: Double
        let activeRect: LayoutRect
        let polyRect: LayoutRect
        let gateContY: Double
        let shapes: [LayoutShape]
    }

    private struct SingleFingerTerminalLayout {
        let shapes: [LayoutShape]
        let sourceM1Rect: LayoutRect
        let drainM1Rect: LayoutRect
    }

    private struct SingleFingerGateLayout {
        let shapes: [LayoutShape]
        let gateM1Rect: LayoutRect
    }

    private struct SingleFingerTapLayout {
        let shapes: [LayoutShape]
        let tapActiveRect: LayoutRect
        let tapM1Rect: LayoutRect
    }

    private struct GateVerticalLayout {
        let polyOriginY: Double
        let polyHeight: Double
        let gateContactY: Double
    }

    private func makeSingleFingerBaseLayout(context c: MOSFETContext) -> SingleFingerBaseLayout {
        let activeLength = c.contactRegionLength + c.sdSpacing + c.l + c.sdSpacing + c.contactRegionLength
        let activeL = snap(activeLength, grid: c.grid)
        let activeW = snap(c.w, grid: c.grid)
        let activeRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: activeL, height: activeW)
        )
        let impRect = activeRect.expanded(by: c.impEnclosure, c.impEnclosure)
        let polyX = snap(c.contactRegionLength + c.sdSpacing, grid: c.grid)
        let gateLayout = makeSingleFingerPolyLayout(context: c, activeW: activeW, polyX: polyX)
        let shapes = [
            LayoutShape(layer: c.activeID, geometry: .rect(activeRect)),
            LayoutShape(layer: c.impID, geometry: .rect(impRect)),
            LayoutShape(layer: c.polyID, geometry: .rect(gateLayout.polyRect)),
        ]
        return SingleFingerBaseLayout(
            activeL: activeL,
            activeW: activeW,
            activeRect: activeRect,
            polyRect: gateLayout.polyRect,
            gateContY: gateLayout.gateContY,
            shapes: shapes
        )
    }

    private func makeSingleFingerPolyLayout(
        context c: MOSFETContext,
        activeW: Double,
        polyX: Double
    ) -> (polyRect: LayoutRect, gateContY: Double) {
        let vertical = makeGateVerticalLayout(context: c, activeW: activeW)
        let polyRect = LayoutRect(
            origin: LayoutPoint(x: polyX, y: vertical.polyOriginY),
            size: LayoutSize(
                width: snap(c.l, grid: c.grid),
                height: vertical.polyHeight
            )
        )
        return (polyRect, vertical.gateContactY)
    }

    private func gateMetalHeight(_ c: MOSFETContext) -> Double {
        ContactArrayHelper.snapUp(max(c.m1Rules.minWidth,
            c.polyContDef.cutSize.height + 2 * c.polyContDef.enclosure.top), grid: c.grid)
    }

    private func makeGateVerticalLayout(context c: MOSFETContext, activeW: Double, terminalSpineWidth: Double = 0) -> GateVerticalLayout {
        let height = gateMetalHeight(c)
        let cutHeight = c.polyContDef.cutSize.height
        let spineClearance = terminalSpineWidth > 0 ? terminalSpineWidth + c.m1Rules.minSpacing : 0
        if c.isPMOS {
            let base = snap(-c.polyExtension + c.polyContEnc, grid: c.grid)
            let metalBound = (-(c.m1Rules.minSpacing + spineClearance + height) / c.grid).rounded(.down) * c.grid
            let polyBound = (-(c.polyContEnc + (height + cutHeight) / 2 + c.grid) / c.grid).rounded(.down) * c.grid
            let gateContactY = min(base, metalBound, polyBound)
            let shift = base - gateContactY
            return GateVerticalLayout(
                polyOriginY: snap(-c.polyExtension - shift, grid: c.grid),
                polyHeight: snap(activeW + c.polyExtension + c.polyRules.minWidth + shift, grid: c.grid),
                gateContactY: gateContactY)
        }
        let base = snap(activeW + c.polyExtension - c.polyContEnc - cutHeight, grid: c.grid)
        let metalBound = ((activeW + c.m1Rules.minSpacing + spineClearance) / c.grid).rounded(.up) * c.grid
        let polyBound = ((activeW + c.polyContEnc - (height - cutHeight) / 2 + c.grid) / c.grid).rounded(.up) * c.grid
        let gateContactY = max(base, metalBound, polyBound)
        let shift = gateContactY - base
        return GateVerticalLayout(
            polyOriginY: snap(-c.polyRules.minWidth, grid: c.grid),
            polyHeight: snap(activeW + c.polyExtension + c.polyRules.minWidth + shift, grid: c.grid),
            gateContactY: gateContactY)
    }

    private func makeSingleFingerTerminalLayout(
        context c: MOSFETContext,
        activeL: Double,
        activeW: Double
    ) -> SingleFingerTerminalLayout {
        let sourceContX = snap(c.contEnc, grid: c.grid)
        let drainContX = snap(activeL - c.contactRegionLength + c.contEnc, grid: c.grid)
        let sourceContacts = ContactArrayHelper.generateContacts1D(
            regionX: sourceContX,
            regionY: snap(c.contEnc, grid: c.grid),
            regionHeight: activeW - 2 * c.contEnc,
            contSize: c.contSize,
            contSpacing: c.contSpacing,
            contLayer: c.contID,
            grid: c.grid
        )
        let drainContacts = ContactArrayHelper.generateContacts1D(
            regionX: drainContX,
            regionY: snap(c.contEnc, grid: c.grid),
            regionHeight: activeW - 2 * c.contEnc,
            contSize: c.contSize,
            contSpacing: c.contSpacing,
            contLayer: c.contID,
            grid: c.grid
        )
        let sourceM1Rect = LayoutRect(
            origin: LayoutPoint(x: snap(sourceContX - c.m1Enc, grid: c.grid), y: 0),
            size: LayoutSize(width: snap(c.m1Width, grid: c.grid), height: activeW)
        )
        let drainM1Rect = LayoutRect(
            origin: LayoutPoint(x: snap(drainContX - c.m1Enc, grid: c.grid), y: 0),
            size: LayoutSize(width: snap(c.m1Width, grid: c.grid), height: activeW)
        )
        var shapes = sourceContacts + drainContacts
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(sourceM1Rect)))
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(drainM1Rect)))
        return SingleFingerTerminalLayout(shapes: shapes, sourceM1Rect: sourceM1Rect, drainM1Rect: drainM1Rect)
    }

    private struct GateContactLanding {
        let cut: LayoutRect
        let poly: LayoutRect
        let metal: LayoutRect
    }

    private func gateLanding(context c: MOSFETContext, polyRect: LayoutRect,
                             metalY: Double, activeW: Double) throws -> GateContactLanding {
        let contact = c.polyContDef
        let height = gateMetalHeight(c)
        let cut = LayoutRect(origin: .init(
            x: snap(polyRect.minX + (polyRect.size.width - contact.cutSize.width) / 2, grid: c.grid),
            y: snap(metalY + (height - contact.cutSize.height) / 2, grid: c.grid)), size: contact.cutSize)
        func enclosing(_ margin: Double) throws -> LayoutRect {
            let steps = (margin / c.grid).rounded(.up)
            let minX = (cut.minX / c.grid).rounded() - steps
            let minY = (cut.minY / c.grid).rounded() - steps
            let maxX = (cut.maxX / c.grid).rounded() + steps
            let maxY = (cut.maxY / c.grid).rounded() + steps
            guard [minX, minY, maxX, maxY].allSatisfy(\.isFinite), maxX > minX, maxY > minY else {
                throw AutoGenError.placementFailed("Gate contact landing is not representable")
            }
            return LayoutRect(origin: .init(x: minX * c.grid, y: minY * c.grid),
                              size: .init(width: (maxX - minX) * c.grid, height: (maxY - minY) * c.grid))
        }
        let poly = try enclosing(contact.enclosure.bottom)
        let metal = try enclosing(contact.enclosure.top)
        guard [poly.minX, poly.minY, poly.maxX, poly.maxY, metal.minX, metal.minY, metal.maxX, metal.maxY].allSatisfy(\.isFinite),
              max(poly.minX, polyRect.minX) < min(poly.maxX, polyRect.maxX),
              max(poly.minY, polyRect.minY) < min(poly.maxY, polyRect.maxY),
              c.isPMOS ? poly.maxY < 0 : poly.minY > activeW else {
            throw AutoGenError.placementFailed("Gate landing must contact its POLY extension outside ACTIVE")
        }
        return GateContactLanding(cut: cut, poly: poly, metal: metal)
    }

    private func makeSingleFingerGateLayout(context c: MOSFETContext, polyRect: LayoutRect,
                                            gateContY: Double, activeW: Double) throws -> SingleFingerGateLayout {
        let landing = try gateLanding(context: c, polyRect: polyRect, metalY: gateContY, activeW: activeW)
        let width = snap(max(polyRect.size.width, c.m1Width), grid: c.grid)
        let originalMetal = LayoutRect(origin: .init(
            x: snap(polyRect.minX + (polyRect.size.width - width) / 2, grid: c.grid), y: gateContY),
            size: .init(width: width, height: gateMetalHeight(c)))
        let metal = originalMetal.union(landing.metal)
        return SingleFingerGateLayout(shapes: [
            LayoutShape(layer: c.m1ID, geometry: .rect(metal)),
            LayoutShape(layer: c.contID, geometry: .rect(landing.cut)),
            LayoutShape(layer: c.polyID, geometry: .rect(landing.poly))
        ], gateM1Rect: metal)
    }

    private func makeSingleFingerTapLayout(
        context c: MOSFETContext,
        activeL: Double,
        activeW: Double
    ) -> SingleFingerTapLayout {
        let tapSpacing = snap(max(c.activeRules.minSpacing, 2 * c.impEnclosure + c.grid), grid: c.grid)
        let tapHeight = snap(c.contSize + 2 * c.contEnc, grid: c.grid)
        let tapY = c.isPMOS
            ? snap(activeW + tapSpacing, grid: c.grid)
            : snap(-tapSpacing - tapHeight, grid: c.grid)
        let tapActiveRect = LayoutRect(
            origin: LayoutPoint(x: 0, y: tapY),
            size: LayoutSize(width: activeL, height: tapHeight)
        )
        let tapImpRect = tapActiveRect.expanded(by: c.impEnclosure, c.impEnclosure)
        let tapContacts = ContactArrayHelper.generateContacts2D(
            regionX: c.contEnc,
            regionY: tapY + c.contEnc,
            regionWidth: activeL - 2 * c.contEnc,
            regionHeight: tapHeight - 2 * c.contEnc,
            contSize: c.contSize,
            contSpacing: c.contSpacing,
            contLayer: c.contID,
            grid: c.grid
        )
        let tapM1Rect = LayoutRect(
            origin: LayoutPoint(x: snap(-c.m1Enc, grid: c.grid), y: tapY),
            size: LayoutSize(width: snap(activeL + 2 * c.m1Enc, grid: c.grid), height: tapHeight)
        )
        var shapes = [
            LayoutShape(layer: c.activeID, geometry: .rect(tapActiveRect)),
            LayoutShape(layer: c.tapImpID, geometry: .rect(tapImpRect)),
        ]
        shapes += tapContacts
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(tapM1Rect)))
        return SingleFingerTapLayout(shapes: shapes, tapActiveRect: tapActiveRect, tapM1Rect: tapM1Rect)
    }

    private func makePMOSWellShape(
        context c: MOSFETContext,
        activeRect: LayoutRect,
        tapActiveRect: LayoutRect
    ) throws -> LayoutShape {
        let nwellID = LayoutLayerID(name: "NWELL", purpose: "drawing")
        let nwellEnc = try c.tech.requiredEnclosureRule(outer: nwellID, inner: c.activeID).minEnclosure
        let combinedRect = activeRect.union(tapActiveRect)
        let nwellRect = combinedRect.expanded(by: nwellEnc, nwellEnc)
        return LayoutShape(layer: nwellID, geometry: .rect(nwellRect))
    }

    private func makeSingleFingerPins(
        context c: MOSFETContext,
        activeW: Double,
        sourceM1Rect: LayoutRect,
        drainM1Rect: LayoutRect,
        gateM1Rect: LayoutRect,
        tapM1Rect: LayoutRect
    ) -> [LayoutPin] {
        [
            LayoutPin(
                name: "source",
                position: sourceM1Rect.center,
                size: LayoutSize(width: c.m1Width, height: activeW),
                layer: c.m1ID,
                role: .source
            ),
            LayoutPin(
                name: "drain",
                position: drainM1Rect.center,
                size: LayoutSize(width: c.m1Width, height: activeW),
                layer: c.m1ID,
                role: .drain
            ),
            LayoutPin(
                name: "gate",
                position: gateM1Rect.center,
                size: gateM1Rect.size,
                layer: c.m1ID,
                role: .gate
            ),
            LayoutPin(
                name: "bulk",
                position: tapM1Rect.center,
                size: tapM1Rect.size,
                layer: c.m1ID,
                role: .bulk
            ),
        ]
    }

    // MARK: - Multi-Finger Generation

    /// Generates a multi-finger MOSFET cell (nf > 1).
    ///
    /// Layout structure (left to right):
    /// ```
    /// [SourceContacts][Gate0][SharedSD][Gate1]...[GateN-1][DrainContacts]
    /// ```
    ///
    /// Between each pair of adjacent gate fingers there is a shared source/drain
    /// diffusion region with contacts. S/D regions alternate by index:
    /// index 0 = source (left edge), index 1 = drain, index 2 = source, ...
    ///
    /// All gate poly fingers are connected by a horizontal M1 bus bar placed
    /// outside the ACTIVE region (above for NMOS, below for PMOS), with one
    /// contact per finger landing on the bus bar.
    private func generateMultiFinger(
        context c: MOSFETContext,
        deviceKindID: String,
        instanceName: String
    ) throws -> LayoutCell {
        let nf = c.nf
        let snappedL = snap(c.l, grid: c.grid)
        let activeW = snap(c.w, grid: c.grid)

        // --- Geometry calculations ---
        // There are (nf + 1) S/D contact regions and nf gate fingers.
        // Between each gate and its neighboring S/D region there is sdSpacing.
        // activeLength = (nf+1)*contactRegionLength + nf*l + (nf+1 + nf-1)*sdSpacing
        //              = (nf+1)*contactRegionLength + nf*l + 2*nf*sdSpacing
        // Explanation: each gate has sdSpacing on both sides = 2*nf*sdSpacing total.
        // But the outermost sdSpacings are already counted once each.
        // Correct formula:
        //   activeLength = contactRegionLength                (left S/D)
        //                + sdSpacing                          (left S/D to gate0)
        //                + l                                  (gate0)
        //                + (nf-1) * (sdSpacing + contactRegionLength + sdSpacing + l)
        //                                                     (shared S/D + subsequent gates)
        //                + sdSpacing                          (last gate to right S/D)
        //                + contactRegionLength                (right S/D)
        let fingerPitch = c.sdSpacing + c.contactRegionLength + c.sdSpacing + snappedL
        let activeLength = c.contactRegionLength + c.sdSpacing + snappedL
                         + Double(nf - 1) * fingerPitch
                         + c.sdSpacing + c.contactRegionLength
        let activeL = snap(activeLength, grid: c.grid)

        var shapes: [LayoutShape] = []
        var pins: [LayoutPin] = []
        var labels: [LayoutLabel] = []

        // 1. ACTIVE rectangle
        let activeRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: activeL, height: activeW)
        )
        shapes.append(LayoutShape(layer: c.activeID, geometry: .rect(activeRect)))

        // 2. Implant enclosing ACTIVE
        let impRect = activeRect.expanded(by: c.impEnclosure, c.impEnclosure)
        shapes.append(LayoutShape(layer: c.impID, geometry: .rect(impRect)))

        // --- Compute X positions of each poly finger ---
        // Gate[i] left edge X:
        //   gate0_x = contactRegionLength + sdSpacing
        //   gate_i_x = gate0_x + i * fingerPitch
        let gate0X = snap(c.contactRegionLength + c.sdSpacing, grid: c.grid)
        let gateVertical = makeGateVerticalLayout(context: c, activeW: activeW,
            terminalSpineWidth: snap(c.m1Width, grid: c.grid))
        var polyXPositions: [Double] = []
        for i in 0..<nf {
            polyXPositions.append(snap(gate0X + Double(i) * fingerPitch, grid: c.grid))
        }

        // --- Compute X positions of each S/D contact region ---
        // There are (nf + 1) S/D regions: index 0 is leftmost (source), last is rightmost (drain).
        // sd_region[0] left edge = 0  (start of active)
        // sd_region[i] left edge = polyXPositions[i-1] + l + sdSpacing  (for i >= 1)
        // sd_region[nf] left edge = polyXPositions[nf-1] + l + sdSpacing
        var sdRegionX: [Double] = [0.0]
        for i in 1...nf {
            sdRegionX.append(snap(polyXPositions[i - 1] + snappedL + c.sdSpacing, grid: c.grid))
        }

        // 3. POLY fingers
        for i in 0..<nf {
            let px = polyXPositions[i]
            let polyRect = LayoutRect(
                origin: LayoutPoint(x: px, y: gateVertical.polyOriginY),
                size: LayoutSize(width: snappedL, height: gateVertical.polyHeight)
            )
            shapes.append(LayoutShape(layer: c.polyID, geometry: .rect(polyRect)))
        }

        // 4. S/D contacts for all (nf + 1) regions
        let contRegionY = snap(c.contEnc, grid: c.grid)
        let contRegionH = activeW - 2 * c.contEnc
        let snappedM1Width = snap(c.m1Width, grid: c.grid)

        // Track M1 rects for source and drain bars (to build bus bars)
        var sourceM1Rects: [LayoutRect] = []
        var drainM1Rects: [LayoutRect] = []

        for i in 0...nf {
            let regionLeftX = sdRegionX[i]
            let contX = snap(regionLeftX + c.contEnc, grid: c.grid)

            // Contacts
            let contacts = ContactArrayHelper.generateContacts1D(
                regionX: contX,
                regionY: contRegionY,
                regionHeight: contRegionH,
                contSize: c.contSize,
                contSpacing: c.contSpacing,
                contLayer: c.contID,
                grid: c.grid
            )
            shapes.append(contentsOf: contacts)

            // M1 bar for this S/D region
            let m1X = snap(contX - c.m1Enc, grid: c.grid)
            let m1Rect = LayoutRect(
                origin: LayoutPoint(x: m1X, y: 0),
                size: LayoutSize(width: snappedM1Width, height: activeW)
            )
            // Classify: even indices are source, odd indices are drain
            // (index 0 = source edge, index 1 = drain, index 2 = source, ...)
            if i % 2 == 0 {
                sourceM1Rects.append(m1Rect)
            } else {
                drainM1Rects.append(m1Rect)
            }
        }

        // 5-6. Exterior spines cannot intersect opposite-terminal fingers.
        let sourceSpineY = ((-c.m1Rules.minSpacing - snappedM1Width) / c.grid).rounded(.down) * c.grid
        let drainSpineY = ContactArrayHelper.snapUp(activeW + c.m1Rules.minSpacing, grid: c.grid)
        func terminalSpine(_ fingers: [LayoutRect], below: Bool) throws -> LayoutRect {
            guard let minX = fingers.map(\.minX).min(), let maxX = fingers.map(\.maxX).max() else {
                throw AutoGenError.placementFailed("MOSFET terminal has no metal fingers")
            }
            let y = below ? sourceSpineY : drainSpineY
            let spine = LayoutRect(origin: .init(x: minX, y: y),
                size: .init(width: maxX - minX, height: snappedM1Width))
            for finger in fingers {
                let minY = below ? y : finger.minY
                let maxY = below ? finger.maxY : spine.maxY
                shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(LayoutRect(
                    origin: .init(x: finger.minX, y: minY),
                    size: .init(width: finger.size.width, height: maxY - minY)))))
            }
            shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(spine)))
            return spine
        }
        let sourceM1Bus = try terminalSpine(sourceM1Rects, below: true)
        let drainM1Bus = try terminalSpine(drainM1Rects, below: false)

        // 7. Gate contacts and gate bus bar
        //    Position: outside ACTIVE, on the side away from the tap.
        //    NMOS: gate contacts above active (tap is below)
        //    PMOS: gate contacts below active (tap is above)
        let gateContY = gateVertical.gateContactY

        // Gate bus bar spans from leftmost poly to rightmost poly
        guard let firstPolyX = polyXPositions.first,
              let lastPolyX = polyXPositions.last else {
            throw AutoGenError.placementFailed("MOSFET gate terminal has no polysilicon positions")
        }
        let gateBusLeftX = snap(firstPolyX, grid: c.grid)
        let gateBusRightX = snap(lastPolyX + snappedL, grid: c.grid)
        let originalGateBus = LayoutRect(
            origin: LayoutPoint(x: gateBusLeftX, y: gateContY),
            size: LayoutSize(width: snap(gateBusRightX - gateBusLeftX, grid: c.grid),
                             height: gateMetalHeight(c)))
        let gateLandings = try polyXPositions.map { x in
            try gateLanding(context: c, polyRect: LayoutRect(
                origin: .init(x: x, y: gateVertical.polyOriginY),
                size: .init(width: snappedL, height: gateVertical.polyHeight)),
                metalY: gateContY, activeW: activeW)
        }
        let gateBusM1Rect = gateLandings.reduce(originalGateBus) { $0.union($1.metal) }
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(gateBusM1Rect)))
        for landing in gateLandings {
            shapes.append(LayoutShape(layer: c.contID, geometry: .rect(landing.cut)))
            shapes.append(LayoutShape(layer: c.polyID, geometry: .rect(landing.poly)))
        }

        // 8. Well/Substrate tap
        let tapSpacing = ContactArrayHelper.snapUp(
            max(c.activeRules.minSpacing, 2 * c.impEnclosure + c.grid, c.m1Rules.minSpacing), grid: c.grid)
        let tapHeight = snap(c.contSize + 2 * c.contEnc, grid: c.grid)

        let tapY: Double
        if c.isPMOS {
            tapY = ContactArrayHelper.snapUp(drainM1Bus.maxY + tapSpacing, grid: c.grid)
        } else {
            tapY = ((sourceM1Bus.minY - tapSpacing - tapHeight) / c.grid).rounded(.down) * c.grid
        }

        let tapActiveRect = LayoutRect(
            origin: LayoutPoint(x: 0, y: tapY),
            size: LayoutSize(width: activeL, height: tapHeight)
        )
        shapes.append(LayoutShape(layer: c.activeID, geometry: .rect(tapActiveRect)))

        let tapImpRect = tapActiveRect.expanded(by: c.impEnclosure, c.impEnclosure)
        shapes.append(LayoutShape(layer: c.tapImpID, geometry: .rect(tapImpRect)))

        let tapContacts = ContactArrayHelper.generateContacts2D(
            regionX: c.contEnc,
            regionY: tapY + c.contEnc,
            regionWidth: activeL - 2 * c.contEnc,
            regionHeight: tapHeight - 2 * c.contEnc,
            contSize: c.contSize,
            contSpacing: c.contSpacing,
            contLayer: c.contID,
            grid: c.grid
        )
        shapes.append(contentsOf: tapContacts)

        let tapM1Rect = LayoutRect(
            origin: LayoutPoint(x: snap(-c.m1Enc, grid: c.grid), y: tapY),
            size: LayoutSize(width: snap(activeL + 2 * c.m1Enc, grid: c.grid), height: tapHeight)
        )
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(tapM1Rect)))

        // 9. NWELL (PMOS only)
        if c.isPMOS {
            let nwellID = LayoutLayerID(name: "NWELL", purpose: "drawing")
            let nwellEnc = try c.tech.requiredEnclosureRule(outer: nwellID, inner: c.activeID).minEnclosure
            let combinedRect = activeRect.union(tapActiveRect)
            let nwellRect = combinedRect.expanded(by: nwellEnc, nwellEnc)
            shapes.append(LayoutShape(layer: nwellID, geometry: .rect(nwellRect)))
        }

        // 10. Pins
        // Source pin: center of the source bus bar (or the single source M1 bar)
        let sourcePinRect = sourceM1Bus
        pins.append(LayoutPin(
            name: "source",
            position: sourcePinRect.center,
            size: sourcePinRect.size,
            layer: c.m1ID,
            role: .source
        ))

        // Drain pin: center of the drain bus bar (or the single drain M1 bar)
        let drainPinRect = drainM1Bus
        pins.append(LayoutPin(
            name: "drain",
            position: drainPinRect.center,
            size: drainPinRect.size,
            layer: c.m1ID,
            role: .drain
        ))

        // Gate pin: center of the gate bus bar
        pins.append(LayoutPin(
            name: "gate",
            position: gateBusM1Rect.center,
            size: gateBusM1Rect.size,
            layer: c.m1ID,
            role: .gate
        ))

        // Bulk pin: center of the tap M1 bar
        pins.append(LayoutPin(
            name: "bulk",
            position: tapM1Rect.center,
            size: tapM1Rect.size,
            layer: c.m1ID,
            role: .bulk
        ))

        // 11. Labels
        labels.append(LayoutLabel(
            text: instanceName,
            position: activeRect.center,
            layer: c.m1ID
        ))

        return LayoutCell(
            name: "\(instanceName)_\(deviceKindID)",
            shapes: shapes,
            labels: labels,
            pins: pins
        )
    }

    // MARK: - Helpers

    private func snap(_ value: Double, grid: Double) -> Double {
        ContactArrayHelper.snap(value, grid: grid)
    }
}
