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
/// All source/drain fingers with even index (0, 2, ...) connect to source,
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
        let isPMOS = deviceKindID.hasPrefix("pmos")

        guard let w = parameters["w"] else {
            throw AutoGenError.missingParameter(device: instanceName, parameter: "w")
        }
        guard let l = parameters["l"] else {
            throw AutoGenError.missingParameter(device: instanceName, parameter: "l")
        }

        let nf = max(1, Int(parameters["nf"] ?? 1.0))

        let context = try MOSFETContext(
            isPMOS: isPMOS,
            w: w,
            l: l,
            nf: nf,
            tech: tech
        )

        if nf == 1 {
            return generateSingleFinger(
                context: context,
                deviceKindID: deviceKindID,
                instanceName: instanceName
            )
        } else {
            return generateMultiFinger(
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
        let polyContDef: LayoutContactDefinition?
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
            self.isPMOS = isPMOS
            self.w = w
            self.l = l
            self.nf = nf
            self.tech = tech
            self.grid = tech.grid

            activeID = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
            polyID   = LayoutLayerID(name: "POLY", purpose: "drawing")
            impID    = isPMOS
                ? LayoutLayerID(name: "PIMP", purpose: "drawing")
                : LayoutLayerID(name: "NIMP", purpose: "drawing")
            tapImpID = isPMOS
                ? LayoutLayerID(name: "NIMP", purpose: "drawing")
                : LayoutLayerID(name: "PIMP", purpose: "drawing")
            contID   = LayoutLayerID(name: "CONTACT", purpose: "cut")
            m1ID     = LayoutLayerID(name: "M1", purpose: "drawing")

            guard let ar = tech.ruleSet(for: activeID) else {
                throw AutoGenError.missingLayerRule("ACTIVE")
            }
            activeRules = ar

            guard let pr = tech.ruleSet(for: polyID) else {
                throw AutoGenError.missingLayerRule("POLY")
            }
            polyRules = pr

            guard let cd = tech.contactDefinition(for: "CONT_ACTIVE") else {
                throw AutoGenError.missingContactDefinition("CONT_ACTIVE")
            }
            contDef = cd

            guard let mr = tech.ruleSet(for: m1ID) else {
                throw AutoGenError.missingLayerRule("M1")
            }
            m1Rules = mr

            polyContDef = tech.contactDefinition(for: "CONT_POLY")
            impEnclosure = tech.enclosureRule(outer: impID, inner: activeID)?.minEnclosure ?? 0.14

            contSize = cd.cutSize.width
            contEnc = cd.enclosure.bottom
            m1Enc = cd.enclosure.top
            contSpacing = cd.cutSpacing
            polyContEnc = polyContDef?.enclosure.bottom ?? 0.08
            polyExtension = ContactArrayHelper.snap(
                max(pr.minWidth, 0.20, (polyContDef?.enclosure.bottom ?? 0.08) + cd.cutSize.width + (polyContDef?.enclosure.bottom ?? 0.08)),
                grid: tech.grid
            )
            contactRegionLength = contSize + 2 * contEnc
            sdSpacing = max(ar.minSpacing, cd.cutSpacing)
            m1Width = max(mr.minWidth, contSize + 2 * cd.enclosure.top)
        }
    }

    // MARK: - Single-Finger Generation

    /// Generates a single-finger MOSFET cell. This is the original layout logic,
    /// preserved exactly for backward compatibility when nf == 1.
    private func generateSingleFinger(
        context c: MOSFETContext,
        deviceKindID: String,
        instanceName: String
    ) -> LayoutCell {
        let activeLength = c.contactRegionLength + c.sdSpacing + c.l + c.sdSpacing + c.contactRegionLength
        let activeL = snap(activeLength, grid: c.grid)
        let activeW = snap(c.w, grid: c.grid)

        var shapes: [LayoutShape] = []
        var pins: [LayoutPin] = []
        var labels: [LayoutLabel] = []

        let activeRect = LayoutRect(
            origin: .zero,
            size: LayoutSize(width: activeL, height: activeW)
        )

        // 1. ACTIVE
        shapes.append(LayoutShape(layer: c.activeID, geometry: .rect(activeRect)))

        // 2. Implant enclosing ACTIVE
        let impRect = activeRect.expanded(by: c.impEnclosure, c.impEnclosure)
        shapes.append(LayoutShape(layer: c.impID, geometry: .rect(impRect)))

        // 3. POLY gate
        let polyX = snap(c.contactRegionLength + c.sdSpacing, grid: c.grid)
        let polyRect: LayoutRect
        if c.isPMOS {
            polyRect = LayoutRect(
                origin: LayoutPoint(x: polyX, y: -c.polyExtension),
                size: LayoutSize(width: snap(c.l, grid: c.grid), height: activeW + c.polyExtension + c.polyRules.minWidth)
            )
        } else {
            polyRect = LayoutRect(
                origin: LayoutPoint(x: polyX, y: -c.polyRules.minWidth),
                size: LayoutSize(width: snap(c.l, grid: c.grid), height: activeW + c.polyExtension + c.polyRules.minWidth)
            )
        }
        shapes.append(LayoutShape(layer: c.polyID, geometry: .rect(polyRect)))

        // 4. Source contacts (left)
        let sourceContX = snap(c.contEnc, grid: c.grid)
        let sourceContacts = ContactArrayHelper.generateContacts1D(
            regionX: sourceContX,
            regionY: snap(c.contEnc, grid: c.grid),
            regionHeight: activeW - 2 * c.contEnc,
            contSize: c.contSize,
            contSpacing: c.contSpacing,
            contLayer: c.contID,
            grid: c.grid
        )
        shapes.append(contentsOf: sourceContacts)

        // 5. Drain contacts (right)
        let drainContX = snap(activeL - c.contactRegionLength + c.contEnc, grid: c.grid)
        let drainContacts = ContactArrayHelper.generateContacts1D(
            regionX: drainContX,
            regionY: snap(c.contEnc, grid: c.grid),
            regionHeight: activeW - 2 * c.contEnc,
            contSize: c.contSize,
            contSpacing: c.contSpacing,
            contLayer: c.contID,
            grid: c.grid
        )
        shapes.append(contentsOf: drainContacts)

        // 6. M1 bars
        let sourceM1Rect = LayoutRect(
            origin: LayoutPoint(x: snap(sourceContX - c.m1Enc, grid: c.grid), y: 0),
            size: LayoutSize(width: snap(c.m1Width, grid: c.grid), height: activeW)
        )
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(sourceM1Rect)))

        let drainM1Rect = LayoutRect(
            origin: LayoutPoint(x: snap(drainContX - c.m1Enc, grid: c.grid), y: 0),
            size: LayoutSize(width: snap(c.m1Width, grid: c.grid), height: activeW)
        )
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(drainM1Rect)))

        // 7. Gate M1 + contact
        let gateContY: Double
        if c.isPMOS {
            gateContY = snap(-c.polyExtension + c.polyContEnc, grid: c.grid)
        } else {
            gateContY = snap(activeW + c.polyExtension - c.polyContEnc - c.contSize, grid: c.grid)
        }
        let gateM1Rect = LayoutRect(
            origin: LayoutPoint(x: polyRect.origin.x, y: gateContY),
            size: LayoutSize(width: polyRect.size.width, height: snap(c.m1Width, grid: c.grid))
        )
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(gateM1Rect)))

        if let pcd = c.polyContDef {
            let gateContRect = LayoutRect(
                origin: LayoutPoint(
                    x: snap(polyRect.origin.x + (polyRect.size.width - pcd.cutSize.width) / 2, grid: c.grid),
                    y: snap(gateContY + (c.m1Width - pcd.cutSize.height) / 2, grid: c.grid)
                ),
                size: pcd.cutSize
            )
            shapes.append(LayoutShape(layer: c.contID, geometry: .rect(gateContRect)))
        }

        // 8. Well/Substrate tap
        let tapSpacing = snap(max(c.activeRules.minSpacing, 2 * c.impEnclosure + c.grid), grid: c.grid)
        let tapHeight = snap(c.contSize + 2 * c.contEnc, grid: c.grid)

        let tapY: Double
        if c.isPMOS {
            tapY = snap(activeW + tapSpacing, grid: c.grid)
        } else {
            tapY = snap(-tapSpacing - tapHeight, grid: c.grid)
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
            let nwellEnc = c.tech.enclosureRule(outer: nwellID, inner: c.activeID)?.minEnclosure ?? 0.18
            let combinedRect = activeRect.union(tapActiveRect)
            let nwellRect = combinedRect.expanded(by: nwellEnc, nwellEnc)
            shapes.append(LayoutShape(layer: nwellID, geometry: .rect(nwellRect)))
        }

        // 10. Pins
        pins.append(LayoutPin(
            name: "source",
            position: sourceM1Rect.center,
            size: LayoutSize(width: c.m1Width, height: activeW),
            layer: c.m1ID,
            role: .source
        ))
        pins.append(LayoutPin(
            name: "drain",
            position: drainM1Rect.center,
            size: LayoutSize(width: c.m1Width, height: activeW),
            layer: c.m1ID,
            role: .drain
        ))
        pins.append(LayoutPin(
            name: "gate",
            position: gateM1Rect.center,
            size: gateM1Rect.size,
            layer: c.m1ID,
            role: .gate
        ))
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

    // MARK: - Multi-Finger Generation

    /// Generates a multi-finger MOSFET cell (nf > 1).
    ///
    /// Layout structure (left to right):
    /// ```
    /// [SourceContacts][Gate0][SharedSD][Gate1]...[GateN-1][DrainContacts]
    /// ```
    ///
    /// Between each pair of adjacent gate fingers there is a shared source/drain
    /// diffusion region with contacts. The leftmost S/D region is always source,
    /// the rightmost is always drain. Intermediate shared regions alternate:
    /// index 0 = source (left edge), index 1 = drain, index 2 = source, ...
    ///
    /// All gate poly fingers are connected by a horizontal M1 bus bar placed
    /// outside the ACTIVE region (above for NMOS, below for PMOS), with one
    /// contact per finger landing on the bus bar.
    private func generateMultiFinger(
        context c: MOSFETContext,
        deviceKindID: String,
        instanceName: String
    ) -> LayoutCell {
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
            let polyRect: LayoutRect
            if c.isPMOS {
                polyRect = LayoutRect(
                    origin: LayoutPoint(x: px, y: -c.polyExtension),
                    size: LayoutSize(width: snappedL, height: activeW + c.polyExtension + c.polyRules.minWidth)
                )
            } else {
                polyRect = LayoutRect(
                    origin: LayoutPoint(x: px, y: -c.polyRules.minWidth),
                    size: LayoutSize(width: snappedL, height: activeW + c.polyExtension + c.polyRules.minWidth)
                )
            }
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
            shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(m1Rect)))

            // Classify: even indices are source, odd indices are drain
            // (index 0 = source edge, index 1 = drain, index 2 = source, ...)
            if i % 2 == 0 {
                sourceM1Rects.append(m1Rect)
            } else {
                drainM1Rects.append(m1Rect)
            }
        }

        // 5. Source M1 bus bar connecting all source M1 fingers
        let sourceM1Bus: LayoutRect
        if sourceM1Rects.count == 1 {
            sourceM1Bus = sourceM1Rects[0]
        } else {
            let leftmostX = sourceM1Rects.map(\.origin.x).min()!
            let rightmostMaxX = sourceM1Rects.map(\.maxX).max()!
            sourceM1Bus = LayoutRect(
                origin: LayoutPoint(x: snap(leftmostX, grid: c.grid), y: 0),
                size: LayoutSize(
                    width: snap(rightmostMaxX - leftmostX, grid: c.grid),
                    height: snap(c.m1Width, grid: c.grid)
                )
            )
            shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(sourceM1Bus)))
        }

        // 6. Drain M1 bus bar connecting all drain M1 fingers
        let drainM1Bus: LayoutRect
        if drainM1Rects.count == 1 {
            drainM1Bus = drainM1Rects[0]
        } else {
            let leftmostX = drainM1Rects.map(\.origin.x).min()!
            let rightmostMaxX = drainM1Rects.map(\.maxX).max()!
            drainM1Bus = LayoutRect(
                origin: LayoutPoint(
                    x: snap(leftmostX, grid: c.grid),
                    y: snap(activeW - c.m1Width, grid: c.grid)
                ),
                size: LayoutSize(
                    width: snap(rightmostMaxX - leftmostX, grid: c.grid),
                    height: snap(c.m1Width, grid: c.grid)
                )
            )
            shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(drainM1Bus)))
        }

        // 7. Gate contacts and gate bus bar
        //    Position: outside ACTIVE, on the side away from the tap.
        //    NMOS: gate contacts above active (tap is below)
        //    PMOS: gate contacts below active (tap is above)
        let gateContY: Double
        if c.isPMOS {
            gateContY = snap(-c.polyExtension + c.polyContEnc, grid: c.grid)
        } else {
            gateContY = snap(activeW + c.polyExtension - c.polyContEnc - c.contSize, grid: c.grid)
        }

        // Gate bus bar spans from leftmost poly to rightmost poly
        let gateBusLeftX = snap(polyXPositions.first!, grid: c.grid)
        let gateBusRightX = snap(polyXPositions.last! + snappedL, grid: c.grid)
        let gateBusM1Rect = LayoutRect(
            origin: LayoutPoint(x: gateBusLeftX, y: gateContY),
            size: LayoutSize(
                width: snap(gateBusRightX - gateBusLeftX, grid: c.grid),
                height: snap(c.m1Width, grid: c.grid)
            )
        )
        shapes.append(LayoutShape(layer: c.m1ID, geometry: .rect(gateBusM1Rect)))

        // One contact per poly finger on the bus bar
        if let pcd = c.polyContDef {
            for i in 0..<nf {
                let px = polyXPositions[i]
                let gateContRect = LayoutRect(
                    origin: LayoutPoint(
                        x: snap(px + (snappedL - pcd.cutSize.width) / 2, grid: c.grid),
                        y: snap(gateContY + (c.m1Width - pcd.cutSize.height) / 2, grid: c.grid)
                    ),
                    size: pcd.cutSize
                )
                shapes.append(LayoutShape(layer: c.contID, geometry: .rect(gateContRect)))
            }
        }

        // 8. Well/Substrate tap
        let tapSpacing = snap(max(c.activeRules.minSpacing, 2 * c.impEnclosure + c.grid), grid: c.grid)
        let tapHeight = snap(c.contSize + 2 * c.contEnc, grid: c.grid)

        let tapY: Double
        if c.isPMOS {
            tapY = snap(activeW + tapSpacing, grid: c.grid)
        } else {
            tapY = snap(-tapSpacing - tapHeight, grid: c.grid)
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
            let nwellEnc = c.tech.enclosureRule(outer: nwellID, inner: c.activeID)?.minEnclosure ?? 0.18
            let combinedRect = activeRect.union(tapActiveRect)
            let nwellRect = combinedRect.expanded(by: nwellEnc, nwellEnc)
            shapes.append(LayoutShape(layer: nwellID, geometry: .rect(nwellRect)))
        }

        // 10. Pins
        // Source pin: center of the source bus bar (or the single source M1 bar)
        let sourcePinRect = sourceM1Rects.count > 1 ? sourceM1Bus : sourceM1Rects[0]
        pins.append(LayoutPin(
            name: "source",
            position: sourcePinRect.center,
            size: sourcePinRect.size,
            layer: c.m1ID,
            role: .source
        ))

        // Drain pin: center of the drain bus bar (or the single drain M1 bar)
        let drainPinRect = drainM1Rects.count > 1 ? drainM1Bus : drainM1Rects[0]
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
