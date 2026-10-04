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
        /// Root pins named through actual native contact incidence.
        public var pinsAnnotated: Int = 0
        /// Labels whose position touches no conductor on their layer.
        public var unmatchedLabels: [String]
        /// Child-occurrence conductors in annotated islands that a
        /// document edit cannot reach directly (their nets flow through
        /// the instance terminal binding instead).
        public var unreachableChildElements: Int
    }

    /// Names the edit-target label candidates using Device-owned contacts.
    /// Strict goal requests admit every candidate before one undoable mutation.
    @discardableResult
    public func annotateNetsFromLabels(
        requireAllLabels: Bool = false,
        limits: LayoutConductorCaptureLimits = .default
    ) -> NetAnnotationSummary? {
        guard let cellID = editTargetCellID,
              let original = editor.document.cell(withID: cellID) else { return nil }
        var summary = NetAnnotationSummary(netsCreated: 0, shapesAnnotated: 0,
            viasAnnotated: 0, unmatchedLabels: [], unreachableChildElements: 0)
        guard !original.labels.isEmpty else { return summary }
        do {
            let snapshot = try DeviceExtractor().captureConductors(
                document: editor.document, tech: tech, cellID: cellID, limits: limits)
            guard let root = snapshot.hierarchy.occurrences.firstIndex(where: {
                $0.parentIndex == nil && $0.sourceCellID == cellID
            }) else { throw SDLNetAnnotationError.invalidCapturedSource }
            let queryWork = original.labels.count.multipliedReportingOverflow(by: snapshot.footprints.count)
            guard !queryWork.overflow, queryWork.partialValue <= limits.maximumContactProbes else {
                throw SDLNetAnnotationError.pointProbeLimitExceeded
            }
            var nameByComponent: [Int: String] = [:]
            for label in original.labels.sorted(by: { $0.text < $1.text }) {
                let components = try snapshot.componentIndices(containing: label.position, on: label.layer)
                guard components.count == 1, let component = components.first else {
                    summary.unmatchedLabels.append(label.text)
                    continue
                }
                if let previous = nameByComponent[component], previous != label.text {
                    throw SDLNetAnnotationError.conflictingComponentNames([previous, label.text].sorted())
                }
                nameByComponent[component] = label.text
            }
            guard !requireAllLabels || summary.unmatchedLabels.isEmpty else {
                throw SDLNetAnnotationError.unmatchedLabels(summary.unmatchedLabels)
            }
            var componentsBySource: [LayoutConductorSnapshot.Source: Set<Int>] = [:]
            for (componentIndex, component) in snapshot.components.enumerated() {
                for footprint in component.footprintIndices {
                    componentsBySource[snapshot.footprints[footprint].source, default: []].insert(componentIndex)
                }
            }
            let rootOccurrence = snapshot.hierarchy.occurrences[root]
            var shapeNames: [Int: String] = [:]
            var viaNames: [Int: String] = [:]
            for (source, components) in componentsBySource where components.count == 1 {
                guard let component = components.first, let name = nameByComponent[component] else { continue }
                switch source {
                case .shape(let index) where rootOccurrence.shapeRange.contains(index):
                    shapeNames[index - rootOccurrence.shapeRange.lowerBound] = name
                case .via(let index) where rootOccurrence.viaRange.contains(index):
                    viaNames[index - rootOccurrence.viaRange.lowerBound] = name
                default: break
                }
            }
            var rootPinNames: [Int: String] = [:]
            var terminalNames: [AnnotationTerminalKey: String] = [:]
            var incidenceByTerminal: [AnnotationTerminalKey: [[Int]]] = [:]
            var boundComponents: Set<Int> = []
            for pin in snapshot.pins {
                let sourcePin = snapshot.hierarchy.pins[pin.sourcePinIndex]
                let occurrence = snapshot.hierarchy.occurrences[pin.occurrenceIndex]
                let selected = Set(pin.componentIndices.compactMap { nameByComponent[$0] })
                let name = selected.first
                if name != nil {
                    guard selected.count == 1, pin.componentIndices.allSatisfy({ nameByComponent[$0] == name }) else {
                        throw SDLNetAnnotationError.ambiguousPin(sourcePin.name)
                    }
                }
                if pin.occurrenceIndex == root {
                    if let name { rootPinNames[pin.sourcePinIndex - rootOccurrence.pinRange.lowerBound] = name }
                    continue
                }
                guard occurrence.path.count == 1, let step = occurrence.path.first,
                      let instanceIndex = original.instances.firstIndex(where: { $0.id == step.instanceID }),
                      original.instances[instanceIndex].cellID == occurrence.sourceCellID else {
                    if name != nil {
                        // FIXME(INCOMPLETE_IMPLEMENTATION): Label annotation cannot persist a
                        // nested occurrence binding without a canonical root-terminal correspondence.
                        // This production editor command must refuse until that authority exists.
                        throw SDLNetAnnotationError.unavailableTerminalBinding(pin: sourcePin.name,
                            instancePath: occurrence.path.map(\.instanceID))
                    }
                    continue
                }
                let key = AnnotationTerminalKey(instanceIndex: instanceIndex, pin: sourcePin.name)
                incidenceByTerminal[key, default: []].append(pin.componentIndices)
                if let name {
                    if let previous = terminalNames[key], previous != name {
                        throw SDLNetAnnotationError.conflictingTerminalBinding(instance: step.instanceID, pin: sourcePin.name)
                    }
                    terminalNames[key] = name
                    boundComponents.formUnion(pin.componentIndices)
                }
            }
            for (key, name) in terminalNames {
                guard incidenceByTerminal[key, default: []].allSatisfy({ components in
                    !components.isEmpty && components.allSatisfy { nameByComponent[$0] == name }
                }) else {
                    throw SDLNetAnnotationError.conflictingTerminalBinding(
                        instance: original.instances[key.instanceIndex].id, pin: key.pin)
                }
            }
            for (source, components) in componentsBySource {
                let child: Bool
                switch source {
                case .shape(let index): child = !rootOccurrence.shapeRange.contains(index)
                case .via(let index): child = !rootOccurrence.viaRange.contains(index)
                case .pin: child = false
                }
                if child && components.contains(where: { nameByComponent[$0] != nil && !boundComponents.contains($0) }) {
                    summary.unreachableChildElements += 1
                }
            }
            try editor.perform { document in
                guard var cell = document.cell(withID: cellID), cell == original else {
                    throw SDLNetAnnotationError.invalidCapturedSource
                }
                var netIDs = Dictionary(cell.nets.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
                for name in Set(nameByComponent.values).sorted() where netIDs[name] == nil {
                    let net = LayoutNet(name: name)
                    cell.nets.append(net); netIDs[name] = net.id; summary.netsCreated += 1
                }
                for (index, name) in shapeNames where cell.shapes[index].netID != netIDs[name] {
                    cell.shapes[index].netID = netIDs[name]; summary.shapesAnnotated += 1
                }
                for (index, name) in viaNames where cell.vias[index].netID != netIDs[name] {
                    cell.vias[index].netID = netIDs[name]; summary.viasAnnotated += 1
                }
                for (index, name) in rootPinNames where cell.pins[index].netID != netIDs[name] {
                    cell.pins[index].netID = netIDs[name]; summary.pinsAnnotated += 1
                }
                for (key, name) in terminalNames where cell.instances[key.instanceIndex].terminalNetIDs[key.pin] != netIDs[name] {
                    cell.instances[key.instanceIndex].terminalNetIDs[key.pin] = netIDs[name]; summary.terminalsBound += 1
                }
                document.updateCell(cell)
            }
            resyncAfterInstanceEdit()
            return summary
        } catch {
            handleError(error)
            return nil
        }
    }

    private struct AnnotationTerminalKey: Hashable {
        let instanceIndex: Int
        let pin: String
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
