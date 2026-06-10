import Foundation
import LayoutCore
import LayoutTech

/// Inserts antenna jumpers: splits a violating-layer wire next to each
/// protected gate and bridges the gap on the next conductor layer up.
///
/// At the violating layer's etch stage the upper layer does not exist
/// yet, so the cut leaves only the short gate-side stub connected to the
/// gate; the accumulated charge of everything beyond the gap can no
/// longer reach the gate oxide. Once the upper layer is deposited the
/// bridge restores the net, so connectivity is unchanged.
///
/// The inserter performs local rectangle surgery only; whether the edit
/// actually clears the violation — and stays clean against spacing and
/// area rules — is decided by rerunning DRC on the edited document.
public struct AntennaJumperInserter {
    private static let tolerance = 1.0e-9

    public init() {}

    /// Applies the requests to `cellID`'s shapes inside `document`. Each
    /// gate position gets at most one jumper; gates that cannot be
    /// protected are returned as explicit failures.
    public func insert(
        requests: [AntennaJumperRequest],
        into document: inout LayoutDocument,
        cellID: UUID,
        tech: LayoutTechDatabase
    ) throws -> AntennaJumperResult {
        guard var cell = document.cell(withID: cellID) else {
            throw AutoGenError.antennaMitigationFailed(
                "target cell \(cellID) does not exist in document '\(document.name)'"
            )
        }

        var insertedJumpers = 0
        var failures: [AntennaJumperFailure] = []

        for request in requests {
            guard let rawViaDef = tech.vias.first(where: { $0.bottomLayer == request.layer }) else {
                failures.append(contentsOf: request.gates.map {
                    AntennaJumperFailure(
                        layer: request.layer,
                        gatePosition: $0.position,
                        reason: .noBridgeLayerAbove(request.layer)
                    )
                })
                continue
            }
            guard let bottomRules = tech.ruleSet(for: request.layer) else {
                failures.append(contentsOf: request.gates.map {
                    AntennaJumperFailure(
                        layer: request.layer,
                        gatePosition: $0.position,
                        reason: .missingLayerRules(request.layer)
                    )
                })
                continue
            }
            guard let topRules = tech.ruleSet(for: rawViaDef.topLayer) else {
                failures.append(contentsOf: request.gates.map {
                    AntennaJumperFailure(
                        layer: request.layer,
                        gatePosition: $0.position,
                        reason: .missingLayerRules(rawViaDef.topLayer)
                    )
                })
                continue
            }

            let viaDef = ViaLandingRule.sized(rawViaDef, bottomRules: bottomRules, topRules: topRules)
            let grid = tech.grid
            let bottomLanding = snapUp(viaDef.cutSize.width + 2 * viaDef.enclosure.bottom, grid: grid)
            let topLanding = snapUp(viaDef.cutSize.width + 2 * viaDef.enclosure.top, grid: grid)
            let gap = snapUp(max(bottomRules.minSpacing, grid), grid: grid)
            let shapeIDSet = Set(request.shapeIDs)

            for gate in request.gates {
                // Recompute candidates per gate: earlier jumpers in this
                // pass have already mutated the cell's shapes.
                let candidates = cell.shapes.indices.compactMap { index -> (index: Int, rect: LayoutRect)? in
                    let shape = cell.shapes[index]
                    guard shapeIDSet.contains(shape.id), shape.layer == request.layer else { return nil }
                    guard case .rect(let rect) = shape.geometry else { return nil }
                    return (index, rect)
                }.sorted {
                    distance(from: $0.rect, to: gate.position) < distance(from: $1.rect, to: gate.position)
                }

                var placed = false
                for candidate in candidates {
                    guard let surgery = jumperSurgery(
                        splitting: candidate.rect,
                        near: gate,
                        bottomLanding: bottomLanding,
                        topLanding: topLanding,
                        gap: gap,
                        grid: grid
                    ) else { continue }

                    let original = cell.shapes[candidate.index]
                    // The stub keeps the original shape ID so follow-up
                    // requests built from the same violation still find it.
                    var stub = original
                    stub.geometry = .rect(surgery.stub)
                    cell.shapes[candidate.index] = stub
                    cell.shapes.append(LayoutShape(
                        layer: original.layer, netID: original.netID, geometry: .rect(surgery.far)
                    ))
                    cell.shapes.append(LayoutShape(
                        layer: original.layer, netID: original.netID, geometry: .rect(surgery.stubPad)
                    ))
                    cell.shapes.append(LayoutShape(
                        layer: original.layer, netID: original.netID, geometry: .rect(surgery.farPad)
                    ))
                    cell.shapes.append(LayoutShape(
                        layer: viaDef.topLayer, netID: original.netID, geometry: .rect(surgery.bridge)
                    ))
                    cell.vias.append(LayoutVia(
                        viaDefinitionID: rawViaDef.id, position: surgery.stubVia, netID: original.netID
                    ))
                    cell.vias.append(LayoutVia(
                        viaDefinitionID: rawViaDef.id, position: surgery.farVia, netID: original.netID
                    ))

                    insertedJumpers += 1
                    placed = true
                    break
                }

                if !placed {
                    failures.append(AntennaJumperFailure(
                        layer: request.layer,
                        gatePosition: gate.position,
                        reason: .noSplittableWireNearGate
                    ))
                }
            }
        }

        document.updateCell(cell)
        return AntennaJumperResult(insertedJumpers: insertedJumpers, failures: failures)
    }

    // MARK: - Rectangle Surgery

    private struct JumperSurgery {
        var stub: LayoutRect
        var far: LayoutRect
        var stubPad: LayoutRect
        var farPad: LayoutRect
        var bridge: LayoutRect
        var stubVia: LayoutPoint
        var farVia: LayoutPoint
    }

    /// Splits `rect` near the end closest to the gate: a stub long enough
    /// to host a landing stays on the gate side, then a spacing gap, then
    /// the remainder — which must itself host a landing. The cut clears the
    /// gate pin's footprint: a cut straddled by the pin would leave the pin
    /// touching both pieces and reconnect the charge path. Returns nil when
    /// the wire is too short for that budget.
    private func jumperSurgery(
        splitting rect: LayoutRect,
        near gate: AntennaJumperGate,
        bottomLanding: Double,
        topLanding: Double,
        gap: Double,
        grid: Double
    ) -> JumperSurgery? {
        let horizontal = rect.size.width >= rect.size.height
        let start = horizontal ? rect.minX : rect.minY
        let end = horizontal ? rect.maxX : rect.maxY
        let gateAxis = horizontal ? gate.position.x : gate.position.y
        let gateHalf = (horizontal ? gate.size.width : gate.size.height) / 2
        let gateAtLowEnd = abs(gateAxis - start) <= abs(gateAxis - end)

        let stubCut: Double
        let farCut: Double
        if gateAtLowEnd {
            stubCut = snapUp(
                max(start + bottomLanding, gateAxis + gateHalf + grid),
                grid: grid
            )
            farCut = snapUp(stubCut + gap, grid: grid)
            guard end - farCut >= bottomLanding - Self.tolerance else { return nil }
        } else {
            stubCut = snapDown(
                min(end - bottomLanding, gateAxis - gateHalf - grid),
                grid: grid
            )
            farCut = snapDown(stubCut - gap, grid: grid)
            guard farCut - start >= bottomLanding - Self.tolerance else { return nil }
        }

        let crossCenter = snap(
            horizontal ? rect.center.y : rect.center.x,
            grid: grid
        )
        // Via axes snap away from the gap so each landing pad stays inside
        // its own piece instead of bulging into the isolation gap.
        let stubViaAxis = gateAtLowEnd
            ? snapDown(stubCut - bottomLanding / 2, grid: grid)
            : snapUp(stubCut + bottomLanding / 2, grid: grid)
        let farViaAxis = gateAtLowEnd
            ? snapUp(farCut + bottomLanding / 2, grid: grid)
            : snapDown(farCut - bottomLanding / 2, grid: grid)

        let stubSpan = gateAtLowEnd ? (start, stubCut) : (stubCut, end)
        let farSpan = gateAtLowEnd ? (farCut, end) : (start, farCut)
        let bridgeSpan = (
            min(stubViaAxis, farViaAxis) - topLanding / 2,
            max(stubViaAxis, farViaAxis) + topLanding / 2
        )

        func axisRect(span: (Double, Double), crossOrigin: Double, crossSize: Double) -> LayoutRect {
            if horizontal {
                return LayoutRect(
                    origin: LayoutPoint(x: span.0, y: crossOrigin),
                    size: LayoutSize(width: span.1 - span.0, height: crossSize)
                )
            }
            return LayoutRect(
                origin: LayoutPoint(x: crossOrigin, y: span.0),
                size: LayoutSize(width: crossSize, height: span.1 - span.0)
            )
        }
        func padRect(centeredAt axis: Double, side: Double) -> LayoutRect {
            axisRect(
                span: (axis - side / 2, axis + side / 2),
                crossOrigin: crossCenter - side / 2,
                crossSize: side
            )
        }
        func viaPoint(axis: Double) -> LayoutPoint {
            horizontal
                ? LayoutPoint(x: axis, y: crossCenter)
                : LayoutPoint(x: crossCenter, y: axis)
        }

        let crossOrigin = horizontal ? rect.minY : rect.minX
        let crossSize = horizontal ? rect.size.height : rect.size.width

        return JumperSurgery(
            stub: axisRect(span: stubSpan, crossOrigin: crossOrigin, crossSize: crossSize),
            far: axisRect(span: farSpan, crossOrigin: crossOrigin, crossSize: crossSize),
            stubPad: padRect(centeredAt: stubViaAxis, side: bottomLanding),
            farPad: padRect(centeredAt: farViaAxis, side: bottomLanding),
            bridge: axisRect(
                span: bridgeSpan,
                crossOrigin: crossCenter - topLanding / 2,
                crossSize: topLanding
            ),
            stubVia: viaPoint(axis: stubViaAxis),
            farVia: viaPoint(axis: farViaAxis)
        )
    }

    // MARK: - Helpers

    private func distance(from rect: LayoutRect, to point: LayoutPoint) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        guard grid > 0 else { return value }
        return (value / grid).rounded() * grid
    }

    private func snapUp(_ value: Double, grid: Double) -> Double {
        guard grid > 0 else { return value }
        return (value / grid).rounded(.up) * grid
    }

    private func snapDown(_ value: Double, grid: Double) -> Double {
        guard grid > 0 else { return value }
        return (value / grid).rounded(.down) * grid
    }
}
