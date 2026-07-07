import Foundation
import LayoutCore

/// Connectivity verdict of one diagnosed cell, in the terms an agent needs to
/// decide the next routing step: per declared net whether it is whole, and for
/// every open net WHERE the disconnected geometry sits (island footprints) and
/// the shortest suggested connections between the pieces (flylines).
public struct LayoutConnectivityDiagnosisReport: Codable, Sendable, Equatable {
    /// Cell the analysis flattened, resolved like `--inspect-document`.
    public let topCellID: UUID
    public let totals: LayoutConnectivityDiagnosisTotals
    /// One row per declared net observed in the design, sorted by name then ID.
    public let nets: [LayoutConnectivityNetDiagnosis]
    /// Detail for every open net, in canonical net-ID order.
    public let opens: [LayoutConnectivityOpenDiagnosis]
    /// Conductor pieces carrying geometry of two or more declared nets.
    public let shorts: [LayoutConnectivityShortDiagnosis]

    public init(
        topCellID: UUID,
        totals: LayoutConnectivityDiagnosisTotals,
        nets: [LayoutConnectivityNetDiagnosis],
        opens: [LayoutConnectivityOpenDiagnosis],
        shorts: [LayoutConnectivityShortDiagnosis]
    ) {
        self.topCellID = topCellID
        self.totals = totals
        self.nets = nets
        self.opens = opens
        self.shorts = shorts
    }
}

public struct LayoutConnectivityDiagnosisTotals: Codable, Sendable, Equatable {
    /// Number of declared-net rows in `nets`.
    public let netCount: Int
    /// Number of electrically connected conductor pieces found by extraction,
    /// including floating metal with no declared net.
    public let extractedNetCount: Int
    public let openCount: Int
    public let shortCount: Int

    public init(netCount: Int, extractedNetCount: Int, openCount: Int, shortCount: Int) {
        self.netCount = netCount
        self.extractedNetCount = extractedNetCount
        self.openCount = openCount
        self.shortCount = shortCount
    }
}

public struct LayoutConnectivityNetDiagnosis: Codable, Sendable, Equatable {
    /// Declared document net ID.
    public let netID: UUID
    /// Declared net name; nil when the ID appears in geometry but no cell
    /// declares a net with that ID.
    public let name: String?
    /// Number of disconnected conductor pieces carrying this net's geometry.
    /// 1 means fully connected, 0 means the net has no geometry at all.
    public let islandCount: Int
    /// True exactly when `islandCount >= 2`, matching the extractor's opens.
    public let isOpen: Bool
    /// Flattened pins bound to this net.
    public let pinCount: Int
    /// Occurrence-exact conductor footprints across all islands of this net.
    public let footprintCount: Int

    public init(
        netID: UUID,
        name: String?,
        islandCount: Int,
        isOpen: Bool,
        pinCount: Int,
        footprintCount: Int
    ) {
        self.netID = netID
        self.name = name
        self.islandCount = islandCount
        self.isOpen = isOpen
        self.pinCount = pinCount
        self.footprintCount = footprintCount
    }
}

public struct LayoutConnectivityOpenDiagnosis: Codable, Sendable, Equatable {
    public let netID: UUID
    public let name: String?
    /// The disconnected conductor pieces; flyline island indices refer into
    /// this array.
    public let islands: [LayoutConnectivityIslandDiagnosis]
    /// Minimum spanning tree of suggested connections over `islands`.
    public let flylines: [LayoutConnectivityFlylineDiagnosis]

    public init(
        netID: UUID,
        name: String?,
        islands: [LayoutConnectivityIslandDiagnosis],
        flylines: [LayoutConnectivityFlylineDiagnosis]
    ) {
        self.netID = netID
        self.name = name
        self.islands = islands
        self.flylines = flylines
    }
}

public struct LayoutConnectivityIslandDiagnosis: Codable, Sendable, Equatable {
    /// Position of this island in the open net's island list.
    public let islandIndex: Int
    public let boundingBox: LayoutRect
    public let shapeCount: Int
    public let viaCount: Int
    /// Occurrence-exact member geometry (layer + rect) — the rectangles a
    /// route must land on to join this island.
    public let footprints: [LayoutConnectivityFootprintDiagnosis]

    public init(
        islandIndex: Int,
        boundingBox: LayoutRect,
        shapeCount: Int,
        viaCount: Int,
        footprints: [LayoutConnectivityFootprintDiagnosis]
    ) {
        self.islandIndex = islandIndex
        self.boundingBox = boundingBox
        self.shapeCount = shapeCount
        self.viaCount = viaCount
        self.footprints = footprints
    }
}

public struct LayoutConnectivityFootprintDiagnosis: Codable, Sendable, Equatable {
    public let layer: LayoutLayerID
    public let boundingBox: LayoutRect

    public init(layer: LayoutLayerID, boundingBox: LayoutRect) {
        self.layer = layer
        self.boundingBox = boundingBox
    }
}

public struct LayoutConnectivityFlylineDiagnosis: Codable, Sendable, Equatable {
    public let fromIslandIndex: Int
    public let toIslandIndex: Int
    public let start: LayoutPoint
    public let end: LayoutPoint
    /// Euclidean gap between the two islands; zero when they touch only
    /// across layers (stacked without a via).
    public let length: Double
    /// Layers of the from-island footprints under `start`, sorted; empty when
    /// the endpoint sits on a via body rather than routed conductor.
    public let startLayers: [LayoutLayerID]
    /// Layers of the to-island footprints under `end`, sorted.
    public let endLayers: [LayoutLayerID]

    public init(
        fromIslandIndex: Int,
        toIslandIndex: Int,
        start: LayoutPoint,
        end: LayoutPoint,
        length: Double,
        startLayers: [LayoutLayerID],
        endLayers: [LayoutLayerID]
    ) {
        self.fromIslandIndex = fromIslandIndex
        self.toIslandIndex = toIslandIndex
        self.start = start
        self.end = end
        self.length = length
        self.startLayers = startLayers
        self.endLayers = endLayers
    }
}

public struct LayoutConnectivityShortDiagnosis: Codable, Sendable, Equatable {
    /// The shorted declared nets, in canonical order, always at least two.
    public let nets: [LayoutConnectivityNetReference]
    /// Bounding box of the shorting conductor piece.
    public let region: LayoutRect
    public let shapeCount: Int
    public let viaCount: Int

    public init(
        nets: [LayoutConnectivityNetReference],
        region: LayoutRect,
        shapeCount: Int,
        viaCount: Int
    ) {
        self.nets = nets
        self.region = region
        self.shapeCount = shapeCount
        self.viaCount = viaCount
    }
}

public struct LayoutConnectivityNetReference: Codable, Sendable, Equatable {
    public let netID: UUID
    public let name: String?

    public init(netID: UUID, name: String?) {
        self.netID = netID
        self.name = name
    }
}
