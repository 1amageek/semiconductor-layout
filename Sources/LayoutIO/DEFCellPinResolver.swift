import Foundation
import DEF
import LEF
import LayoutCore
import LayoutIR
import LayoutTech

/// Binds standard terminal declarations to admitted source rectangles before publication.
struct DEFCellPinResolver {
    let tech: LayoutTechDatabase
    let library: LEFDocument?

    private func identity(_ kind: String, _ value: String) -> UUID {
        IRLayoutConverter().stableUUID(namespace: kind, payload: value)
    }

    private func grid(_ value: Double, units: Double) throws -> Int32 {
        let scaled = value * units, rounded = scaled.rounded()
        guard scaled.isFinite, abs(scaled - rounded) <= scaled.ulp * 4,
              let result = Int32(exactly: rounded) else {
            throw LayoutIOError.unsupportedSourcePin("Nonfinite, off-grid or overflowing source coordinate")
        }
        return result
    }

    private func layer(_ name: String) throws -> LayoutLayerID {
        let matches = tech.layers.filter {
            $0.id.name.caseInsensitiveCompare(name) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }
        guard matches.count == 1, let match = matches.first, match.id.purpose == "drawing" else {
            throw LayoutIOError.unsupportedSourcePin("Missing or ambiguous routing layer '\(name)'")
        }
        return match.id
    }

    private func direction(_ raw: String?) throws -> LayoutPinDirection {
        switch raw {
        case "INPUT": return .input
        case "OUTPUT": return .output
        case "INOUT": return .inout_
        case "FEEDTHRU": return .feedthrough
        default: throw LayoutIOError.unsupportedSourcePin("A declared source direction is required")
        }
    }

    private func role(_ raw: String?) throws -> LayoutPinRole {
        switch raw {
        case nil, "SIGNAL": return .signal
        case "POWER": return .power
        case "GROUND": return .ground
        default:
            // FIXME(INCOMPLETE_IMPLEMENTATION): Canonical roles do not retain CLOCK/ANALOG use.
            // Bound DEF/LEF import must fail until source use has a lossless canonical value.
            throw LayoutIOError.unsupportedSourcePin("Source use '\(raw ?? "")' is not represented by canonical pin roles")
        }
    }

    private func master(_ name: String) throws -> LEFMacroDef {
        guard let library else { throw LayoutIOError.missingStandardCellLibrary }
        let matches = library.macros.filter { $0.name == name }
        guard matches.count == 1, let macro = matches.first else { throw LayoutIOError.unresolvedCellMaster(name) }
        guard let width = macro.width, let height = macro.height,
              width.isFinite, height.isFinite, width > 0, height > 0,
              library.dbuPerMicron.isFinite, library.dbuPerMicron > 0 else {
            throw LayoutIOError.unresolvedCellMaster(name)
        }
        _ = try grid(width, units: library.dbuPerMicron); _ = try grid(height, units: library.dbuPerMicron)
        // FIXME(INCOMPLETE_IMPLEMENTATION): This master profile proves origin-zero placement frames.
        // Canonical electrical import/export must reject nonzero LEF ORIGIN until the source
        // origin convention and every transformed port are verified against standard geometry.
        guard macro.origin == nil || macro.origin == LEFPoint(x: 0, y: 0) else {
            throw LayoutIOError.unsupportedSourcePin("Nonzero ORIGIN in master '\(name)'")
        }
        guard Set(macro.pins.map(\.name)).count == macro.pins.count else {
            throw LayoutIOError.unresolvedCellMaster(name)
        }
        return macro
    }

    private func rectangle(_ rect: LEFRect, sourceUnits: Double, units: Double) throws -> LayoutRect {
        let values = [rect.x1, rect.y1, rect.x2, rect.y2]
        for value in values { _ = try grid(value, units: sourceUnits) }
        let x1 = try grid(rect.x1, units: units), y1 = try grid(rect.y1, units: units)
        let x2 = try grid(rect.x2, units: units), y2 = try grid(rect.y2, units: units)
        let width = Int64(x2) - Int64(x1), height = Int64(y2) - Int64(y1)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw LayoutIOError.unsupportedSourcePin("Source rectangle cannot retain a centered pin on the native grid")
        }
        return LayoutRect(origin: .init(x: Double(x1) / units, y: Double(y1) / units),
            size: .init(width: Double(width) / units, height: Double(height) / units))
    }

    private func port(_ pin: LEFPinDef, units: Double) throws -> (LayoutRect, LayoutLayerID) {
        // FIXME(INCOMPLETE_IMPLEMENTATION): LayoutPin has one single-layer rectangular surface.
        // Bound master import must reject multiple rectangles/layers, polygons and named vias
        // until their full port geometry can be retained and captured without envelopes.
        guard pin.ports.count == 1, let port = pin.ports.first, port.rects.count == 1,
              port.polygons.isEmpty, port.vias.isEmpty, let rect = port.rects.first,
              rect.mask == nil, let library else {
            throw LayoutIOError.unsupportedSourcePin("Pin '\(pin.name)' requires one unmasked single-layer RECT PORT")
        }
        return (try rectangle(rect, sourceUnits: library.dbuPerMicron, units: units), try layer(port.layerName))
    }

    private func normalized(_ orientation: DEFOrientation, width: Double, height: Double,
                            position: LayoutPoint) -> LayoutTransform {
        let ir = DEFIRConverter.orientationToTransform(orientation)
        var transform = LayoutTransform(rotationDegrees: ir.angle, mirrorY: ir.mirrorX)
        let corners = [LayoutPoint.zero, .init(x: width, y: 0), .init(x: 0, y: height), .init(x: width, y: height)].map { transform.apply(to: $0) }
        let minX = corners.map(\.x).min() ?? 0, minY = corners.map(\.y).min() ?? 0
        transform.translation = .init(x: position.x - minX, y: position.y - minY)
        return transform
    }

    func resolve(_ canonical: LayoutDocument, source: DEFDocument) throws -> LayoutDocument {
        var result = canonical
        guard let rootIndex = result.cells.firstIndex(where: { $0.id == result.topCellID }) else {
            throw LayoutIOError.conversionFailed("DEF requires a canonical top cell")
        }
        let units = result.units.scale.databaseUnitsPerMicrometer
        var root = result.cells[rootIndex]
        if let dieArea = source.dieArea {
            root.properties["def.dieArea"] = String(decoding: try JSONEncoder().encode(dieArea), as: UTF8.self)
        }
        guard Set(source.components.map(\.name)).count == source.components.count,
              Set(source.pins.map(\.name)).count == source.pins.count else {
            throw LayoutIOError.conversionFailed("Duplicate DEF component or pin identity")
        }
        let components = Dictionary(uniqueKeysWithValues: source.components.map { ($0.name, $0) })
        var definitions: [String: LEFMacroDef] = [:]
        for component in source.components {
            guard component.placementStatus != nil, component.placementStatus != .unplaced else {
                throw LayoutIOError.unresolvedCellMaster(component.macro)
            }
            definitions[component.macro] = try master(component.macro)
        }
        for (name, macro) in definitions {
            guard let index = result.cells.firstIndex(where: { $0.name == name && $0.id != result.topCellID }),
                  let width = macro.width, let height = macro.height else { throw LayoutIOError.unresolvedCellMaster(name) }
            _ = try grid(width, units: units); _ = try grid(height, units: units)
            var cell = result.cells[index]
            cell.properties["lef.macro.widthMicrometers"] = String(width)
            cell.properties["lef.macro.heightMicrometers"] = String(height)
            for sourcePin in macro.pins {
                let (rect, pinLayer) = try port(sourcePin, units: units)
                let net = LayoutNet(id: identity("lef-net", "\(source.designName)|\(name)|\(sourcePin.name)"), name: sourcePin.name)
                let pinID = identity("lef-pin", "\(source.designName)|\(name)|\(sourcePin.name)")
                cell.nets.append(net)
                cell.pins.append(LayoutPin(id: pinID, name: sourcePin.name, position: rect.center,
                    size: rect.size, layer: pinLayer, netID: net.id,
                    role: try role(sourcePin.use?.rawValue), direction: try direction(sourcePin.direction?.rawValue)))
                cell.shapes.append(LayoutShape(id: identity("lef-port", pinID.uuidString), layer: pinLayer,
                    netID: net.id, geometry: .rect(rect), properties: ["lef.pin.name": sourcePin.name]))
            }
            result.cells[index] = cell
        }
        func rootNet(_ name: String) throws -> UUID {
            guard !name.isEmpty else { throw LayoutIOError.unresolvedTerminal(component: "PIN", pin: name) }
            if let net = root.nets.first(where: { $0.name == name }) { return net.id }
            let net = LayoutNet(id: identity("def-pin-net", "\(source.designName)|\(name)"), name: name)
            root.nets.append(net); return net.id
        }
        var terminalBindings: [String: [String: UUID]] = [:]
        var topBindings: [String: UUID] = [:]
        for pin in source.pins {
            if let netName = pin.netName { topBindings[pin.name] = try rootNet(netName) }
        }
        func bind(_ component: String, _ pin: String, to netID: UUID) throws {
            if component == "PIN" {
                guard source.pins.contains(where: { $0.name == pin }) else {
                    throw LayoutIOError.unresolvedTerminal(component: component, pin: pin)
                }
                if let existing = topBindings[pin], existing != netID {
                    throw LayoutIOError.unresolvedTerminal(component: component, pin: pin)
                }
                topBindings[pin] = netID
            } else {
                guard let definition = components[component].flatMap({ definitions[$0.macro] }),
                      definition.pins.contains(where: { $0.name == pin }) else {
                    throw LayoutIOError.unresolvedTerminal(component: component, pin: pin)
                }
                if let existing = terminalBindings[component]?[pin], existing != netID {
                    throw LayoutIOError.unresolvedTerminal(component: component, pin: pin)
                }
                terminalBindings[component, default: [:]][pin] = netID
            }
        }
        let sourceNets = source.nets.map { ($0.name, $0.connections) } + source.specialNets.map { ($0.name, $0.connections) }
        for (name, connections) in sourceNets {
            let netID = try rootNet(name)
            for connection in connections {
                if connection.componentName == "*" {
                    let matches = source.components.filter { definitions[$0.macro]?.pins.contains(where: { $0.name == connection.pinName }) == true }
                    guard !matches.isEmpty else { throw LayoutIOError.unresolvedTerminal(component: "*", pin: connection.pinName) }
                    for component in matches { try bind(component.name, connection.pinName, to: netID) }
                } else { try bind(connection.componentName, connection.pinName, to: netID) }
            }
        }
        for component in source.components {
            guard let index = root.instances.firstIndex(where: { $0.name == component.name }),
                  let macro = definitions[component.macro], let width = macro.width, let height = macro.height else {
                throw LayoutIOError.unresolvedCellMaster(component.macro)
            }
            let transform = normalized(component.orientation, width: width, height: height,
                position: .init(x: Double(component.x) / units, y: Double(component.y) / units))
            root.instances[index].transform = transform
            root.instances[index].terminalNetIDs = terminalBindings[component.name] ?? [:]
            let cell = try requireCell(root.instances[index].cellID, in: result)
            for pin in cell.pins {
                let world = pin.transformed(by: [transform])
                _ = try grid(world.position.x, units: units); _ = try grid(world.position.y, units: units)
                _ = try grid(world.position.x - world.size.width / 2, units: units)
                _ = try grid(world.position.x + world.size.width / 2, units: units)
                _ = try grid(world.position.y - world.size.height / 2, units: units)
                _ = try grid(world.position.y + world.size.height / 2, units: units)
            }
        }
        root.labels = []
        for sourcePin in source.pins {
            // FIXME(INCOMPLETE_IMPLEMENTATION): This canonical pin profile retains one rectangle.
            // DEF intake must reject missing/multiple rectangles and unplaced ports until their
            // complete source geometry is represented; labels are never terminal substitutes.
            guard sourcePin.placementStatus != nil, sourcePin.placementStatus != .unplaced,
                  sourcePin.layerRects.count == 1, let surface = sourcePin.layerRects.first,
                  surface.rects.count == 1, let sourceRect = surface.rects.first,
                  let netID = topBindings[sourcePin.name] else {
                throw LayoutIOError.unsupportedSourcePin("DEF PIN '\(sourcePin.name)' requires placed rectangle and exact net binding")
            }
            let world = try topPinRectangle(sourceRect, orientation: sourcePin.orientation,
                x: sourcePin.x, y: sourcePin.y, units: units)
            let pinID = identity("def-pin", "\(source.designName)|\(sourcePin.name)")
            let pin = LayoutPin(id: pinID, name: sourcePin.name, position: world.center,
                size: world.rect.size, layer: try layer(surface.layerName), netID: netID,
                role: try role(sourcePin.use?.rawValue), direction: try direction(sourcePin.direction?.rawValue))
            root.pins.append(pin)
            root.shapes.append(LayoutShape(id: identity("def-pin-metal", pinID.uuidString), layer: pin.layer,
                netID: netID, geometry: .rect(world.rect), properties: ["def.pin.name": pin.name,
                        "def.pin.status": sourcePin.placementStatus?.rawValue ?? "",
                        "def.pin.special": String(sourcePin.special),
                        "def.pin.properties": String(decoding: try JSONEncoder().encode(sourcePin.properties), as: UTF8.self)]))
        }
        result.cells[rootIndex] = root
        return result
    }

    private func topPinRectangle(_ rect: DEFRect, orientation: DEFOrientation, x: Int32, y: Int32,
                                 units: Double) throws -> (rect: LayoutRect, center: LayoutPoint) {
        guard rect.x2 > rect.x1, rect.y2 > rect.y1 else {
            throw LayoutIOError.unsupportedSourcePin("Source PIN rectangle must have positive area")
        }
        let matrix: (Int64, Int64, Int64, Int64)
        switch orientation {
        case .n: matrix = (1, 0, 0, 1)
        case .s: matrix = (-1, 0, 0, -1)
        case .e: matrix = (0, 1, -1, 0)
        case .w: matrix = (0, -1, 1, 0)
        case .fn: matrix = (-1, 0, 0, 1)
        case .fs: matrix = (1, 0, 0, -1)
        case .fe: matrix = (0, -1, -1, 0)
        case .fw: matrix = (0, 1, 1, 0)
        }
        let corners = [(rect.x1, rect.y1), (rect.x2, rect.y1), (rect.x1, rect.y2), (rect.x2, rect.y2)]
        // Int32 coordinates and +/-1 matrices have sums within Int64; reject Int32 output overflow.
        let xs = corners.map { matrix.0 * Int64($0.0) + matrix.1 * Int64($0.1) + Int64(x) }
        let ys = corners.map { matrix.2 * Int64($0.0) + matrix.3 * Int64($0.1) + Int64(y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              Int32(exactly: minX) != nil, Int32(exactly: maxX) != nil,
              Int32(exactly: minY) != nil, Int32(exactly: maxY) != nil,
              (minX + maxX) % 2 == 0, (minY + maxY) % 2 == 0 else {
            throw LayoutIOError.unsupportedSourcePin("Source PIN pose overflows or has an off-grid center")
        }
        return (.init(origin: .init(x: Double(minX) / units, y: Double(minY) / units),
            size: .init(width: Double(maxX - minX) / units, height: Double(maxY - minY) / units)),
            .init(x: Double((minX + maxX) / 2) / units, y: Double((minY + maxY) / 2) / units))
    }

    private func requireCell(_ id: UUID, in document: LayoutDocument) throws -> LayoutCell {
        guard let cell = document.cells.first(where: { $0.id == id }) else { throw LayoutIOError.conversionFailed("Missing canonical master cell") }
        return cell
    }

    func prepareExport(_ source: inout DEFDocument, canonical: LayoutDocument) throws {
        guard let root = canonical.topCellID.flatMap({ canonical.cell(withID: $0) }) else {
            throw LayoutIOError.conversionFailed("DEF requires a canonical top cell")
        }
        let units = canonical.units.scale.databaseUnitsPerMicrometer
        if let raw = root.properties["def.dieArea"] {
            source.dieArea = try JSONDecoder().decode(DEFDieArea.self, from: Data(raw.utf8))
        }
        for index in source.components.indices {
            let component = source.components[index], definition = try master(component.macro)
            guard let width = definition.width, let height = definition.height,
                  let instance = root.instances.first(where: { $0.name == component.name }) else {
                throw LayoutIOError.unresolvedCellMaster(component.macro)
            }
            let cell = try requireCell(instance.cellID, in: canonical)
            guard cell.instances.isEmpty, cell.vias.isEmpty, cell.labels.isEmpty,
                  cell.pins.count == definition.pins.count, cell.shapes.count == definition.pins.count,
                  cell.properties["lef.macro.widthMicrometers"] == String(width),
                  cell.properties["lef.macro.heightMicrometers"] == String(height) else {
                throw LayoutIOError.unresolvedCellMaster(component.macro)
            }
            for sourcePin in definition.pins {
                let (rect, pinLayer) = try port(sourcePin, units: units)
                guard let pin = cell.pins.first(where: { $0.name == sourcePin.name }),
                      pin.position == rect.center, pin.size == rect.size, pin.layer == pinLayer,
                      cell.nets.contains(where: { $0.id == pin.netID && $0.name == pin.name }),
                      pin.direction == (try direction(sourcePin.direction?.rawValue)),
                      pin.role == (try role(sourcePin.use?.rawValue)),
                      cell.shapes.contains(where: {
                          $0.layer == pinLayer && $0.netID == pin.netID && $0.geometry == .rect(rect)
                              && $0.properties["lef.pin.name"] == sourcePin.name
                      }) else { throw LayoutIOError.unresolvedTerminal(component: component.name, pin: sourcePin.name) }
            }
            guard instance.terminalNetIDs.keys.allSatisfy({ key in cell.pins.contains(where: { $0.name == key }) }),
                  instance.terminalNetIDs.values.allSatisfy({ value in root.nets.contains(where: { $0.id == value }) }) else {
                throw LayoutIOError.unresolvedCellMaster(component.macro)
            }
            let offset = normalized(component.orientation, width: width, height: height, position: .zero).translation
            source.components[index].x = try grid(instance.transform.translation.x - offset.x, units: units)
            source.components[index].y = try grid(instance.transform.translation.y - offset.y, units: units)
        }

        var connections: [String: [DEFConnection]] = [:]
        for instance in root.instances {
            let name = instance.name
            guard !name.isEmpty else { throw LayoutIOError.unresolvedCellMaster("Unnamed component") }
            for (pin, netID) in instance.terminalNetIDs.sorted(by: { $0.key < $1.key }) {
                guard let net = root.nets.first(where: { $0.id == netID }) else {
                    throw LayoutIOError.unresolvedTerminal(component: name, pin: pin)
                }
                connections[net.name, default: []].append(.init(componentName: name, pinName: pin))
            }
        }
        for pin in root.pins {
            guard let netID = pin.netID, let net = root.nets.first(where: { $0.id == netID }) else {
                throw LayoutIOError.unresolvedTerminal(component: "PIN", pin: pin.name)
            }
            connections[net.name, default: []].append(.init(componentName: "PIN", pinName: pin.name))
        }
        let names = source.nets.map(\.name) + source.specialNets.map(\.name)
        guard Set(names).count == names.count, connections.keys.allSatisfy({ names.contains($0) }) else {
            throw LayoutIOError.conversionFailed("Ambiguous or missing declared DEF net class")
        }
        for index in source.nets.indices { source.nets[index].connections = connections[source.nets[index].name] ?? [] }
        for index in source.specialNets.indices { source.specialNets[index].connections = connections[source.specialNets[index].name] ?? [] }
        source.pins = try root.pins.map { pin in
            guard let netID = pin.netID, let net = root.nets.first(where: { $0.id == netID }),
                  let direction = pin.direction else {
                throw LayoutIOError.unsupportedSourcePin("DEF PIN '\(pin.name)' requires declared net and direction")
            }
            let layers = tech.layers.filter { $0.id == pin.layer }
            guard layers.count == 1 else { throw LayoutIOError.unsupportedSourcePin("Unresolved PIN layer") }
            let width = try grid(pin.size.width, units: units), height = try grid(pin.size.height, units: units)
            guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
                throw LayoutIOError.unsupportedSourcePin("DEF PIN rectangle cannot be represented exactly")
            }
            let directionValue: DEFPin.Direction
            switch direction {
            case .input: directionValue = .input
            case .output: directionValue = .output
            case .inout_: directionValue = .inout_
            case .feedthrough: directionValue = .feedthru
            }
            let use: DEFSpecialNet.NetUse
            switch pin.role {
            case .power: use = .power
            case .ground: use = .ground
            case .signal: use = .signal
            default: throw LayoutIOError.unsupportedSourcePin("Canonical device role is not a standard PIN use")
            }
            let metals = root.shapes.filter { $0.properties["def.pin.name"] == pin.name }
            guard metals.count <= 1 else { throw LayoutIOError.unsupportedSourcePin("Ambiguous source PIN annotations") }
            let metadata = metals.first?.properties ?? [:]
            let status: DEFComponent.PlacementStatus
            if let raw = metadata["def.pin.status"] {
                guard let value = DEFComponent.PlacementStatus(rawValue: raw), value != .unplaced else {
                    throw LayoutIOError.unsupportedSourcePin("Invalid source PIN status")
                }
                status = value
            } else { status = .placed }
            let properties: [DEFProperty]
            if let raw = metadata["def.pin.properties"] { properties = try JSONDecoder().decode([DEFProperty].self, from: Data(raw.utf8)) }
            else { properties = [] }
            return DEFPin(name: pin.name, direction: directionValue, netName: net.name, layerName: layers[0].id.name,
                x: try grid(pin.position.x, units: units), y: try grid(pin.position.y, units: units),
                orientation: .n, placementStatus: status, use: use,
                layerRects: [.init(layerName: layers[0].id.name, rects: [.init(x1: -width / 2, y1: -height / 2, x2: width / 2, y2: height / 2)])], special: metadata["def.pin.special"] == "true", properties: properties)
        }
    }
}
