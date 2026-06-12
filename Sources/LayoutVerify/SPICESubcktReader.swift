import Foundation
import LayoutCore

public enum SPICESubcktReaderError: Error, Equatable, Sendable {
    case missingSubcircuit(String)
    case unterminatedSubcircuit(String)
    case malformedCard(line: Int, text: String)
    case unknownModel(String)
    case unresolvedSubcircuit(String)
    case recursionTooDeep(String)
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
        try expand(
            block: target,
            blocks: blocks,
            netMap: Dictionary(uniqueKeysWithValues: target.ports.map { ($0, netID(for: $0)) }),
            instancePath: "",
            depth: 0,
            into: &devices
        )
        let ports = Dictionary(
            uniqueKeysWithValues: target.ports.map { ($0, netID(for: $0)) }
        )
        return ComparisonNetlist(devices: devices, ports: ports)
    }

    // MARK: - Parsing

    private struct Block {
        var name: String
        var ports: [String]
        var cards: [(line: Int, fields: [String])]
    }

    private func parseBlocks(_ text: String) throws -> [String: Block] {
        // Fold + continuations, drop comments and blanks.
        var logical: [(line: Int, text: String)] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("*") else { continue }
            if line.hasPrefix("+"), !logical.isEmpty {
                logical[logical.count - 1].text += " " + line.dropFirst().trimmingCharacters(in: .whitespaces)
            } else {
                logical.append((index + 1, line))
            }
        }

        var blocks: [String: Block] = [:]
        var current: Block? = nil
        for (lineNumber, line) in logical {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let keyword = fields[0].lowercased()
            if keyword == ".subckt" {
                guard fields.count >= 2 else {
                    throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
                }
                current = Block(
                    name: fields[1].lowercased(),
                    ports: Array(fields.dropFirst(2)).map { $0.lowercased() },
                    cards: []
                )
                continue
            }
            if keyword == ".ends" {
                guard let block = current else {
                    throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
                }
                blocks[block.name] = block
                current = nil
                continue
            }
            if keyword.hasPrefix(".") {
                // Control cards outside the supported subset.
                if current != nil {
                    throw SPICESubcktReaderError.malformedCard(line: lineNumber, text: line)
                }
                continue
            }
            guard current != nil else { continue }
            current?.cards.append((lineNumber, fields))
        }
        if let unterminated = current {
            throw SPICESubcktReaderError.unterminatedSubcircuit(unterminated.name)
        }
        return blocks
    }

    // MARK: - Expansion

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
            let card = fields[0]
            switch card.lowercased().first {
            case "m":
                guard fields.count >= 6 else {
                    throw SPICESubcktReaderError.malformedCard(
                        line: lineNumber, text: fields.joined(separator: " ")
                    )
                }
                let model = fields[5].lowercased()
                guard let kind = modelKinds[model] else {
                    throw SPICESubcktReaderError.unknownModel(model)
                }
                var width = 0.0
                var length = 0.0
                var multiplier = 1
                for parameter in fields.dropFirst(6) {
                    let parts = parameter.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else {
                        throw SPICESubcktReaderError.malformedCard(
                            line: lineNumber, text: parameter
                        )
                    }
                    let value = try number(String(parts[1]), line: lineNumber)
                    switch parts[0].lowercased() {
                    case "w": width = value * 1e6
                    case "l": length = value * 1e6
                    case "m", "nf": multiplier = Int(value.rounded())
                    default:
                        // Unknown device parameters (ad, as, pd, ...) do
                        // not change the compared quantities.
                        continue
                    }
                }
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
                        width: width,
                        length: length,
                        multiplier: multiplier
                    ),
                    region: .zero
                ))
            case "x":
                guard fields.count >= 2 else {
                    throw SPICESubcktReaderError.malformedCard(
                        line: lineNumber, text: fields.joined(separator: " ")
                    )
                }
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
            default:
                throw SPICESubcktReaderError.malformedCard(
                    line: lineNumber, text: fields.joined(separator: " ")
                )
            }
        }
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

    private func number(_ text: String, line: Int) throws -> Double {
        let lowered = text.lowercased()
        let suffixes: [(String, Double)] = [
            ("meg", 1e6), ("t", 1e12), ("g", 1e9), ("k", 1e3),
            ("m", 1e-3), ("u", 1e-6), ("n", 1e-9), ("p", 1e-12), ("f", 1e-15),
        ]
        for (suffix, scale) in suffixes {
            if lowered.hasSuffix(suffix),
               let value = Double(lowered.dropLast(suffix.count)) {
                return value * scale
            }
        }
        if let value = Double(lowered) { return value }
        throw SPICESubcktReaderError.malformedCard(line: line, text: text)
    }
}
