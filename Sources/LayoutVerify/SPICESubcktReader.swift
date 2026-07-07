import Foundation
import LayoutCore

public enum SPICESubcktReaderError: Error, Equatable, Sendable {
    case missingSubcircuit(String)
    case duplicateSubcircuit(String)
    case duplicatePort(subcircuit: String, port: String)
    case mismatchedSubcircuitEnd(expected: String, observed: String)
    case unterminatedSubcircuit(String)
    case malformedCard(line: Int, text: String)
    case unknownModel(String)
    case unresolvedSubcircuit(String)
    case recursionTooDeep(String)
    case missingDeviceParameter(instance: String, parameter: String)
    case invalidDeviceParameter(instance: String, parameter: String, value: String)
    case noSubcircuitsFound
}

/// Minimal SPICE `.subckt` reader for LVS reference netlists.
///
/// Deliberately narrow: `.subckt`/`.ends` blocks containing MOSFET `M`
/// cards and subcircuit `X` instances (expanded recursively). Anything
/// else — other device cards, control lines, parameter expressions — is
/// a typed error, never silently skipped: a reference netlist that the
/// reader cannot fully represent must not silently compare as smaller
/// than it is. Comments (`*`) and blank lines are ignored; `+`
/// continuations are folded.
///
/// Net naming convention: a subcircuit net named `A` becomes the
/// comparison net `pin:A`, matching how the device extractor names
/// layout islands carrying an undeclared pin of that name. Geometry W/L
/// values are SPICE meters (with the usual engineering suffixes) and are
/// converted to the extractor's micron unit.
public struct SPICESubcktReader: Sendable {

    public var modelKinds: [String: ComparisonDeviceKind]

    public init(
        modelKinds: [String: ComparisonDeviceKind] = ["nmos": .nmos, "pmos": .pmos]
    ) {
        self.modelKinds = modelKinds
    }

    /// Reads `text` and returns the comparison netlist of `subcircuit`
    /// (or of the only subcircuit when nil), with X instances expanded.
    public func read(_ text: String, subcircuit name: String? = nil) throws -> ComparisonNetlist {
        let blocks = try parseBlocks(text)
        guard !blocks.isEmpty else { throw SPICESubcktReaderError.noSubcircuitsFound }
        let targetName: String
        if let name {
            targetName = name.lowercased()
        } else if blocks.count == 1, let only = blocks.keys.first {
            targetName = only
        } else {
            throw SPICESubcktReaderError.missingSubcircuit(
                "multiple subcircuits; specify one of: \(blocks.keys.sorted().joined(separator: ", "))"
            )
        }
        guard let target = blocks[targetName] else {
            throw SPICESubcktReaderError.missingSubcircuit(targetName)
        }

        var devices: [ComparisonNetlist.Device] = []
        let targetPortMap = portMap(for: target.ports)
        try expand(
            block: target,
            blocks: blocks,
            netMap: targetPortMap,
            instancePath: "",
            depth: 0,
            into: &devices
        )
        return ComparisonNetlist(devices: devices, ports: targetPortMap)
    }

    // MARK: - Parsing

    private struct Block {
        var name: String
        var ports: [String]
        var cards: [(line: Int, fields: [String])]
    }

    private struct LogicalLine {
        var line: Int
        var text: String
    }

    private func parseBlocks(_ text: String) throws -> [String: Block] {
        var blocks: [String: Block] = [:]
        var current: Block? = nil
        for logicalLine in try logicalLines(from: text) {
            try parseBlockLine(logicalLine, blocks: &blocks, current: &current)
        }
        if let unterminated = current {
            throw SPICESubcktReaderError.unterminatedSubcircuit(unterminated.name)
        }
        return blocks
    }

    private func parseBlockLine(
        _ logicalLine: LogicalLine,
        blocks: inout [String: Block],
        current: inout Block?
    ) throws {
        let lineNumber = logicalLine.line
        let line = logicalLine.text
        let fields = fields(from: line)
        let keyword = fields[0].lowercased()
        if keyword == ".subckt" {
            try startBlock(fields: fields, lineNumber: lineNumber, line: line, blocks: blocks, current: &current)
        } else if keyword == ".ends" {
            try finishBlock(fields: fields, lineNumber: lineNumber, line: line, blocks: &blocks, current: &current)
        } else if keyword.hasPrefix(".") {
            try acceptControlLineOutsideSubckt(lineNumber: lineNumber, line: line, current: current)
        } else {
            try appendDeviceCard(fields: fields, lineNumber: lineNumber, line: line, current: &current)
        }
    }

    private func startBlock(
        fields: [String],
        lineNumber: Int,
        line: String,
        blocks: [String: Block],
        current: inout Block?
    ) throws {
        guard current == nil else {
            throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
        }
        let block = try makeBlock(fields: fields, lineNumber: lineNumber, line: line)
        guard blocks[block.name] == nil else {
            throw SPICESubcktReaderError.duplicateSubcircuit(block.name)
        }
        current = block
    }

    private func finishBlock(
        fields: [String],
        lineNumber: Int,
        line: String,
        blocks: inout [String: Block],
        current: inout Block?
    ) throws {
        guard let block = current else {
            throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
        }
        try validateEndCard(fields: fields, lineNumber: lineNumber, line: line, block: block)
        guard blocks[block.name] == nil else {
            throw SPICESubcktReaderError.duplicateSubcircuit(block.name)
        }
        blocks[block.name] = block
        current = nil
    }

    private func validateEndCard(
        fields: [String],
        lineNumber: Int,
        line: String,
        block: Block
    ) throws {
        guard fields.count <= 2 else {
            throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
        }
        guard fields.count == 2 else { return }
        let observed = fields[1].lowercased()
        guard observed == block.name else {
            throw SPICESubcktReaderError.mismatchedSubcircuitEnd(
                expected: block.name,
                observed: observed
            )
        }
    }

    private func acceptControlLineOutsideSubckt(
        lineNumber: Int,
        line: String,
        current: Block?
    ) throws {
        if current != nil {
            throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
        }
    }

    private func appendDeviceCard(
        fields: [String],
        lineNumber: Int,
        line: String,
        current: inout Block?
    ) throws {
        guard var block = current else {
            throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
        }
        block.cards.append((lineNumber, fields))
        current = block
    }

    private func logicalLines(from text: String) throws -> [LogicalLine] {
        var result: [LogicalLine] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("*") else { continue }
            if line.hasPrefix("+") {
                guard !result.isEmpty else {
                    throw SPICESubcktReaderError.malformedCard(line: index + 1, text: line)
                }
                let continuation = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard !continuation.isEmpty else {
                    throw SPICESubcktReaderError.malformedCard(line: index + 1, text: line)
                }
                result[result.count - 1].text += " " + continuation
            } else {
                result.append(LogicalLine(line: index + 1, text: line))
            }
        }
        return result
    }

    private func makeBlock(
        fields: [String],
        lineNumber: Int,
        line: String
    ) throws -> Block {
        guard fields.count >= 2 else {
            throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
        }
        let name = fields[1].lowercased()
        let ports = Array(fields.dropFirst(2)).map { $0.lowercased() }
        var seenPorts: Set<String> = []
        for port in ports {
            guard seenPorts.insert(port).inserted else {
                throw SPICESubcktReaderError.duplicatePort(subcircuit: name, port: port)
            }
        }
        return Block(name: name, ports: ports, cards: [])
    }

    private func fields(from line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    // MARK: - Expansion

    private struct MOSParameters {
        var width: Double
        var length: Double
        var multiplier: Int
    }

    private struct MOSParameterAccumulator {
        var width: Double?
        var length: Double?
        var multiplier = 1
    }

    private func expand(
        block: Block,
        blocks: [String: Block],
        netMap: [String: ComparisonNetID],
        instancePath: String,
        depth: Int,
        into devices: inout [ComparisonNetlist.Device]
    ) throws {
        guard depth < 16 else {
            throw SPICESubcktReaderError.recursionTooDeep(block.name)
        }
        for (lineNumber, fields) in block.cards {
            try expandCard(
                lineNumber: lineNumber,
                fields: fields,
                blocks: blocks,
                netMap: netMap,
                instancePath: instancePath,
                depth: depth,
                into: &devices
            )
        }
    }

    private func expandCard(
        lineNumber: Int,
        fields: [String],
        blocks: [String: Block],
        netMap: [String: ComparisonNetID],
        instancePath: String,
        depth: Int,
        into devices: inout [ComparisonNetlist.Device]
    ) throws {
        let card = fields[0]
        switch card.lowercased().first {
        case "m":
            try expandMOS(
                lineNumber: lineNumber,
                fields: fields,
                netMap: netMap,
                instancePath: instancePath,
                into: &devices
            )
        case "x":
            try expandInstance(
                lineNumber: lineNumber,
                fields: fields,
                blocks: blocks,
                netMap: netMap,
                instancePath: instancePath,
                depth: depth,
                into: &devices
            )
        default:
            throw SPICESubcktReaderError.malformedCard(
                line: lineNumber, text: fields.joined(separator: " ")
            )
        }
    }

    private func expandMOS(
        lineNumber: Int,
        fields: [String],
        netMap: [String: ComparisonNetID],
        instancePath: String,
        into devices: inout [ComparisonNetlist.Device]
    ) throws {
        guard fields.count >= 6 else {
            throw SPICESubcktReaderError.malformedCard(
                line: lineNumber, text: fields.joined(separator: " ")
            )
        }
        let card = fields[0]
        let model = fields[5].lowercased()
        guard let kind = modelKinds[model] else {
            throw SPICESubcktReaderError.unknownModel(model)
        }
        let parameters = try mosParameters(
            fields: fields,
            lineNumber: lineNumber,
            instanceID: instancePath + card
        )
        let terminals: [ComparisonTerminalRole: ComparisonNetID] = [
            .drain: try resolve(fields[1], netMap: netMap, instancePath: instancePath),
            .gate: try resolve(fields[2], netMap: netMap, instancePath: instancePath),
            .source: try resolve(fields[3], netMap: netMap, instancePath: instancePath),
            .bulk: try resolve(fields[4], netMap: netMap, instancePath: instancePath),
        ]
        devices.append(ComparisonNetlist.Device(
            id: instancePath + card,
            kind: kind,
            terminals: terminals,
            parameters: ComparisonDeviceParameters(
                width: parameters.width,
                length: parameters.length,
                multiplier: parameters.multiplier
            ),
            region: .zero
        ))
    }

    private func expandInstance(
        lineNumber: Int,
        fields: [String],
        blocks: [String: Block],
        netMap: [String: ComparisonNetID],
        instancePath: String,
        depth: Int,
        into devices: inout [ComparisonNetlist.Device]
    ) throws {
        guard fields.count >= 2 else {
            throw SPICESubcktReaderError.malformedCard(
                line: lineNumber, text: fields.joined(separator: " ")
            )
        }
        let card = fields[0]
        let childName = fields[fields.count - 1].lowercased()
        guard let child = blocks[childName] else {
            throw SPICESubcktReaderError.unresolvedSubcircuit(childName)
        }
        let actuals = Array(fields.dropFirst().dropLast())
        guard actuals.count == child.ports.count else {
            throw SPICESubcktReaderError.malformedCard(
                line: lineNumber, text: fields.joined(separator: " ")
            )
        }
        var childMap: [String: ComparisonNetID] = [:]
        for (port, actual) in zip(child.ports, actuals) {
            childMap[port] = try resolve(actual, netMap: netMap, instancePath: instancePath)
        }
        try expand(
            block: child,
            blocks: blocks,
            netMap: childMap,
            instancePath: instancePath + card + "/",
            depth: depth + 1,
            into: &devices
        )
    }

    private func mosParameters(
        fields: [String],
        lineNumber: Int,
        instanceID: String
    ) throws -> MOSParameters {
        var accumulator = MOSParameterAccumulator()
        for parameter in fields.dropFirst(6) {
            try applyMOSParameter(
                parameter,
                lineNumber: lineNumber,
                instanceID: instanceID,
                accumulator: &accumulator
            )
        }
        return try completedMOSParameters(accumulator, instanceID: instanceID)
    }

    private func applyMOSParameter(
        _ parameter: String,
        lineNumber: Int,
        instanceID: String,
        accumulator: inout MOSParameterAccumulator
    ) throws {
        let parts = parameter.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else {
            throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: parameter)
        }
        let key = String(parts[0]).lowercased()
        let rawValue = String(parts[1])
        let value = try number(rawValue, line: lineNumber)
        switch key {
        case "w":
            accumulator.width = try positiveMicrons(
                value: value,
                rawValue: rawValue,
                instanceID: instanceID,
                parameter: key
            )
        case "l":
            accumulator.length = try positiveMicrons(
                value: value,
                rawValue: rawValue,
                instanceID: instanceID,
                parameter: key
            )
        case "m", "nf":
            accumulator.multiplier = try positiveInteger(
                value: value,
                rawValue: rawValue,
                instanceID: instanceID,
                parameter: key
            )
        default:
            return
        }
    }

    private func completedMOSParameters(
        _ accumulator: MOSParameterAccumulator,
        instanceID: String
    ) throws -> MOSParameters {
        let width = try requiredMOSParameter(
            accumulator.width,
            instanceID: instanceID,
            parameter: "w"
        )
        let length = try requiredMOSParameter(
            accumulator.length,
            instanceID: instanceID,
            parameter: "l"
        )
        return MOSParameters(width: width, length: length, multiplier: accumulator.multiplier)
    }

    private func requiredMOSParameter(
        _ value: Double?,
        instanceID: String,
        parameter: String
    ) throws -> Double {
        guard let value else {
            throw SPICESubcktReaderError.missingDeviceParameter(
                instance: instanceID,
                parameter: parameter
            )
        }
        return value
    }

    private func positiveMicrons(
        value: Double,
        rawValue: String,
        instanceID: String,
        parameter: String
    ) throws -> Double {
        guard value.isFinite, value > 0 else {
            throw SPICESubcktReaderError.invalidDeviceParameter(
                instance: instanceID,
                parameter: parameter,
                value: rawValue
            )
        }
        return value * 1e6
    }

    private func positiveInteger(
        value: Double,
        rawValue: String,
        instanceID: String,
        parameter: String
    ) throws -> Int {
        guard value.isFinite,
              value > 0,
              value <= Double(Int.max),
              value.rounded(.towardZero) == value else {
            throw SPICESubcktReaderError.invalidDeviceParameter(
                instance: instanceID,
                parameter: parameter,
                value: rawValue
            )
        }
        return Int(value)
    }

    /// Port nets map through the instance boundary; internal nets get a
    /// path-qualified name so two instances of one subcircuit never merge.
    private func resolve(
        _ net: String,
        netMap: [String: ComparisonNetID],
        instancePath: String
    ) throws -> ComparisonNetID {
        let key = net.lowercased()
        if let mapped = netMap[key] { return mapped }
        return netID(for: instancePath.isEmpty ? key : instancePath + key)
    }

    private func netID(for name: String) -> ComparisonNetID {
        ComparisonNetID("pin:\(name)")
    }

    private func portMap(for ports: [String]) -> [String: ComparisonNetID] {
        var map: [String: ComparisonNetID] = [:]
        for port in ports {
            map[port] = netID(for: port)
        }
        return map
    }

    private func number(_ text: String, line: Int) throws -> Double {
        let lowered = text.lowercased()
        let suffixes: [(String, Double)] = [
            ("meg", 1e6), ("t", 1e12), ("g", 1e9), ("k", 1e3),
            ("m", 1e-3), ("u", 1e-6), ("n", 1e-9), ("p", 1e-12), ("f", 1e-15),
        ]
        for (suffix, scale) in suffixes {
            if lowered.hasSuffix(suffix),
               let value = Double(lowered.dropLast(suffix.count)),
               value.isFinite {
                return value * scale
            }
        }
        if let value = Double(lowered), value.isFinite { return value }
        throw SPICESubcktReaderError.malformedCard(line: line, text: text)
    }
}
