import Foundation
import DEF
import LEF
import LayoutIR
import LayoutCore
import LayoutTech

/// Resolves retained source mask masters without synthesizing their geometry.
struct DEFMasterMaskComposer {
    let tech: LayoutTechDatabase

    func compose(_ defLibrary: IRLibrary, source: DEFDocument, mask: IRLibrary,
                 lef: LEFDocument?) throws -> IRLibrary {
        let units = mask.databaseUnitScale.databaseUnitsPerMicrometer
        guard units.isFinite, units > 0, units == source.dbuPerMicron,
              units == tech.units.scale.databaseUnitsPerMicrometer,
              let lef, lef.dbuPerMicron == units else {
            throw LayoutIOError.incompatibleStandardCellMask("DEF, mask, LEF and technology must have identical DBU scales")
        }
        let cells = Dictionary(grouping: mask.cells, by: \.name)
        var states: [String: Bool] = [:]
        var ordered: [IRCell] = []
        for name in Set(source.components.map(\.macro)).sorted() {
            var stack = [(name, false)]
            while let (current, expanded) = stack.popLast() {
                if expanded {
                    states[current] = true
                    guard let cell = cells[current]?.first else { throw failure("Missing admitted mask cell") }
                    ordered.append(cell)
                    continue
                }
                if let complete = states[current] {
                    guard complete else { throw failure("Cyclic master reference '\(current)'") }
                    continue
                }
                guard current != source.designName, let matches = cells[current], matches.count == 1,
                      let cell = matches.first else {
                    throw failure("Missing, duplicate or top-colliding mask master '\(current)'")
                }
                states[current] = false
                stack.append((current, true))
                for element in cell.elements.reversed() {
                    switch element {
                    case .cellRef(let ref):
                        try requireTransform(ref.transform)
                        stack.append((ref.cellName, false))
                    case .arrayRef(let ref):
                        try requireTransform(ref.transform)
                        stack.append((ref.cellName, false))
                    case .boundary(let boundary): try requireLayer(boundary.layer, boundary.datatype)
                    case .path(let path): try requireLayer(path.layer, path.datatype)
                    case .text(let text):
                        try requireLayer(text.layer, text.texttype)
                        // FIXME(INCOMPLETE_IMPLEMENTATION): LayoutLabel has no source text-pose field.
                        // Full-master DEF import must reject nonidentity text poses until the
                        // canonical model and standard exporters preserve their affine action.
                        guard text.transform == .identity else {
                            throw LayoutIOError.unsupportedStandardCellMask("Nonidentity source text pose is not represented")
                        }
                    case .via:
                        // FIXME(INCOMPLETE_IMPLEMENTATION): Retained mask bodies use standard mask geometry.
                        // DEF full-master import rejects typed route-via bodies until their raw mask
                        // shapes and all source layer footprints can be retained without projection.
                        throw LayoutIOError.unsupportedStandardCellMask("Typed route vias are not a retained GDS master body")
                    }
                }
            }
        }
        guard let top = defLibrary.cells.first, top.name == source.designName else {
            throw failure("DEF top cell is not uniquely identified")
        }
        var result = defLibrary
        result.cells = [top] + ordered
        return result
    }

    /// Closure cells precede their parents, so each body is measured once.
    func validateBounds(_ canonical: LayoutDocument, source: DEFDocument, lef: LEFDocument?) throws {
        let selected = Set(source.components.map(\.macro))
        var bounds: [UUID: LayoutRect] = [:]
        var physical: Set<UUID> = []
        for cell in canonical.cells where cell.id != canonical.topCellID {
            var box: LayoutRect?
            func add(_ candidate: LayoutRect) throws {
                guard [candidate.minX, candidate.minY, candidate.maxX, candidate.maxY].allSatisfy(\.isFinite),
                      candidate.size.width >= 0, candidate.size.height >= 0 else {
                    throw failure("Nonfinite or invalid mask bounds in '\(cell.name)'")
                }
                box = box.map { $0.union(candidate) } ?? candidate
            }
            for shape in cell.shapes {
                try add(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
                physical.insert(cell.id)
            }
            // FIXME(INCOMPLETE_IMPLEMENTATION): Property-encoded via projection may replace raw mask shapes.
            // Full-master import rejects that representation until every retained source footprint
            // can be verified without regenerating geometry from a technology master.
            guard cell.vias.isEmpty else {
                throw LayoutIOError.unsupportedStandardCellMask("Projected via geometry is not a retained raw mask body in '\(cell.name)'")
            }
            for label in cell.labels {
                try add(.init(origin: label.position, size: .zero))
            }
            for instance in cell.instances {
                if physical.contains(instance.cellID) { physical.insert(cell.id) }
                guard let child = bounds[instance.cellID] else { continue }
                let corners = child.toPolygon().points.map { instance.transform.apply(to: $0) }
                var transformed = LayoutGeometryAnalysis.boundingBox(for: LayoutPolygon(points: corners))
                if let repetition = instance.repetition {
                    let column = Double(repetition.columns - 1), row = Double(repetition.rows - 1)
                    let offsets = [LayoutPoint.zero,
                        .init(x: column * repetition.columnStep.x, y: column * repetition.columnStep.y),
                        .init(x: row * repetition.rowStep.x, y: row * repetition.rowStep.y),
                        .init(x: column * repetition.columnStep.x + row * repetition.rowStep.x,
                              y: column * repetition.columnStep.y + row * repetition.rowStep.y)]
                    let original = transformed
                    for offset in offsets.dropFirst() {
                        transformed = transformed.union(.init(
                            origin: .init(x: original.minX + offset.x, y: original.minY + offset.y), size: original.size))
                    }
                }
                try add(transformed)
            }
            if let box { bounds[cell.id] = box }
            if selected.contains(cell.name) {
                let matches = lef?.macros.filter { $0.name == cell.name } ?? []
                guard matches.count == 1, let master = matches.first,
                      let width = master.width, let height = master.height,
                      width.isFinite, height.isFinite, width > 0, height > 0,
                      physical.contains(cell.id), let box,
                      box.minX >= 0, box.minY >= 0, box.maxX <= width, box.maxY <= height else {
                    throw failure("Empty or out-of-SIZE mask body for '\(cell.name)'")
                }
            }
        }
    }

    static func exactPortShape(in cell: LayoutCell, rect: LayoutRect, layer: LayoutLayerID,
                               units: Double) throws -> Int {
        func grid(_ point: LayoutPoint) throws -> IRPoint {
            func coordinate(_ value: Double) throws -> Int32 {
                let scaled = value * units, rounded = scaled.rounded()
                guard scaled.isFinite, abs(scaled - rounded) <= scaled.ulp * 4,
                      let integer = Int32(exactly: rounded) else {
                    throw LayoutIOError.unsupportedSourcePin("Full-mask PORT is off the source DBU grid")
                }
                return integer
            }
            return try .init(x: coordinate(point.x), y: coordinate(point.y))
        }
        let corners = Set(try rect.toPolygon().points.map(grid))
        var matches: [Int] = []
        for index in cell.shapes.indices where cell.shapes[index].layer == layer {
            let points: [LayoutPoint]
            switch cell.shapes[index].geometry {
            case .rect(let actual): points = actual.toPolygon().points
            case .polygon(let polygon): points = polygon.points
            case .path: continue
            }
            guard points.count == 4 else { continue }
            let source = try points.map(grid)
            guard Set(source) == corners else { continue }
            let perimeter = source.indices.allSatisfy { index in
                let a = source[index], b = source[(index + 1) % 4]
                return (a.x == b.x) != (a.y == b.y)
            }
            if perimeter { matches.append(index) }
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Full-mask PORT coverage supports one exact source rectangle.
        // DEF master import must reject distributed, hierarchical-only or ambiguous metal until
        // a public exact coverage contract can preserve source geometry and terminal incidence.
        guard matches.count == 1, let index = matches.first else {
            throw LayoutIOError.unsupportedSourcePin("Full-mask PORT requires one exact top-level source metal rectangle in '\(cell.name)'")
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Source local-net aliases are not rebound by this profile.
        // Full-master import must reject existing bindings until their identity and terminal
        // role can be proved equal without overwriting source nets or joining distinct pins.
        guard cell.shapes[index].netID == nil else {
            throw LayoutIOError.unsupportedSourcePin("Full-mask PORT cannot overwrite an existing source net or alias another terminal")
        }
        return index
    }

    private func requireLayer(_ layer: Int16, _ datatype: Int16) throws {
        guard tech.layers.filter({ $0.gdsLayer == Int(layer) && $0.gdsDatatype == Int(datatype) }).count == 1 else {
            throw failure("Missing or ambiguous explicit mask layer (\(layer),\(datatype))")
        }
    }

    private func requireTransform(_ transform: IRTransform) throws {
        guard transform.angle.isFinite, transform.magnification.isFinite, transform.magnification > 0 else {
            throw failure("Nonfinite or invalid master transform")
        }
    }

    private func failure(_ reason: String) -> LayoutIOError { .incompatibleStandardCellMask(reason) }
}
