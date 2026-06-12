import Foundation
import LayoutCore

public struct ComparisonNetID: Hashable, Sendable, Codable, Comparable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ComparisonDeviceKind: String, Hashable, Sendable, Codable {
    case nmos
    case pmos
}

public enum ComparisonTerminalRole: String, Hashable, Sendable, Codable, CaseIterable {
    case gate
    case source
    case drain
    case bulk
}

public struct ComparisonDeviceParameters: Hashable, Sendable, Codable {
    public var width: Double
    public var length: Double
    public var multiplier: Int

    public init(width: Double, length: Double, multiplier: Int = 1) {
        self.width = width
        self.length = length
        self.multiplier = multiplier
    }
}

public struct ComparisonNetlist: Hashable, Sendable, Codable {
    public struct Device: Hashable, Sendable, Codable {
        public var id: String
        public var kind: ComparisonDeviceKind
        public var terminals: [ComparisonTerminalRole: ComparisonNetID]
        public var parameters: ComparisonDeviceParameters
        public var region: LayoutRect

        public init(
            id: String,
            kind: ComparisonDeviceKind,
            terminals: [ComparisonTerminalRole: ComparisonNetID],
            parameters: ComparisonDeviceParameters,
            region: LayoutRect
        ) {
            self.id = id
            self.kind = kind
            self.terminals = terminals
            self.parameters = parameters
            self.region = region
        }
    }

    public var devices: [Device]
    public var ports: [String: ComparisonNetID]

    public init(devices: [Device], ports: [String: ComparisonNetID] = [:]) {
        self.devices = devices
        self.ports = ports
    }
}
