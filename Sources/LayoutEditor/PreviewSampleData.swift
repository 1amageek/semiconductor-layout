import LayoutIR
import LayoutCore
import LayoutTech
import LayoutIO

/// Preview sample data: Fully-Differential Folded Cascode OTA (40 MOS devices)
///
/// Cell hierarchy (9 cells):
/// - NMOS: 2-finger NMOS with dummy gates
/// - PMOS: 2-finger PMOS with dummy gates + NWELL
/// - DECAP: MOS gate decoupling capacitor
/// - GUARD_RING: P-substrate guard ring
/// - FC_OTA: Folded Cascode OTA core (15 MOS)
/// - BIAS_GEN: Cascode bias generator (8 MOS)
/// - CMFB: Common-mode feedback (7 MOS)
/// - OUTPUT_BUF: Output buffer (4 MOS)
/// - TOP: Full chip assembly (+ 4 DECAP + GUARD_RING + pads)
enum PreviewSampleData {

    // MARK: - GDS Layer Constants (sampleProcess)

    private static let LY_M1: Int16 = 1
    private static let LY_M2: Int16 = 2
    private static let LY_VIA1: Int16 = 3
    private static let LY_NWELL: Int16 = 10
    private static let LY_ACTIVE: Int16 = 20
    private static let LY_POLY: Int16 = 30
    private static let LY_NIMP: Int16 = 40
    private static let LY_PIMP: Int16 = 41
    private static let LY_CONTACT: Int16 = 50

    // MARK: - Cell Pin Constants (relative to cell origin 0,0)
    // NMOS/PMOS cell: 1500 × 800 dbu

    /// Drain center X offset from cell origin
    private static let pinDX: Int32 = 750
    /// Source bus Y offset from cell origin
    private static let pinSY: Int32 = 400
    /// Cell height
    private static let cellH: Int32 = 800

    // MARK: - Geometry Helpers

    private static func rect(_ ly: Int16, _ x1: Int32, _ y1: Int32,
                              _ x2: Int32, _ y2: Int32) -> IRElement {
        .boundary(IRBoundary(layer: ly, datatype: 0, points: [
            IRPoint(x: x1, y: y1), IRPoint(x: x2, y: y1),
            IRPoint(x: x2, y: y2), IRPoint(x: x1, y: y2),
            IRPoint(x: x1, y: y1),
        ]))
    }

    private static func wire(_ ly: Int16, _ w: Int32,
                              _ pts: [(Int32, Int32)]) -> IRElement {
        .path(IRPath(
            layer: ly, datatype: 0,
            pathType: .halfWidthExtend, width: w,
            points: pts.map { IRPoint(x: $0.0, y: $0.1) }
        ))
    }

    private static func lbl(_ ly: Int16, _ x: Int32, _ y: Int32,
                             _ s: String) -> IRElement {
        .text(IRText(layer: ly, position: IRPoint(x: x, y: y), string: s))
    }

    private static func inst(_ cell: String, _ x: Int32, _ y: Int32,
                              mirror: Bool = false) -> IRElement {
        .cellRef(IRCellRef(
            cellName: cell, origin: IRPoint(x: x, y: y),
            transform: IRTransform(mirrorX: mirror)
        ))
    }

    /// Via1 centered at (cx, cy), 220×220
    private static func via1(_ cx: Int32, _ cy: Int32) -> IRElement {
        rect(LY_VIA1, cx - 110, cy - 110, cx + 110, cy + 110)
    }

    /// NMOS drain exit point (top of cell)
    private static func nDrain(_ px: Int32, _ py: Int32) -> (Int32, Int32) {
        (px + pinDX, py + cellH)
    }

    /// PMOS drain exit point (bottom of cell)
    private static func pDrain(_ px: Int32, _ py: Int32) -> (Int32, Int32) {
        (px + pinDX, py)
    }

    // MARK: - Leaf Cells

    /// NMOS 2-finger device (1500 × 800 dbu)
    /// Drain exits top at (750, 800). Source bus at y=400.
    private static func nmosCell() -> IRCell {
        var e: [IRElement] = []
        e.append(rect(LY_ACTIVE, 200, 150, 1300, 650))
        for cx: Int32 in [10, 410, 810, 1210] {
            e.append(rect(LY_POLY, cx, 0, cx + 180, 800))
        }
        e.append(rect(LY_NIMP, 60, 10, 1440, 790))
        e.append(rect(LY_CONTACT, 240, 290, 460, 510))   // Source L
        e.append(rect(LY_CONTACT, 640, 290, 860, 510))   // Drain
        e.append(rect(LY_CONTACT, 1040, 290, 1260, 510)) // Source R
        // M1 Source bus
        e.append(wire(LY_M1, 200, [(350, 400), (1150, 400)]))
        // M1 Drain stub (exits top)
        e.append(wire(LY_M1, 200, [(750, 400), (750, 800)]))
        return IRCell(name: "NMOS", elements: e)
    }

    /// PMOS 2-finger device (1500 × 800 dbu)
    /// Drain exits bottom at (750, 0). Source bus at y=400.
    private static func pmosCell() -> IRCell {
        var e: [IRElement] = []
        e.append(rect(LY_NWELL, 20, -30, 1480, 830))
        e.append(rect(LY_ACTIVE, 200, 150, 1300, 650))
        for cx: Int32 in [10, 410, 810, 1210] {
            e.append(rect(LY_POLY, cx, 0, cx + 180, 800))
        }
        e.append(rect(LY_PIMP, 60, 10, 1440, 790))
        e.append(rect(LY_CONTACT, 240, 290, 460, 510))
        e.append(rect(LY_CONTACT, 640, 290, 860, 510))
        e.append(rect(LY_CONTACT, 1040, 290, 1260, 510))
        // M1 Source bus
        e.append(wire(LY_M1, 200, [(350, 400), (1150, 400)]))
        // M1 Drain stub (exits bottom)
        e.append(wire(LY_M1, 200, [(750, 0), (750, 400)]))
        return IRCell(name: "PMOS", elements: e)
    }

    /// DECAP: MOS gate capacitor (1500 × 1500 dbu)
    private static func decapCell() -> IRCell {
        var e: [IRElement] = []
        e.append(rect(LY_ACTIVE, 200, 200, 1300, 1300))
        e.append(rect(LY_POLY, 200, 100, 1300, 1400))
        e.append(rect(LY_NIMP, 60, 60, 1440, 1440))
        var cx: Int32 = 250
        while cx + 220 <= 1250 {
            e.append(rect(LY_CONTACT, cx, 280, cx + 220, 500))
            e.append(rect(LY_CONTACT, cx, 1000, cx + 220, 1220))
            cx += 470
        }
        e.append(wire(LY_M1, 200, [(200, 390), (1300, 390)]))
        e.append(wire(LY_M1, 200, [(200, 1110), (1300, 1110)]))
        e.append(lbl(LY_M1, 750, 750, "CAP"))
        return IRCell(name: "DECAP", elements: e)
    }

    /// Guard ring: P-substrate
    private static func guardRingCell(innerW: Int32, innerH: Int32) -> IRCell {
        let rw: Int32 = 400
        let tw = innerW + 2 * rw
        let th = innerH + 2 * rw
        var e: [IRElement] = []
        e.append(rect(LY_ACTIVE, 0, 0, tw, rw))
        e.append(rect(LY_ACTIVE, 0, th - rw, tw, th))
        e.append(rect(LY_ACTIVE, 0, rw, rw, th - rw))
        e.append(rect(LY_ACTIVE, tw - rw, rw, tw, th - rw))
        e.append(rect(LY_NIMP, -140, -140, tw + 140, rw + 140))
        e.append(rect(LY_NIMP, -140, th - rw - 140, tw + 140, th + 140))
        e.append(rect(LY_NIMP, -140, rw, rw + 140, th - rw))
        e.append(rect(LY_NIMP, tw - rw - 140, rw, tw + 140, th - rw))
        var cx: Int32 = 90
        while cx + 220 < tw - 90 {
            e.append(rect(LY_CONTACT, cx, 90, cx + 220, 310))
            e.append(rect(LY_CONTACT, cx, th - 310, cx + 220, th - 90))
            cx += 500
        }
        var cy: Int32 = rw + 90
        while cy + 220 < th - rw - 90 {
            e.append(rect(LY_CONTACT, 90, cy, 310, cy + 220))
            e.append(rect(LY_CONTACT, tw - 310, cy, tw - 90, cy + 220))
            cy += 500
        }
        e.append(wire(LY_M1, 300, [(200, 200), (tw - 200, 200)]))
        e.append(wire(LY_M1, 300, [(200, th - 200), (tw - 200, th - 200)]))
        e.append(wire(LY_M1, 300, [(200, 200), (200, th - 200)]))
        e.append(wire(LY_M1, 300, [(tw - 200, 200), (tw - 200, th - 200)]))
        e.append(lbl(LY_M1, tw / 2, 200, "GND"))
        return IRCell(name: "GUARD_RING", elements: e)
    }

    // MARK: - Sub-Block Cells

    /// Folded Cascode OTA core (15 MOS: 6 PMOS top, 2+1 NMOS mid, 6 NMOS bot)
    private static func fcOtaCell() -> IRCell {
        var e: [IRElement] = []
        let sp: Int32 = 1700
        // 6 device columns
        let dx: [Int32] = (0..<6).map { Int32($0) * sp + 200 }

        // --- PMOS row at py --- [M5, M3D, M3, M4, M4D, M6]
        let py: Int32 = 6800
        for (i, name) in ["M5", "M3D", "M3", "M4", "M4D", "M6"].enumerated() {
            e.append(inst("PMOS", dx[i], py))
            e.append(lbl(LY_M1, dx[i] + pinDX, py - 300, name))
        }
        e.append(rect(LY_NWELL, 0, py - 200, dx[5] + 1500 + 100, py + cellH + 200))

        // --- Diff pair at dy --- [M1, M2]
        let dy: Int32 = 4200
        e.append(inst("NMOS", dx[2], dy))
        e.append(lbl(LY_M1, dx[2] + pinDX, dy + cellH + 200, "M1"))
        e.append(inst("NMOS", dx[3], dy))
        e.append(lbl(LY_M1, dx[3] + pinDX, dy + cellH + 200, "M2"))

        // --- Tail at ty --- [M0]
        let ty: Int32 = 3000
        let tailX = (dx[2] + dx[3]) / 2
        e.append(inst("NMOS", tailX, ty))
        e.append(lbl(LY_M1, tailX + pinDX, ty + cellH + 200, "M0"))

        // --- NMOS row at ny --- [M9, M7D, M7, M8, M8D, M10]
        let ny: Int32 = 800
        for (i, name) in ["M9", "M7D", "M7", "M8", "M8D", "M10"].enumerated() {
            e.append(inst("NMOS", dx[i], ny))
            e.append(lbl(LY_M1, dx[i] + pinDX, ny - 300, name))
        }

        // --- M1 Internal Routing ---

        // Diff pair shared source bus
        let diffSrcY = dy + pinSY
        e.append(wire(LY_M1, 200, [
            (dx[2] + 350, diffSrcY), (dx[3] + 1150, diffSrcY)
        ]))
        // Tail drain → diff source (vertical)
        let tailDrain = nDrain(tailX, ty)
        e.append(wire(LY_M1, 200, [
            tailDrain, (tailDrain.0, diffSrcY)
        ]))

        // PMOS cascode gate tie (M3-M4) via POLY at top of cells
        let pGateY = py + cellH
        e.append(wire(LY_POLY, 180, [
            (dx[2] + 500, pGateY), (dx[3] + 900, pGateY)
        ]))
        // PMOS load gate tie (M5-M6)
        e.append(wire(LY_POLY, 180, [
            (dx[0] + 500, pGateY), (dx[5] + 900, pGateY)
        ]))
        // NMOS cascode gate tie (M7-M8) via POLY at bottom of cells
        let nGateY = ny
        e.append(wire(LY_POLY, 180, [
            (dx[2] + 500, nGateY), (dx[3] + 900, nGateY)
        ]))
        // NMOS source gate tie (M9-M10)
        e.append(wire(LY_POLY, 180, [
            (dx[0] + 500, nGateY), (dx[5] + 900, nGateY)
        ]))

        // --- M2 Signal Routing ---
        let blockW = dx[5] + 1500 + 200

        // VOUTP: M3 drain (bottom) ↔ M7 drain (top) — vertical M2
        let vp = pDrain(dx[2], py)   // PMOS M3 drain exit
        let vpN = nDrain(dx[2], ny)  // NMOS M7 drain exit
        e.append(wire(LY_M2, 200, [vpN, vp]))
        e.append(via1(vpN.0, vpN.1))
        e.append(via1(vp.0, vp.1))
        e.append(lbl(LY_M2, vp.0 - 500, (vpN.1 + vp.1) / 2, "VOUTP"))

        // VOUTN: M4 drain ↔ M8 drain
        let vn = pDrain(dx[3], py)
        let vnN = nDrain(dx[3], ny)
        e.append(wire(LY_M2, 200, [vnN, vn]))
        e.append(via1(vnN.0, vnN.1))
        e.append(via1(vn.0, vn.1))
        e.append(lbl(LY_M2, vn.0 + 400, (vnN.1 + vn.1) / 2, "VOUTN"))

        // INP: M2 to M1 gate
        let inpX = dx[2] + 500
        e.append(wire(LY_M2, 200, [(inpX, dy - 500), (inpX, dy + cellH)]))
        e.append(via1(inpX, dy + pinSY))
        e.append(lbl(LY_M2, inpX, dy - 700, "INP"))

        // INM
        let inmX = dx[3] + 900
        e.append(wire(LY_M2, 200, [(inmX, dy - 500), (inmX, dy + cellH)]))
        e.append(via1(inmX, dy + pinSY))
        e.append(lbl(LY_M2, inmX, dy - 700, "INM"))

        // Power buses
        e.append(wire(LY_M2, 300, [(0, py + cellH + 400), (blockW, py + cellH + 400)]))
        e.append(lbl(LY_M2, blockW / 2, py + cellH + 400, "VDD"))
        e.append(wire(LY_M2, 300, [(0, 0), (blockW, 0)]))
        e.append(lbl(LY_M2, blockW / 2, 0, "GND"))

        return IRCell(name: "FC_OTA", elements: e)
    }

    /// Bias generator: 4 PMOS + 4 NMOS (8 MOS)
    private static func biasGenCell() -> IRCell {
        var e: [IRElement] = []
        let sp: Int32 = 1700
        let dx: [Int32] = (0..<4).map { Int32($0) * sp + 200 }

        // PMOS row
        let py: Int32 = 2200
        for (i, name) in ["BP_d", "BP_m", "BPC1", "BPC2"].enumerated() {
            e.append(inst("PMOS", dx[i], py))
            e.append(lbl(LY_M1, dx[i] + pinDX, py - 300, name))
        }
        e.append(rect(LY_NWELL, 0, py - 200, dx[3] + 1500 + 100, py + cellH + 200))

        // NMOS row
        let ny: Int32 = 600
        for (i, name) in ["BN_d", "BN_m", "BNC1", "BNC2"].enumerated() {
            e.append(inst("NMOS", dx[i], ny))
            e.append(lbl(LY_M1, dx[i] + pinDX, ny + cellH + 200, name))
        }

        let blockW = dx[3] + 1500 + 200

        // POLY gate ties: mirror pairs (top of cell row)
        let pGateY = py + cellH
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, pGateY), (dx[1] + 900, pGateY)]))
        e.append(wire(LY_POLY, 180, [(dx[2] + 500, pGateY), (dx[3] + 900, pGateY)]))
        let nGateY = ny
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, nGateY), (dx[1] + 900, nGateY)]))
        e.append(wire(LY_POLY, 180, [(dx[2] + 500, nGateY), (dx[3] + 900, nGateY)]))

        // M2 vertical: NMOS drain → PMOS drain + VIA1 (centered on drain exits)
        for i in 0..<4 {
            let nd = nDrain(dx[i], ny)   // NMOS drain exit (top)
            let pd = pDrain(dx[i], py)   // PMOS drain exit (bottom)
            e.append(wire(LY_M2, 200, [nd, pd]))
            e.append(via1(nd.0, nd.1))
            e.append(via1(pd.0, pd.1))
        }

        // Power
        e.append(wire(LY_M2, 300, [(0, py + cellH + 400), (blockW, py + cellH + 400)]))
        e.append(lbl(LY_M2, blockW / 2, py + cellH + 400, "VDD"))
        e.append(wire(LY_M2, 300, [(0, 0), (blockW, 0)]))
        e.append(lbl(LY_M2, blockW / 2, 0, "GND"))

        e.append(lbl(LY_M2, dx[0] + pinDX, (ny + py) / 2, "VBIAS_N"))
        e.append(lbl(LY_M2, dx[2] + pinDX, (ny + py) / 2, "VBIAS_C"))

        return IRCell(name: "BIAS_GEN", elements: e)
    }

    /// Common-mode feedback: 2 PMOS + 5 NMOS (7 MOS)
    private static func cmfbCell() -> IRCell {
        var e: [IRElement] = []
        let sp: Int32 = 1700
        let dx: [Int32] = (0..<5).map { Int32($0) * sp + 200 }

        // PMOS load pair (columns 1 and 3)
        let py: Int32 = 2200
        e.append(inst("PMOS", dx[1], py))
        e.append(lbl(LY_M1, dx[1] + pinDX, py - 300, "CL"))
        e.append(inst("PMOS", dx[3], py))
        e.append(lbl(LY_M1, dx[3] + pinDX, py - 300, "CR"))
        e.append(rect(LY_NWELL, dx[1] - 100, py - 200, dx[3] + 1500 + 100, py + cellH + 200))

        // NMOS row: 5 devices
        let ny: Int32 = 600
        for (i, name) in ["D1L", "D1R", "TAIL", "D2L", "D2R"].enumerated() {
            e.append(inst("NMOS", dx[i], ny))
            e.append(lbl(LY_M1, dx[i] + pinDX, ny + cellH + 200, name))
        }

        let blockW = dx[4] + 1500 + 200

        // POLY gate ties
        let pGateY = py + cellH
        e.append(wire(LY_POLY, 180, [(dx[1] + 500, pGateY), (dx[3] + 900, pGateY)]))
        // Diff pair 1 gate sharing
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, ny), (dx[1] + 900, ny)]))
        // Diff pair 2 gate sharing
        e.append(wire(LY_POLY, 180, [(dx[3] + 500, ny), (dx[4] + 900, ny)]))

        // M1: All NMOS sources shared bus (→ tail)
        let srcBusY = ny + pinSY
        e.append(wire(LY_M1, 200, [(dx[0] + 350, srcBusY), (dx[4] + 1150, srcBusY)]))

        // M2: CL drain → D1R drain
        let clN = nDrain(dx[1], ny)
        let clP = pDrain(dx[1], py)
        e.append(wire(LY_M2, 200, [clN, clP]))
        e.append(via1(clN.0, clN.1))
        e.append(via1(clP.0, clP.1))

        // M2: CR drain → D2L drain
        let crN = nDrain(dx[3], ny)
        let crP = pDrain(dx[3], py)
        e.append(wire(LY_M2, 200, [crN, crP]))
        e.append(via1(crN.0, crN.1))
        e.append(via1(crP.0, crP.1))

        // VCMFB output (M2 vertical from middle)
        let cmfbOutX = (clP.0 + crP.0) / 2
        e.append(wire(LY_M2, 200, [(cmfbOutX, clP.1), (cmfbOutX, py + cellH + 400)]))
        e.append(via1(cmfbOutX, clP.1))
        e.append(lbl(LY_M2, cmfbOutX, py + cellH + 600, "VCMFB"))

        // Power
        e.append(wire(LY_M2, 300, [(0, py + cellH + 400), (blockW, py + cellH + 400)]))
        e.append(lbl(LY_M2, blockW / 2, py + cellH + 400, "VDD"))
        e.append(wire(LY_M2, 300, [(0, 0), (blockW, 0)]))
        e.append(lbl(LY_M2, blockW / 2, 0, "GND"))

        return IRCell(name: "CMFB", elements: e)
    }

    /// Output buffer: 2 source followers + 2 current sources (4 MOS)
    private static func outputBufCell() -> IRCell {
        var e: [IRElement] = []
        let sp: Int32 = 1700
        let dx: [Int32] = [200, sp + 200]

        // Source followers (top)
        let sy: Int32 = 1800
        e.append(inst("NMOS", dx[0], sy))
        e.append(lbl(LY_M1, dx[0] + pinDX, sy + cellH + 200, "SF_P"))
        e.append(inst("NMOS", dx[1], sy))
        e.append(lbl(LY_M1, dx[1] + pinDX, sy + cellH + 200, "SF_N"))

        // Current sources (bottom)
        let cy: Int32 = 600
        e.append(inst("NMOS", dx[0], cy))
        e.append(lbl(LY_M1, dx[0] + pinDX, cy - 300, "CS_P"))
        e.append(inst("NMOS", dx[1], cy))
        e.append(lbl(LY_M1, dx[1] + pinDX, cy - 300, "CS_N"))

        let blockW = dx[1] + 1500 + 200

        // M1: CS drain → SF source (vertical)
        let csDrain0 = nDrain(dx[0], cy)
        let csDrain1 = nDrain(dx[1], cy)
        e.append(wire(LY_M1, 200, [csDrain0, (csDrain0.0, sy + pinSY)]))
        e.append(wire(LY_M1, 200, [csDrain1, (csDrain1.0, sy + pinSY)]))

        // POLY: CS gate mirror
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, cy), (dx[1] + 900, cy)]))

        // M2 output + VIA1
        let sfDrain0 = nDrain(dx[0], sy)
        let sfDrain1 = nDrain(dx[1], sy)
        e.append(wire(LY_M2, 200, [sfDrain0, (sfDrain0.0, sfDrain0.1 + 600)]))
        e.append(via1(sfDrain0.0, sfDrain0.1))
        e.append(lbl(LY_M2, sfDrain0.0, sfDrain0.1 + 800, "OUT_P"))

        e.append(wire(LY_M2, 200, [sfDrain1, (sfDrain1.0, sfDrain1.1 + 600)]))
        e.append(via1(sfDrain1.0, sfDrain1.1))
        e.append(lbl(LY_M2, sfDrain1.0, sfDrain1.1 + 800, "OUT_N"))

        // GND
        e.append(wire(LY_M2, 300, [(0, 0), (blockW, 0)]))
        e.append(lbl(LY_M2, blockW / 2, 0, "GND"))

        return IRCell(name: "OUTPUT_BUF", elements: e)
    }

    // MARK: - Additional Blocks

    /// Bandgap voltage reference: 4 PMOS + 4 NMOS (8 MOS)
    private static func bandgapCell() -> IRCell {
        var e: [IRElement] = []
        let sp: Int32 = 1700
        let dx: [Int32] = (0..<4).map { Int32($0) * sp + 200 }

        let py: Int32 = 2200
        for (i, name) in ["BP1", "BP2", "BP3", "BP4"].enumerated() {
            e.append(inst("PMOS", dx[i], py))
            e.append(lbl(LY_M1, dx[i] + pinDX, py - 300, name))
        }
        e.append(rect(LY_NWELL, 0, py - 200, dx[3] + 1500 + 100, py + cellH + 200))

        let ny: Int32 = 600
        for (i, name) in ["BN1", "BN2", "BN3", "BN4"].enumerated() {
            e.append(inst("NMOS", dx[i], ny))
            e.append(lbl(LY_M1, dx[i] + pinDX, ny + cellH + 200, name))
        }

        let blockW = dx[3] + 1500 + 200

        // POLY gate ties
        let pGateY = py + cellH
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, pGateY), (dx[1] + 900, pGateY)]))
        e.append(wire(LY_POLY, 180, [(dx[2] + 500, pGateY), (dx[3] + 900, pGateY)]))
        let nGateY = ny
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, nGateY), (dx[1] + 900, nGateY)]))
        e.append(wire(LY_POLY, 180, [(dx[2] + 500, nGateY), (dx[3] + 900, nGateY)]))

        // M2 vertical drain connections
        for i in 0..<4 {
            let nd = nDrain(dx[i], ny)
            let pd = pDrain(dx[i], py)
            e.append(wire(LY_M2, 200, [nd, pd]))
            e.append(via1(nd.0, nd.1))
            e.append(via1(pd.0, pd.1))
        }

        // M1 cross-coupled core (columns 1↔2)
        let midY = (ny + cellH + py) / 2
        e.append(wire(LY_M1, 200, [nDrain(dx[1], ny), (dx[1] + pinDX, midY)]))
        e.append(wire(LY_M1, 200, [nDrain(dx[2], ny), (dx[2] + pinDX, midY)]))
        e.append(wire(LY_M1, 200, [(dx[1] + pinDX, midY), (dx[2] + pinDX, midY)]))

        // Power
        e.append(wire(LY_M2, 300, [(0, py + cellH + 400), (blockW, py + cellH + 400)]))
        e.append(lbl(LY_M2, blockW / 2, py + cellH + 400, "VDD"))
        e.append(wire(LY_M2, 300, [(0, 0), (blockW, 0)]))
        e.append(lbl(LY_M2, blockW / 2, 0, "GND"))
        e.append(lbl(LY_M2, blockW / 2, (ny + py) / 2, "VREF"))

        return IRCell(name: "BANDGAP", elements: e)
    }

    /// LDO regulator: 3 PMOS + 3 NMOS (6 MOS)
    private static func ldoCell() -> IRCell {
        var e: [IRElement] = []
        let sp: Int32 = 1700
        let dx: [Int32] = (0..<3).map { Int32($0) * sp + 200 }

        let py: Int32 = 2200
        for (i, name) in ["PASS", "REG1", "REG2"].enumerated() {
            e.append(inst("PMOS", dx[i], py))
            e.append(lbl(LY_M1, dx[i] + pinDX, py - 300, name))
        }
        e.append(rect(LY_NWELL, 0, py - 200, dx[2] + 1500 + 100, py + cellH + 200))

        let ny: Int32 = 600
        for (i, name) in ["ERR1", "ERR2", "IBIAS"].enumerated() {
            e.append(inst("NMOS", dx[i], ny))
            e.append(lbl(LY_M1, dx[i] + pinDX, ny + cellH + 200, name))
        }

        let blockW = dx[2] + 1500 + 200

        // POLY gate ties
        e.append(wire(LY_POLY, 180, [(dx[1] + 500, py + cellH), (dx[2] + 900, py + cellH)]))
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, ny), (dx[1] + 900, ny)]))

        // M2 vertical
        for i in 0..<3 {
            let nd = nDrain(dx[i], ny)
            let pd = pDrain(dx[i], py)
            e.append(wire(LY_M2, 200, [nd, pd]))
            e.append(via1(nd.0, nd.1))
            e.append(via1(pd.0, pd.1))
        }

        // Regulated output from PASS drain
        let passDrain = pDrain(dx[0], py)
        e.append(wire(LY_M2, 200, [passDrain, (passDrain.0, py - 600)]))
        e.append(lbl(LY_M2, passDrain.0, py - 800, "VREG"))

        // Power
        e.append(wire(LY_M2, 300, [(0, py + cellH + 400), (blockW, py + cellH + 400)]))
        e.append(lbl(LY_M2, blockW / 2, py + cellH + 400, "VDD"))
        e.append(wire(LY_M2, 300, [(0, 0), (blockW, 0)]))
        e.append(lbl(LY_M2, blockW / 2, 0, "GND"))

        return IRCell(name: "LDO", elements: e)
    }

    /// Startup circuit: 2 PMOS + 2 NMOS (4 MOS)
    private static func startupCell() -> IRCell {
        var e: [IRElement] = []
        let sp: Int32 = 1700
        let dx: [Int32] = [200, sp + 200]

        let py: Int32 = 2200
        e.append(inst("PMOS", dx[0], py))
        e.append(lbl(LY_M1, dx[0] + pinDX, py - 300, "SP1"))
        e.append(inst("PMOS", dx[1], py))
        e.append(lbl(LY_M1, dx[1] + pinDX, py - 300, "SP2"))
        e.append(rect(LY_NWELL, 0, py - 200, dx[1] + 1500 + 100, py + cellH + 200))

        let ny: Int32 = 600
        e.append(inst("NMOS", dx[0], ny))
        e.append(lbl(LY_M1, dx[0] + pinDX, ny + cellH + 200, "SN1"))
        e.append(inst("NMOS", dx[1], ny))
        e.append(lbl(LY_M1, dx[1] + pinDX, ny + cellH + 200, "SN2"))

        let blockW = dx[1] + 1500 + 200

        // POLY gate tie
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, py + cellH), (dx[1] + 900, py + cellH)]))

        // M2 vertical
        for i in 0..<2 {
            let nd = nDrain(dx[i], ny)
            let pd = pDrain(dx[i], py)
            e.append(wire(LY_M2, 200, [nd, pd]))
            e.append(via1(nd.0, nd.1))
            e.append(via1(pd.0, pd.1))
        }

        // Cross connection: SN1 drain → SP2 gate
        let sn1Drain = nDrain(dx[0], ny)
        e.append(wire(LY_M1, 200, [sn1Drain, (dx[1] + 500, sn1Drain.1)]))

        // Power
        e.append(wire(LY_M2, 300, [(0, py + cellH + 400), (blockW, py + cellH + 400)]))
        e.append(lbl(LY_M2, blockW / 2, py + cellH + 400, "VDD"))
        e.append(wire(LY_M2, 300, [(0, 0), (blockW, 0)]))
        e.append(lbl(LY_M2, blockW / 2, 0, "GND"))

        return IRCell(name: "STARTUP", elements: e)
    }

    /// ESD protection clamps: 6 NMOS (grounded-gate clamps)
    private static func esdClampCell() -> IRCell {
        var e: [IRElement] = []
        let sp: Int32 = 1700
        let dx: [Int32] = (0..<6).map { Int32($0) * sp + 200 }

        let ny: Int32 = 400
        for (i, name) in ["ESD1", "ESD2", "ESD3", "ESD4", "ESD5", "ESD6"].enumerated() {
            e.append(inst("NMOS", dx[i], ny))
            e.append(lbl(LY_M1, dx[i] + pinDX, ny + cellH + 200, name))
        }

        let blockW = dx[5] + 1500 + 200

        // All gates tied to GND (POLY bus)
        e.append(wire(LY_POLY, 180, [(dx[0] + 500, ny), (dx[5] + 900, ny)]))
        // All sources connected (M1 bus)
        e.append(wire(LY_M1, 200, [(dx[0] + 350, ny + pinSY), (dx[5] + 1150, ny + pinSY)]))

        // Drain → I/O via M2 stubs
        for i in 0..<6 {
            let nd = nDrain(dx[i], ny)
            e.append(wire(LY_M2, 200, [nd, (nd.0, nd.1 + 500)]))
            e.append(via1(nd.0, nd.1))
        }

        // GND bus
        e.append(wire(LY_M2, 300, [(0, 0), (blockW, 0)]))
        e.append(lbl(LY_M2, blockW / 2, 0, "GND"))

        return IRCell(name: "ESD_CLAMP", elements: e)
    }

    // MARK: - Top-Level Assembly

    private static func topCell() -> IRCell {
        var e: [IRElement] = []

        // Block placement
        let fcX: Int32 = 2000, fcY: Int32 = 2000
        e.append(inst("FC_OTA", fcX, fcY))
        e.append(lbl(LY_M2, fcX + 5200, fcY + 4000, "FC_OTA"))

        let biasX: Int32 = 14000, biasY: Int32 = 4000
        e.append(inst("BIAS_GEN", biasX, biasY))
        e.append(lbl(LY_M2, biasX + 3500, biasY + 1700, "BIAS"))

        let cmfbX: Int32 = 2000, cmfbY: Int32 = 12000
        e.append(inst("CMFB", cmfbX, cmfbY))
        e.append(lbl(LY_M2, cmfbX + 4350, cmfbY + 1700, "CMFB"))

        let bufX: Int32 = 14000, bufY: Int32 = 12000
        e.append(inst("OUTPUT_BUF", bufX, bufY))
        e.append(lbl(LY_M2, bufX + 1800, bufY + 1600, "BUF"))

        // BANDGAP (7000 × 3400) below BIAS_GEN
        let bgX: Int32 = 14000, bgY: Int32 = 8000
        e.append(inst("BANDGAP", bgX, bgY))
        e.append(lbl(LY_M2, bgX + 3500, bgY + 1700, "BANDGAP"))

        // STARTUP (3600 × 3400) right of BIAS_GEN
        let suX: Int32 = 21200, suY: Int32 = 4200
        e.append(inst("STARTUP", suX, suY))
        e.append(lbl(LY_M2, suX + 1800, suY + 1700, "STARTUP"))

        // LDO (5300 × 3400) right of OUTPUT_BUF
        let ldoX: Int32 = 18000, ldoY: Int32 = 12000
        e.append(inst("LDO", ldoX, ldoY))
        e.append(lbl(LY_M2, ldoX + 2650, ldoY + 1700, "LDO"))

        // ESD_CLAMP (10400 × 1700) below CMFB area
        let esdX: Int32 = 3000, esdY: Int32 = 16400
        e.append(inst("ESD_CLAMP", esdX, esdY))
        e.append(lbl(LY_M2, esdX + 5200, esdY + 600, "ESD"))

        // DECAPs at corners + gaps
        e.append(inst("DECAP", 600, 600))
        e.append(inst("DECAP", 600, 17500))
        e.append(inst("DECAP", 22500, 600))
        e.append(inst("DECAP", 22500, 17500))
        e.append(inst("DECAP", 11000, 10500))
        e.append(inst("DECAP", 21500, 10500))

        // Guard ring
        e.append(inst("GUARD_RING", 0, 0))

        // M2 power buses
        let chipW: Int32 = 25000
        let chipH: Int32 = 19500
        e.append(wire(LY_M2, 400, [(400, chipH - 400), (chipW - 400, chipH - 400)]))
        e.append(lbl(LY_M2, chipW / 2, chipH - 400, "VDD"))
        e.append(wire(LY_M2, 400, [(400, 400), (chipW - 400, 400)]))
        e.append(lbl(LY_M2, chipW / 2, 400, "GND"))

        // Vertical power straps
        for sx: Int32 in [3000, 9000, 13000, 19000] {
            e.append(wire(LY_M2, 200, [(sx, 400), (sx, chipH - 400)]))
            e.append(via1(sx, 400))
            e.append(via1(sx, chipH - 400))
        }

        // Bond pads (M2 along top)
        let padW: Int32 = 1500
        let padH: Int32 = 1200
        let padY = chipH + 400
        for (name, px) in [("INP", 600), ("INM", 3000), ("VOUTP", 5500),
                            ("VOUTN", 8000), ("VBIAS", 11000),
                            ("VDD", 16000), ("GND", 20000)] as [(String, Int32)] {
            e.append(rect(LY_M2, px, padY, px + padW, padY + padH))
            e.append(lbl(LY_M2, px + padW / 2, padY + padH / 2, name))
        }

        // Inter-block M2 routing

        // Bias → OTA (two horizontal routes)
        let biasNDrainY = biasY + 600 + cellH  // NMOS drain top in BIAS block
        e.append(wire(LY_M2, 200, [
            (biasX + 950, biasNDrainY),
            (fcX + 10400, biasNDrainY)
        ]))
        e.append(lbl(LY_M2, (biasX + fcX + 10400) / 2, biasNDrainY - 300, "VBIAS"))

        // CMFB → OTA (vertical in gap)
        let cmfbOutAbsX = cmfbX + 4350  // CMFB output X
        let cmfbTopY = cmfbY + 2200 + cellH + 400
        e.append(wire(LY_M2, 200, [
            (cmfbOutAbsX, fcY + 6800 + cellH + 400),
            (cmfbOutAbsX, cmfbTopY)
        ]))
        e.append(lbl(LY_M2, cmfbOutAbsX + 300, (fcY + 8000 + cmfbTopY) / 2, "VCMFB"))

        // OTA → BUF (L-shaped)
        let otaRightX = fcX + 10400
        let routeY: Int32 = 7000
        e.append(wire(LY_M2, 200, [
            (otaRightX, routeY),
            (bufX, routeY),
            (bufX, bufY + 1800 + pinSY)
        ]))

        // Bandgap → Bias (VREF distribution)
        e.append(wire(LY_M2, 200, [
            (bgX + 3500, bgY + 2200 + cellH + 400),
            (bgX + 3500, biasY + 0)
        ]))
        e.append(lbl(LY_M2, bgX + 3800, (bgY + biasY) / 2 + 2000, "VREF"))

        // Startup → Bias (enable)
        e.append(wire(LY_M2, 200, [
            (suX + 950, suY + 600 + cellH),
            (biasX + 6800, suY + 600 + cellH),
        ]))

        // LDO → power distribution
        e.append(wire(LY_M2, 200, [
            (ldoX + 950, ldoY + 2200),
            (ldoX + 950, ldoY - 600)
        ]))
        e.append(lbl(LY_M2, ldoX + 1200, ldoY + 800, "VREG"))

        // ESD → pads (short stubs to pad bus)
        let esdTopY = esdY + 400 + cellH + 500
        for i: Int32 in 0..<6 {
            let esdDevX = esdX + Int32(i) * 1700 + 200 + pinDX
            e.append(wire(LY_M2, 200, [
                (esdDevX, esdTopY),
                (esdDevX, esdTopY + 800)
            ]))
        }

        return IRCell(name: "TOP", elements: e)
    }

    // MARK: - Public Entry Point

    @MainActor
    static func buildFCOTALayout() throws -> (LayoutDocument, LayoutTechDatabase) {
        let tech = LayoutTechDatabase.sampleProcess()
        let guardRing = guardRingCell(innerW: 24200, innerH: 18700)

        let irLib = IRLibrary(
            name: "FC_OTA_LIB",
            databaseUnitScale: tech.units.scale,
            cells: [
                nmosCell(),
                pmosCell(),
                decapCell(),
                guardRing,
                fcOtaCell(),
                biasGenCell(),
                cmfbCell(),
                outputBufCell(),
                bandgapCell(),
                ldoCell(),
                startupCell(),
                esdClampCell(),
                topCell(),
            ]
        )

        let converter = IRLayoutConverter()
        let document = try converter.checkedImportLibrary(irLib, tech: tech)
        return (document, tech)
    }
}
