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
        let analysis = try extractor.extract(document: document, tech: tech, cellID: topCellID, electricalContext: .deviceAwareMOS)
        guard let snapshot = analysis.sourceSnapshot else {
            throw LayoutConnectivityExtractionError.missingSourceSnapshot
        }
        let nameByNetID = Self.netNames(document: document, snapshot: snapshot)

        return LayoutConnectivityDiagnosisReport(
            topCellID: topCellID,
            electricalContext: snapshot.electricalContext,
            sourceDocumentID: snapshot.hierarchy.documentID,
            occurrences: snapshot.hierarchy.occurrences,
            pins: snapshot.hierarchy.pins,
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
                pins: snapshot.pins,
                nameByNetID: nameByNetID
            ),
            opens: analysis.opens.map { open in
                Self.openDiagnosis(open, snapshot: snapshot, nameByNetID: nameByNetID)
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
    ) -> Set<LayoutConductorSnapshot.NetReference> {
        var netIDs = Set((document.cell(withID: topCellID)?.nets ?? []).compactMap {
            analysis.rootNetReference(for: $0.id)
        })
        for net in analysis.nets {
            netIDs.formUnion(net.declaredNets)
        }
        for pin in analysis.sourceSnapshot?.pins ?? [] {
            if let net = pin.declaredNet { netIDs.insert(net) }
        }
        return netIDs
    }

    private static func netRows(
        document: LayoutDocument,
        topCellID: UUID,
        analysis: ConnectivityAnalysis,
        pins: [LayoutConductorSnapshot.Pin],
        nameByNetID: [LayoutConductorSnapshot.NetReference: String]
    ) -> [LayoutConnectivityNetDiagnosis] {
        var pinCounts: [LayoutConductorSnapshot.NetReference: Int] = [:]
        for pin in pins {
            guard let netID = pin.declaredNet else { continue }
            pinCounts[netID, default: 0] += 1
        }
        var islandCounts: [LayoutConductorSnapshot.NetReference: Int] = [:]
        var footprintCounts: [LayoutConductorSnapshot.NetReference: Int] = [:]
        for net in analysis.nets {
            for netID in net.declaredNets {
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
                    isOpen: analysis.opens.contains { $0.netID == netID },
                    pinCount: pinCounts[netID] ?? 0,
                    footprintCount: footprintCounts[netID] ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return (lhs.name ?? "") < (rhs.name ?? "")
                }
                return lhs.netID < rhs.netID
            }
    }

    // MARK: - Opens

    private static func openDiagnosis(
        _ open: ConnectivityOpen,
        snapshot: LayoutConductorSnapshot,
        nameByNetID: [LayoutConductorSnapshot.NetReference: String]
    ) -> LayoutConnectivityOpenDiagnosis {
        LayoutConnectivityOpenDiagnosis(
            netID: open.netID,
            name: nameByNetID[open.netID],
            unconnectedPinIndices: open.unconnectedPinIndices.map { snapshot.pins[$0].sourcePinIndex },
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

    /// Names belong to resolved owning occurrences, including parent-bound nets.
    private static func netNames(
        document: LayoutDocument, snapshot: LayoutConductorSnapshot
    ) -> [LayoutConductorSnapshot.NetReference: String] {
        var names: [LayoutConductorSnapshot.NetReference: String] = [:]
        for (index, occurrence) in snapshot.hierarchy.occurrences.enumerated() {
            guard let cell = document.cell(withID: occurrence.sourceCellID) else { continue }
            for net in cell.nets {
                names[.init(occurrenceIndex: index, netID: net.id)] = net.name
            }
        }
        return names
    }
}
