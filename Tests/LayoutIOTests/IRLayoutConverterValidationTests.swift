import Foundation
import CircuiteFoundation
import Testing
import LayoutCore
import LayoutIR
import LayoutTech
@testable import LayoutIO

@Suite("IRLayoutConverter Validation")
struct IRLayoutConverterValidationTests {
    @Test func databaseUnitScaleRejectsInvalidValue() {
        #expect(throws: DatabaseUnitScaleError.self) {
            _ = try DatabaseUnitScale(databaseUnitsPerMicrometer: 0)
        }
    }

    @Test func checkedImportRejectsDuplicateCellNames() {
        let library = IRLibrary(
            name: "duplicate",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP"),
                IRCell(name: "TOP"),
            ]
        )

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().checkedImportLibrary(library, tech: .standard())
        }
    }

    @Test func checkedImportRejectsUnresolvedCellReference() {
        let library = IRLibrary(
            name: "missing-ref",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP", elements: [
                    .cellRef(IRCellRef(cellName: "MISSING", origin: IRPoint(x: 0, y: 0)))
                ])
            ]
        )

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().checkedImportLibrary(library, tech: .standard())
        }
    }

    @Test func checkedImportRejectsUnmappedLayer() {
        let library = IRLibrary(
            name: "unmapped-layer",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP", elements: [
                    .boundary(IRBoundary(
                        layer: 999,
                        datatype: 0,
                        points: [
                            IRPoint(x: 0, y: 0),
                            IRPoint(x: 100, y: 0),
                            IRPoint(x: 100, y: 100),
                            IRPoint(x: 0, y: 0),
                        ]
                    ))
                ])
            ]
        )

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().checkedImportLibrary(library, tech: .standard())
        }
    }

    @Test func checkedImportRejectsUnknownDEFRouteLayerName() {
        let library = IRLibrary(
            name: "unknown-def-layer",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP", elements: [
                    .path(IRPath(
                        layer: 1,
                        datatype: 0,
                        width: 100,
                        points: [
                            IRPoint(x: 0, y: 0),
                            IRPoint(x: 100, y: 0),
                        ],
                        properties: [
                            IRProperty(attribute: 0, value: "def.route.layerName=UNKNOWN_METAL")
                        ]
                    ))
                ])
            ]
        )

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().checkedImportLibrary(library, tech: .standard())
        }
    }

    @Test func checkedImportRejectsUnknownDEFRouteViaName() {
        let library = IRLibrary(
            name: "unknown-def-via",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP", elements: [
                    .path(IRPath(
                        layer: 1,
                        datatype: 0,
                        width: 100,
                        points: [
                            IRPoint(x: 0, y: 0),
                            IRPoint(x: 100, y: 0),
                        ],
                        properties: [
                            IRProperty(attribute: 0, value: "def.route.viaName=UNKNOWN_VIA")
                        ]
                    ))
                ])
            ]
        )

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().checkedImportLibrary(library, tech: .standard())
        }
    }

    @Test func checkedImportRejectsSpecialRouteViaWithoutPlacementPoint() {
        let library = IRLibrary(
            name: "orphan-special-route-via",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP", elements: [
                    .path(IRPath(
                        layer: 1,
                        datatype: 0,
                        width: 100,
                        points: [
                            IRPoint(x: 0, y: 0),
                            IRPoint(x: 100, y: 0),
                        ],
                        properties: [
                            IRProperty(attribute: 0, value: "def.route.kind=specialNet"),
                            IRProperty(attribute: 0, value: "def.route.specialPoints=*,*,*,VIA1"),
                        ]
                    ))
                ])
            ]
        )

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().checkedImportLibrary(library, tech: .standard())
        }
    }

    @Test func exportRejectsUnmappedShapeLayer() {
        let unknownLayer = LayoutLayerID(name: "M9", purpose: "drawing")
        let cell = LayoutCell(
            name: "TOP",
            shapes: [
                LayoutShape(
                    layer: unknownLayer,
                    geometry: .rect(LayoutRect(
                        origin: LayoutPoint(x: 0, y: 0),
                        size: LayoutSize(width: 1, height: 1)
                    ))
                )
            ]
        )
        let document = LayoutDocument(name: "unmapped", cells: [cell], topCellID: cell.id)

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().exportLibrary(document, tech: .standard())
        }
    }

    @Test func exportRejectsMissingInstanceTarget() {
        let instance = LayoutInstance(
            cellID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            name: "X0"
        )
        let cell = LayoutCell(name: "TOP", instances: [instance])
        let document = LayoutDocument(name: "missing-instance-target", cells: [cell], topCellID: cell.id)

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().exportLibrary(document, tech: .standard())
        }
    }

    @Test func exportRejectsNonFiniteCoordinates() {
        let cell = LayoutCell(
            name: "TOP",
            shapes: [
                LayoutShape(
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    geometry: .rect(LayoutRect(
                        origin: LayoutPoint(x: .nan, y: 0),
                        size: LayoutSize(width: 1, height: 1)
                    ))
                )
            ]
        )
        let document = LayoutDocument(name: "non-finite-coordinate", cells: [cell], topCellID: cell.id)

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().exportLibrary(document, tech: .standard())
        }
    }

    @Test func exportRejectsCoordinatesOutsideDBURange() {
        let cell = LayoutCell(
            name: "TOP",
            shapes: [
                LayoutShape(
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    geometry: .path(LayoutPath(
                        points: [
                            LayoutPoint(x: 0, y: 0),
                            LayoutPoint(x: Double(Int32.max) + 1, y: 0),
                        ],
                        width: 0.1
                    ))
                )
            ]
        )
        let document = LayoutDocument(name: "oversized-coordinate", cells: [cell], topCellID: cell.id)

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().exportLibrary(document, tech: .standard())
        }
    }

    @Test func exportRejectsNonFinitePathWidth() {
        let cell = LayoutCell(
            name: "TOP",
            shapes: [
                LayoutShape(
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    geometry: .path(LayoutPath(
                        points: [
                            LayoutPoint(x: 0, y: 0),
                            LayoutPoint(x: 1, y: 0),
                        ],
                        width: .infinity
                    ))
                )
            ]
        )
        let document = LayoutDocument(name: "non-finite-width", cells: [cell], topCellID: cell.id)

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().exportLibrary(document, tech: .standard())
        }
    }

    @Test func exportRejectsTechnologyLayerOutsideIRRange() {
        var tech = LayoutTechDatabase.standard()
        tech.layers[0].gdsLayer = Int(Int16.max) + 1
        let cell = LayoutCell(
            name: "TOP",
            shapes: [
                LayoutShape(
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    geometry: .rect(LayoutRect(
                        origin: LayoutPoint(x: 0, y: 0),
                        size: LayoutSize(width: 1, height: 1)
                    ))
                )
            ]
        )
        let document = LayoutDocument(name: "invalid-tech-layer", cells: [cell], topCellID: cell.id)

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutConverter().exportLibrary(document, tech: tech)
        }
    }
}
