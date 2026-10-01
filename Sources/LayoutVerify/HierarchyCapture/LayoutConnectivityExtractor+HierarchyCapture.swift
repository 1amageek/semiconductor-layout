import Foundation
import LayoutCore

extension LayoutConnectivityExtractor {
    /// Captures bounded world geometry from the supplied immutable value.
    /// Repeated source IDs are disambiguated by occurrence paths and ranges.
    public func captureHierarchy(
        document: LayoutDocument,
        cellID: UUID? = nil,
        limits: LayoutHierarchyCaptureLimits = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> LayoutHierarchySnapshot {
        guard limits.maximumOccurrences > 0, limits.maximumObjects >= 0,
              limits.maximumGeometryPoints >= 0, limits.maximumDepth >= 0 else {
            throw LayoutHierarchyCaptureError.invalidLimits
        }
        func checkCancellation() throws {
            if isCancelled() { throw LayoutHierarchyCaptureError.cancelled }
        }
        try checkCancellation()
        guard document.cells.count <= limits.maximumOccurrences else {
            throw LayoutHierarchyCaptureError.limitExceeded(.occurrences)
        }
        var cellsByID: [UUID: LayoutCell] = [:]
        for cell in document.cells {
            try checkCancellation()
            guard cellsByID.updateValue(cell, forKey: cell.id) == nil else {
                throw LayoutHierarchyCaptureError.duplicateCellID(cell.id)
            }
        }
        let requestedID = cellID ?? document.topCellID ?? document.cells.first?.id
        guard let rootID = requestedID, let root = cellsByID[rootID] else {
            throw LayoutHierarchyCaptureError.targetCellNotFound(requestedID)
        }
        var objects = 0
        var points = 0
        func charge(_ count: Int, _ resource: LayoutHierarchyCaptureError.Resource) throws {
            try checkCancellation()
            let current = resource == .objects ? objects : points
            let maximum = resource == .objects ? limits.maximumObjects : limits.maximumGeometryPoints
            guard count >= 0, count <= maximum - current else {
                throw LayoutHierarchyCaptureError.limitExceeded(resource)
            }
            if resource == .objects { objects += count } else { points += count }
        }
        func validate(_ point: LayoutPoint, id: UUID) throws {
            try checkCancellation()
            guard point.x.isFinite, point.y.isFinite else {
                throw LayoutHierarchyCaptureError.invalidGeometry(id)
            }
        }
        func validate(_ rect: LayoutRect, id: UUID) throws {
            try validate(rect.origin, id: id)
            guard rect.size.width.isFinite, rect.size.height.isFinite,
                  rect.size.width > 0, rect.size.height > 0,
                  rect.maxX.isFinite, rect.maxY.isFinite, rect.maxX > rect.minX, rect.maxY > rect.minY else {
                throw LayoutHierarchyCaptureError.invalidGeometry(id)
            }
        }
        func validate(_ transform: LayoutTransform, id: UUID) throws {
            try checkCancellation()
            guard transform.translation.x.isFinite, transform.translation.y.isFinite,
                  transform.rotationDegrees.isFinite, transform.magnification.isFinite,
                  transform.magnification > 0 else {
                throw LayoutHierarchyCaptureError.invalidTransform(id)
            }
        }
        func validate(_ geometry: LayoutGeometry, id: UUID) throws {
            switch geometry {
            case .rect(let rect): try validate(rect, id: id)
            case .polygon(let polygon):
                for point in polygon.points { try validate(point, id: id) }
            case .path(let path):
                guard path.points.count >= 2, path.width.isFinite, path.width > 0 else {
                    throw LayoutHierarchyCaptureError.invalidGeometry(id)
                }
                for point in path.points { try validate(point, id: id) }
            }
            let box = LayoutGeometryAnalysis.boundingBox(for: geometry)
            guard box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite,
                  box.size.width.isFinite, box.size.height.isFinite, box.size.width >= 0, box.size.height >= 0 else {
                throw LayoutHierarchyCaptureError.invalidGeometry(id)
            }
        }
        func transformed(_ geometry: LayoutGeometry, by transforms: [LayoutTransform], id: UUID) throws -> LayoutGeometry {
            let count: Int
            switch geometry {
            case .rect: count = 4
            case .polygon(let polygon): count = polygon.points.count
            case .path(let path): count = path.points.count
            }
            let (work, overflow) = count.multipliedReportingOverflow(by: max(1, transforms.count))
            guard !overflow else { throw LayoutHierarchyCaptureError.limitExceeded(.geometryPoints) }
            try charge(work, .geometryPoints)
            try validate(geometry, id: id)
            var world = geometry
            for transform in transforms.reversed() {
                try checkCancellation()
                world = world.transformed(by: transform)
                try validate(world, id: id)
            }
            return world
        }
        struct Frame {
            let cell: LayoutCell
            let occurrenceIndex: Int
            var instanceIndex = 0
            var replicaIndex = 0
        }
        var occurrences: [LayoutHierarchySnapshot.Occurrence] = []
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var pins: [LayoutPin] = []
        var pinGeometries: [LayoutGeometry] = []
        func appendOccurrence(_ cell: LayoutCell, parentIndex: Int?, path: [LayoutHierarchySnapshot.Step],
                              transforms: [LayoutTransform], terminalNetIDs: [String: UUID]) throws -> Int {
            try checkCancellation()
            guard path.count <= limits.maximumDepth else { throw LayoutHierarchyCaptureError.limitExceeded(.depth) }
            guard occurrences.count < limits.maximumOccurrences else {
                throw LayoutHierarchyCaptureError.limitExceeded(.occurrences)
            }
            for count in [cell.shapes.count, cell.vias.count, cell.pins.count, cell.instances.count, terminalNetIDs.count] {
                try charge(count, .objects)
            }
            func unique<IDs: Sequence>(_ ids: IDs) throws where IDs.Element == UUID {
                var seen: Set<UUID> = []
                for id in ids {
                    try checkCancellation()
                    guard seen.insert(id).inserted else {
                        throw LayoutHierarchyCaptureError.duplicateObjectID(cellID: cell.id, objectID: id)
                    }
                }
            }
            try unique(cell.shapes.lazy.map(\.id)); try unique(cell.vias.lazy.map(\.id))
            try unique(cell.pins.lazy.map(\.id)); try unique(cell.instances.lazy.map(\.id))
            let shapeStart = shapes.count, viaStart = vias.count, pinStart = pins.count
            for shape in cell.shapes {
                var world = shape
                world.geometry = try transformed(shape.geometry, by: transforms, id: shape.id)
                shapes.append(world)
            }
            for via in cell.vias {
                try charge(via.geometryTransforms.count, .geometryPoints)
                try charge(transforms.count, .geometryPoints)
                try charge(1, .geometryPoints)
                try validate(via.position, id: via.id)
                for transform in via.geometryTransforms { try validate(transform, id: via.id) }
                let world = via.transformed(by: transforms)
                try validate(world.position, id: via.id)
                vias.append(world)
            }
            for pin in cell.pins {
                try validate(pin.position, id: pin.id)
                let geometry = LayoutGeometry.rect(LayoutRect(
                    origin: LayoutPoint(x: pin.position.x - pin.size.width / 2,
                                        y: pin.position.y - pin.size.height / 2), size: pin.size))
                pinGeometries.append(try transformed(geometry, by: transforms, id: pin.id))
                let worldPin = pin.transformed(by: transforms)
                try validate(worldPin.position, id: pin.id)
                pins.append(worldPin)
            }
            let index = occurrences.count
            occurrences.append(.init(sourceCellID: cell.id, parentIndex: parentIndex, path: path,
                                     transforms: transforms, terminalNetIDs: terminalNetIDs,
                                     shapeRange: shapeStart..<shapes.count, viaRange: viaStart..<vias.count,
                                     pinRange: pinStart..<pins.count))
            return index
        }
        let rootIndex = try appendOccurrence(root, parentIndex: nil, path: [], transforms: [], terminalNetIDs: [:])
        var stack = [Frame(cell: root, occurrenceIndex: rootIndex)]
        var activeCellIDs: Set<UUID> = [root.id]
        while !stack.isEmpty {
            try checkCancellation()
            let frameIndex = stack.count - 1
            let frame = stack[frameIndex]
            guard frame.instanceIndex < frame.cell.instances.count else {
                activeCellIDs.remove(frame.cell.id)
                stack.removeLast()
                continue
            }
            let instance = frame.cell.instances[frame.instanceIndex]
            try validate(instance.transform, id: instance.id)
            guard let child = cellsByID[instance.cellID] else {
                throw LayoutHierarchyCaptureError.missingChildCell(instance.cellID)
            }
            let rows = instance.repetition?.rows ?? 1
            let columns = instance.repetition?.columns ?? 1
            guard rows > 0, columns > 0 else { throw LayoutHierarchyCaptureError.invalidRepetition(instance.id) }
            let (replicas, overflow) = rows.multipliedReportingOverflow(by: columns)
            guard !overflow else { throw LayoutHierarchyCaptureError.repetitionOverflow(instance.id) }
            if frame.replicaIndex == 0, replicas > limits.maximumOccurrences - occurrences.count {
                throw LayoutHierarchyCaptureError.limitExceeded(.occurrences)
            }
            if frame.replicaIndex == replicas {
                stack[frameIndex].instanceIndex += 1
                stack[frameIndex].replicaIndex = 0
                continue
            }
            guard !activeCellIDs.contains(child.id) else { throw LayoutHierarchyCaptureError.hierarchyCycle(child.id) }
            let row = frame.replicaIndex / columns, column = frame.replicaIndex % columns
            var transform = instance.transform
            if let repetition = instance.repetition {
                try validate(repetition.rowStep, id: instance.id)
                try validate(repetition.columnStep, id: instance.id)
                transform.translation = LayoutPoint(
                    x: transform.translation.x + Double(row) * repetition.rowStep.x + Double(column) * repetition.columnStep.x,
                    y: transform.translation.y + Double(row) * repetition.rowStep.y + Double(column) * repetition.columnStep.y)
                try validate(transform, id: instance.id)
            }
            let parent = occurrences[frame.occurrenceIndex]
            guard parent.path.count < limits.maximumDepth else {
                throw LayoutHierarchyCaptureError.limitExceeded(.depth)
            }
            try charge(parent.path.count + 1, .geometryPoints)
            try charge(parent.transforms.count + 1, .geometryPoints)
            let nextIndex = try appendOccurrence(child, parentIndex: frame.occurrenceIndex,
                path: parent.path + [.init(instanceID: instance.id, row: row, column: column)],
                transforms: parent.transforms + [transform], terminalNetIDs: instance.terminalNetIDs)
            stack[frameIndex].replicaIndex += 1
            activeCellIDs.insert(child.id)
            stack.append(Frame(cell: child, occurrenceIndex: nextIndex))
        }
        try checkCancellation()
        return LayoutHierarchySnapshot(documentID: document.id, units: document.units, rootCellID: root.id,
            occurrences: occurrences, shapes: shapes, vias: vias, pins: pins, pinGeometries: pinGeometries)
    }
}
