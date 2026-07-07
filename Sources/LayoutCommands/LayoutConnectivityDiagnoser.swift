import Foundation
import LayoutCore
import LayoutTech
import LayoutVerify

/// Builds a `LayoutConnectivityDiagnosisReport` from the batch connectivity
/// extraction used by verification — the same engine the editor's live
/// verdicts are verified against — so the CLI diagnosis can never disagree
/// with the interactive tool.
public struct LayoutConnectivityDiagnoser: Sendable {
    public init() {}

    /// Diagnoses one cell of the document (the document top cell, or its
    /// first cell when none is marked top, mirroring `--inspect-document`).
    public func diagnose(
        document: LayoutDocument,
        tech: LayoutTechDatabase
    ) throws -> LayoutConnectivityDiagnosisReport {
        guard let topCellID = document.topCellID ?? document.cells.first?.id else {
            throw LayoutConnectivityExtractionError.targetCellNotFound
        }
        let extractor = LayoutConnectivityExtractor()
        let analysis = try extractor.extract(document: document, tech: tech, cellID: topCellID)
        let conductors = try extractor.flattenedConductors(document: document, tech: tech, cellID: topCellID)
        let nameByNetID = Self.netNames(document: document)

        return LayoutConnectivityDiagnosisReport(
            topCellID: topCellID,
            totals: LayoutConnectivityDiagnosisTotals(
                netCount: Self.observedNetIDs(document: document, topCellID: topCellID, analysis: analysis).count,
                extractedNetCount: analysis.nets.count,
                openCount: analysis.opens.count,
                shortCount: analysis.shorts.count
            ),
            nets: Self.netRows(
                document: document,
                topCellID: topCellID,
                analysis: analysis,
                pins: conductors.pins,
                nameByNetID: nameByNetID
            ),
            opens: analysis.opens.map { open in
                Self.openDiagnosis(open, nameByNetID: nameByNetID)
            },
            shorts: analysis.shorts.map { short in
                LayoutConnectivityShortDiagnosis(
                    nets: short.netIDs.map {
                        LayoutConnectivityNetReference(netID: $0, name: nameByNetID[$0])
                    },
                    region: short.region,
                    shapeCount: short.shapeIDs.count,
                    viaCount: short.viaIDs.count
                )
            }
        )
    }

    // MARK: - Per-net rows

    /// Declared nets worth a row: every net declared on the diagnosed cell
    /// (even with no geometry yet) plus every net ID the extraction observed
    /// in geometry or pins (child-cell declarations surface here).
    private static func observedNetIDs(
        document: LayoutDocument,
        topCellID: UUID,
        analysis: ConnectivityAnalysis
    ) -> Set<UUID> {
        var netIDs = Set((document.cell(withID: topCellID)?.nets ?? []).map(\.id))
        for net in analysis.nets {
            netIDs.formUnion(net.declaredNetIDs)
        }
        return netIDs
    }

    private static func netRows(
        document: LayoutDocument,
        topCellID: UUID,
        analysis: ConnectivityAnalysis,
        pins: [LayoutPin],
        nameByNetID: [UUID: String]
    ) -> [LayoutConnectivityNetDiagnosis] {
        var pinCounts: [UUID: Int] = [:]
        for pin in pins {
            guard let netID = pin.netID else { continue }
            pinCounts[netID, default: 0] += 1
        }
        var islandCounts: [UUID: Int] = [:]
        var footprintCounts: [UUID: Int] = [:]
        for net in analysis.nets {
            for netID in net.declaredNetIDs {
                islandCounts[netID, default: 0] += 1
                footprintCounts[netID, default: 0] += net.memberFootprints.count
            }
        }
        return observedNetIDs(document: document, topCellID: topCellID, analysis: analysis)
            .map { netID in
                let islandCount = islandCounts[netID] ?? 0
                return LayoutConnectivityNetDiagnosis(
                    netID: netID,
                    name: nameByNetID[netID],
                    islandCount: islandCount,
                    isOpen: islandCount >= 2,
                    pinCount: pinCounts[netID] ?? 0,
                    footprintCount: footprintCounts[netID] ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return (lhs.name ?? "") < (rhs.name ?? "")
                }
                return lhs.netID.uuidString < rhs.netID.uuidString
            }
    }

    // MARK: - Opens

    private static func openDiagnosis(
        _ open: ConnectivityOpen,
        nameByNetID: [UUID: String]
    ) -> LayoutConnectivityOpenDiagnosis {
        LayoutConnectivityOpenDiagnosis(
            netID: open.netID,
            name: nameByNetID[open.netID],
            islands: open.islands.enumerated().map { index, island in
                LayoutConnectivityIslandDiagnosis(
                    islandIndex: index,
                    boundingBox: island.boundingBox,
                    shapeCount: island.shapeIDs.count,
                    viaCount: island.viaIDs.count,
                    footprints: island.memberFootprints.map {
                        LayoutConnectivityFootprintDiagnosis(layer: $0.layer, boundingBox: $0.boundingBox)
                    }
                )
            },
            flylines: open.flylines.map { flyline in
                LayoutConnectivityFlylineDiagnosis(
                    fromIslandIndex: flyline.fromIslandIndex,
                    toIslandIndex: flyline.toIslandIndex,
                    start: flyline.start,
                    end: flyline.end,
                    length: flyline.length,
                    startLayers: endpointLayers(at: flyline.start, islandIndex: flyline.fromIslandIndex, open: open),
                    endLayers: endpointLayers(at: flyline.end, islandIndex: flyline.toIslandIndex, open: open)
                )
            }
        )
    }

    /// Layers of the island's conductor footprints under a flyline endpoint,
    /// sorted for determinism. Empty when the endpoint sits on a via body
    /// only, which carries no drawn layer.
    private static func endpointLayers(
        at point: LayoutPoint,
        islandIndex: Int,
        open: ConnectivityOpen
    ) -> [LayoutLayerID] {
        guard open.islands.indices.contains(islandIndex) else { return [] }
        let layers = Set(
            open.islands[islandIndex].memberFootprints
                .filter { $0.boundingBox.contains(point) }
                .map(\.layer)
        )
        return layers.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.purpose < rhs.purpose
        }
    }

    // MARK: - Names

    /// Net names across the whole document: flattened child geometry keeps
    /// child-declared net IDs, so their names resolve too. Duplicate IDs keep
    /// the first declaration in document order.
    private static func netNames(document: LayoutDocument) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for cell in document.cells {
            for net in cell.nets where names[net.id] == nil {
                names[net.id] = net.name
            }
        }
        return names
    }
}
