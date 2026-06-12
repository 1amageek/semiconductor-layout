import Foundation
import LayoutCore

public struct LayoutLayerDefinition: Hashable, Sendable, Codable {
    public var id: LayoutLayerID
    public var displayName: String
    public var gdsLayer: Int
    public var gdsDatatype: Int
    public var color: LayoutColor
    public var fillPattern: LayoutFillPattern
    public var preferredDirection: LayoutPreferredDirection
    public var visibleByDefault: Bool
    /// Sheet resistance in ohms per square; nil means the layer's
    /// resistance is not modeled (estimates report it as unavailable,
    /// never as zero).
    public var sheetResistance: Double?
    /// Capacitance to substrate per area, fF/um^2.
    public var areaCapacitance: Double?
    /// Fringe capacitance per perimeter length, fF/um.
    public var fringeCapacitance: Double?
    /// Electromigration current-density limit, mA per um of wire width.
    public var maxCurrentDensity: Double?

    public init(
        id: LayoutLayerID,
        displayName: String,
        gdsLayer: Int,
        gdsDatatype: Int,
        color: LayoutColor,
        fillPattern: LayoutFillPattern = .solid,
        preferredDirection: LayoutPreferredDirection = .none,
        visibleByDefault: Bool = true,
        sheetResistance: Double? = nil,
        areaCapacitance: Double? = nil,
        fringeCapacitance: Double? = nil,
        maxCurrentDensity: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.gdsLayer = gdsLayer
        self.gdsDatatype = gdsDatatype
        self.color = color
        self.fillPattern = fillPattern
        self.preferredDirection = preferredDirection
        self.visibleByDefault = visibleByDefault
        self.sheetResistance = sheetResistance
        self.areaCapacitance = areaCapacitance
        self.fringeCapacitance = fringeCapacitance
        self.maxCurrentDensity = maxCurrentDensity
    }
}
