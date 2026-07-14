import Foundation
import LayoutCore
import LayoutTech

public protocol LayoutGeometryExtracting: Sendable {
    func extract(
        document: LayoutDocument,
        technology: LayoutTechDatabase,
        topCellID: UUID?,
        profile: LayoutExtractionProcessProfile,
        maximumObjectCount: Int
    ) throws -> LayoutExtractionIR
}
