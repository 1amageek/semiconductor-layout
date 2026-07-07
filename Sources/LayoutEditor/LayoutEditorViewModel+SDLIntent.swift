import Foundation
import LayoutAutoGen
import LayoutCore
import LayoutVerify

extension LayoutEditorViewModel {
    // MARK: - SDL (N2)

    /// Outcome of the label→net annotation pass.
    public struct NetAnnotationSummary: Sendable, Equatable {
        public var netsCreated: Int
        public var shapesAnnotated: Int
        public var viasAnnotated: Int
        /// Instance terminals bound through `terminalNetIDs` because the
        /// labeled island lives inside an instance.
        public var terminalsBound: Int = 0
        /// Labels whose position touches no conductor on their layer.
        public var unmatchedLabels: [String]
        /// Child-occurrence conductors in annotated islands that a
        /// document edit cannot reach directly (their nets flow through
        /// the instance terminal binding instead).
        public var unreachableChildElements: Int
    }

    /// Derives net assignments from text labels — the bridge that makes
    /// an imported GDS (where every netID is nil) engage connectivity,
    /// opens/shorts and LVS. Each label names a net; the whole connected
    /// island under the label takes it. One undo unit.
    @discardableResult
    public func annotateNetsFromLabels() -> NetAnnotationSummary? {
        guard let cellID = editTargetCellID,
              let cell = editor.document.cell(withID: cellID) else { return nil }
        guard !cell.labels.isEmpty else {
            return NetAnnotationSummary(
                netsCreated: 0,
                shapesAnnotated: 0,
                viasAnnotated: 0,
                unmatchedLabels: [],
                unreachableChildElements: 0
            )
        }
        do {
            let analysis = try LayoutConnectivityExtractor().extract(
                document: editor.document,
                tech: tech,
                cellID: cellID
            )
            var summary = NetAnnotationSummary(
                netsCreated: 0,
                shapesAnnotated: 0,
                viasAnnotated: 0,
                unmatchedLabels: [],
                unreachableChildElements: 0
            )
            try editor.perform { doc in
                guard var cell = doc.cell(withID: cellID) else {
                    throw LayoutCoreError.cellNotFound(cellID)
                }
                var netIDByName = Dictionary(
                    cell.nets.map { ($0.name, $0.id) },
                    uniquingKeysWith: { first, _ in first }
                )
                let topShapeIDs = Set(cell.shapes.map(\.id))
                let topViaIDs = Set(cell.vias.map(\.id))

                // Labels may sit on FLATTENED geometry — a terminal bar
                // inside an instance — so candidates come from the same
                // flatten the connectivity analysis used. A child shape's
                // UUID repeats across occurrences; the label's position
                // against the island's bounding box disambiguates which
                // occurrence it names (far-apart occurrences in practice;
                // a genuinely ambiguous label is reported, not guessed).
                let flatShapes = try LayoutConnectivityExtractor()
                    .flattenedConductors(document: doc, tech: tech, cellID: cellID)
                    .shapes

                for label in cell.labels.sorted(by: { $0.text < $1.text }) {
                    let touchedIDs = Set(
                        flatShapes
                            .filter {
                                $0.layer == label.layer
                                    && LayoutGeometryAnalysis.contains(label.position, in: $0.geometry)
                            }
                            .map(\.id)
                    )
                    let candidates = analysis.nets.filter { net in
                        !touchedIDs.isDisjoint(with: net.shapeIDs)
                            && net.boundingBox.contains(label.position)
                    }
                    guard candidates.count == 1, let island = candidates.first else {
                        summary.unmatchedLabels.append(label.text)
                        continue
                    }
                    let netID: UUID
                    if let existing = netIDByName[label.text] {
                        netID = existing
                    } else {
                        let net = LayoutNet(name: label.text)
                        cell.nets.append(net)
                        netIDByName[label.text] = net.id
                        netID = net.id
                        summary.netsCreated += 1
                    }
                    var childShapeCount = 0
                    for shapeID in island.shapeIDs {
                        if topShapeIDs.contains(shapeID),
                           let index = cell.shapes.firstIndex(where: { $0.id == shapeID }) {
                            if cell.shapes[index].netID != netID {
                                cell.shapes[index].netID = netID
                                summary.shapesAnnotated += 1
                            }
                        } else {
                            childShapeCount += 1
                        }
                    }
                    for viaID in island.viaIDs {
                        if topViaIDs.contains(viaID),
                           let index = cell.vias.firstIndex(where: { $0.id == viaID }) {
                            if cell.vias[index].netID != netID {
                                cell.vias[index].netID = netID
                                summary.viasAnnotated += 1
                            }
                        } else {
                            childShapeCount += 1
                        }
                    }
                    // An island inside an instance has no editable shape;
                    // its net flows through the instance TERMINAL binding:
                    // every child pin sitting on the island gets bound, so
                    // flatten republishes the net on the pin and the
                    // connectivity tagging sees it. Child members count as
                    // unreachable only when no terminal carries their net.
                    var boundForIsland = 0
                    let islandShapeIDs = Set(island.shapeIDs)
                    for instanceIndex in cell.instances.indices {
                        let instance = cell.instances[instanceIndex]
                        guard let child = doc.cell(withID: instance.cellID) else { continue }
                        for occurrence in instance.occurrenceTransforms() {
                            for pin in child.pins {
                                let position = occurrence.apply(to: pin.position)
                                guard island.boundingBox.contains(position) else { continue }
                                let sitsOnIsland = flatShapes.contains { shape in
                                    islandShapeIDs.contains(shape.id)
                                        && shape.layer == pin.layer
                                        && LayoutGeometryAnalysis.contains(position, in: shape.geometry)
                                }
                                guard sitsOnIsland else { continue }
                                if cell.instances[instanceIndex].terminalNetIDs[pin.name] != netID {
                                    cell.instances[instanceIndex].terminalNetIDs[pin.name] = netID
                                    summary.terminalsBound += 1
                                }
                                boundForIsland += 1
                            }
                        }
                    }
                    if boundForIsland == 0 {
                        summary.unreachableChildElements += childShapeCount
                    }
                }
                doc.updateCell(cell)
            }
            resyncAfterInstanceEdit()
            return summary
        } catch {
            handleError(error)
            return nil
        }
    }

    /// The intent device armed for ghost placement; the next canvas click
    /// places it.
    /// Reference devices the layout does not realize yet — the SDL
    /// "unplaced" list (empty when no reference is loaded).
    public var unplacedIntentDevices: [ComparisonNetlist.Device] {
        lvsComparison?.unmatchedReferenceDevices ?? []
    }

    public func armIntentPlacement(_ device: ComparisonNetlist.Device) {
        pendingIntentDevice = device
    }

    public func disarmIntentPlacement() {
        pendingIntentDevice = nil
    }

    /// Places the armed intent device at `point`: generates (or reuses) a
    /// parameter-exact device cell and instantiates it. Direct UI
    /// placement binds the generated terminals to the reference ports;
    /// goal-command placement keeps binding as an explicit later command.
    /// Returns whether the instance landed.
    @discardableResult
    public func placeArmedIntentDevice(at point: LayoutPoint, bindTerminals: Bool = true) -> Bool {
        guard let device = pendingIntentDevice else { return false }
        pendingIntentDevice = nil
        do {
            let kindID: String
            switch device.kind {
            case .nmos: kindID = "nmos"
            case .pmos: kindID = "pmos"
            }
            let cellName = String(
                format: "%@_w%.3f_l%.3f_nf%d",
                kindID, device.parameters.width, device.parameters.length,
                device.parameters.multiplier
            )
            let deviceCellID: UUID
            if let existing = editor.document.cells.first(where: { $0.name == cellName }) {
                deviceCellID = existing.id
            } else {
                var generated = try MOSFETCellGenerator().generateCell(
                    deviceKindID: kindID,
                    instanceName: cellName,
                    parameters: [
                        "w": device.parameters.width,
                        "l": device.parameters.length,
                        "nf": Double(device.parameters.multiplier),
                    ],
                    tech: tech
                )
                generated.name = cellName
                let cell = generated
                editor.perform { doc in
                    doc.cells.append(cell)
                }
                deviceCellID = cell.id
            }
            let instanceCountBefore = editor.document
                .cell(withID: editTargetCellID ?? UUID())?.instances.count ?? 0
            if bindTerminals {
                placeIntentInstance(
                    cellID: deviceCellID,
                    name: device.id,
                    at: point,
                    device: device
                )
            } else {
                placeInstance(cellID: deviceCellID, name: device.id, at: point)
            }
            let instanceCountAfter = editor.document
                .cell(withID: editTargetCellID ?? UUID())?.instances.count ?? 0
            return instanceCountAfter == instanceCountBefore + 1
        } catch {
            handleError(error)
            return false
        }
    }

    private func placeIntentInstance(
        cellID childCellID: UUID,
        name: String,
        at point: LayoutPoint,
        device: ComparisonNetlist.Device
    ) {
        guard let parentCellID = editTargetCellID else { return }
        guard canPlaceInstance(childCellID: childCellID, in: parentCellID) else {
            handleError(LayoutCoreError.instanceCycle(
                parentCellID: parentCellID,
                childCellID: childCellID
            ))
            return
        }
        do {
            var placedID: UUID?
            try editor.perform { doc in
                guard var parent = doc.cell(withID: parentCellID) else {
                    throw LayoutCoreError.cellNotFound(parentCellID)
                }
                guard let child = doc.cell(withID: childCellID) else {
                    throw LayoutCoreError.cellNotFound(childCellID)
                }
                var netIDByName = Dictionary(
                    parent.nets.map { ($0.name, $0.id) },
                    uniquingKeysWith: { first, _ in first }
                )
                var terminalNetIDs: [String: UUID] = [:]
                for pin in child.pins {
                    guard let role = ComparisonTerminalRole(rawValue: pin.role.rawValue),
                          let net = device.terminals[role],
                          net.rawValue.hasPrefix("pin:") else { continue }
                    let netName = String(net.rawValue.dropFirst("pin:".count))
                    let netID: UUID
                    if let existing = netIDByName[netName] {
                        netID = existing
                    } else {
                        let created = LayoutNet(name: netName)
                        parent.nets.append(created)
                        netIDByName[netName] = created.id
                        netID = created.id
                    }
                    terminalNetIDs[pin.name] = netID
                }
                let instance = LayoutInstance(
                    cellID: childCellID,
                    name: name,
                    transform: LayoutTransform(
                        translation: isEditingInPlace ? editPoint(point) : snapToGrid(point)
                    ),
                    terminalNetIDs: terminalNetIDs
                )
                parent.instances.append(instance)
                doc.updateCell(parent)
                placedID = instance.id
            }
            selectedInstanceID = placedID
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    /// Binds every placed intent instance's terminals to document nets
    /// named after the LVS reference — the label-less autonomy path: the
    /// reference already states which net each terminal belongs to, so
    /// an agent needs no text labels. Instances are matched to reference
    /// devices by name (placement names them after the device ID), pins
    /// to terminals by role. Nets are created or reused BY NAME, and the
    /// terminal map carries them through flatten into connectivity and
    /// LVS. Returns the number of newly bound terminals, or nil when no
    /// reference is loaded. One undo unit.
    @discardableResult
    public func bindIntentTerminals() -> Int? {
        guard let reference = lvsReference, let cellID = editTargetCellID else { return nil }
        var bound = 0
        editor.perform { doc in
            guard var cell = doc.cell(withID: cellID) else { return }
            var netIDByName = Dictionary(
                cell.nets.map { ($0.name, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            for device in reference.devices {
                for index in cell.instances.indices where cell.instances[index].name == device.id {
                    guard let child = doc.cell(withID: cell.instances[index].cellID) else { continue }
                    for pin in child.pins {
                        guard let role = ComparisonTerminalRole(rawValue: pin.role.rawValue),
                              let net = device.terminals[role],
                              net.rawValue.hasPrefix("pin:") else { continue }
                        let name = String(net.rawValue.dropFirst("pin:".count))
                        let netID: UUID
                        if let existing = netIDByName[name] {
                            netID = existing
                        } else {
                            let created = LayoutNet(name: name)
                            cell.nets.append(created)
                            netIDByName[name] = created.id
                            netID = created.id
                        }
                        if cell.instances[index].terminalNetIDs[pin.name] != netID {
                            cell.instances[index].terminalNetIDs[pin.name] = netID
                            bound += 1
                        }
                    }
                }
            }
            doc.updateCell(cell)
        }
        resyncAfterInstanceEdit()
        return bound
    }

}
