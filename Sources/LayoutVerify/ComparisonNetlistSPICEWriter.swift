import Foundation

/// Serializes a ``ComparisonNetlist`` as a SPICE `.subckt` for external
/// tools — most importantly the Netgen agreement gate, which cross-checks
/// the in-process comparator's verdict against Netgen's on the same pair.
///
/// Net tokens are sanitized deterministically (one token per distinct
/// net, collisions uniquified), so two netlists written by this writer
/// use consistent naming and compare structurally.
public struct ComparisonNetlistSPICEWriter: Sendable {

    public init() {}

    public func write(_ netlist: ComparisonNetlist, name: String) -> String {
        var tokens: [ComparisonNetID: String] = [:]
        var used: Set<String> = []
        func token(_ net: ComparisonNetID) -> String {
            if let existing = tokens[net] { return existing }
            var sanitized = String(net.rawValue.map { character in
                character.isLetter || character.isNumber || character == "_" ? character : "_"
            })
            if sanitized.isEmpty || (sanitized.first?.isNumber ?? false) {
                sanitized = "n" + sanitized
            }
            var candidate = sanitized
            var counter = 1
            while used.contains(candidate) {
                candidate = "\(sanitized)_\(counter)"
                counter += 1
            }
            used.insert(candidate)
            tokens[net] = candidate
            return candidate
        }

        var portTokens: [String] = []
        var seenPorts: Set<String> = []
        for portName in netlist.ports.keys.sorted() {
            guard let net = netlist.ports[portName] else { continue }
            let portToken = token(net)
            if seenPorts.insert(portToken).inserted {
                portTokens.append(portToken)
            }
        }

        var lines: [String] = []
        lines.append(".subckt \(name) \(portTokens.joined(separator: " "))")
        for (index, device) in netlist.devices
            .sorted(by: { $0.id < $1.id })
            .enumerated() {
            let model: String
            switch device.kind {
            case .nmos: model = "nmos"
            case .pmos: model = "pmos"
            }
            let drain = device.terminals[.drain].map(token) ?? "unconnected_d\(index)"
            let gate = device.terminals[.gate].map(token) ?? "unconnected_g\(index)"
            let source = device.terminals[.source].map(token) ?? "unconnected_s\(index)"
            let bulk = device.terminals[.bulk].map(token) ?? "unconnected_b\(index)"
            lines.append(
                "M\(index) \(drain) \(gate) \(source) \(bulk) \(model) "
                    + "W=\(format(device.parameters.width))u "
                    + "L=\(format(device.parameters.length))u "
                    + "M=\(device.parameters.multiplier)"
            )
        }
        lines.append(".ends")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.6g", value)
    }
}
