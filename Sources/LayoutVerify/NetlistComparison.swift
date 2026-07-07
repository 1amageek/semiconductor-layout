import Foundation
import LayoutCore

public struct NetlistParameterMismatch: Hashable, Sendable, Codable {
    public var extractedDeviceID: String
    public var referenceDeviceID: String
    public var extracted: ComparisonDeviceParameters
    public var reference: ComparisonDeviceParameters
    public var region: LayoutRect

    public init(
        extractedDeviceID: String,
        referenceDeviceID: String,
        extracted: ComparisonDeviceParameters,
        reference: ComparisonDeviceParameters,
        region: LayoutRect
    ) {
        self.extractedDeviceID = extractedDeviceID
        self.referenceDeviceID = referenceDeviceID
        self.extracted = extracted
        self.reference = reference
        self.region = region
    }
}

public struct NetlistPortMismatch: Hashable, Sendable, Codable {
    public var portName: String
    public var extracted: ComparisonNetID?
    public var reference: ComparisonNetID?

    public init(
        portName: String,
        extracted: ComparisonNetID?,
        reference: ComparisonNetID?
    ) {
        self.portName = portName
        self.extracted = extracted
        self.reference = reference
    }
}

public struct NetlistComparison: Hashable, Sendable, Codable {
    public var unmatchedExtractedDevices: [ComparisonNetlist.Device]
    public var unmatchedReferenceDevices: [ComparisonNetlist.Device]
    public var parameterMismatches: [NetlistParameterMismatch]
    public var portMismatches: [NetlistPortMismatch]
    /// Total device count of the reference netlist — the denominator of
    /// the SDL convergence meter.
    public var referenceDeviceCount: Int

    public init(
        unmatchedExtractedDevices: [ComparisonNetlist.Device] = [],
        unmatchedReferenceDevices: [ComparisonNetlist.Device] = [],
        parameterMismatches: [NetlistParameterMismatch] = [],
        portMismatches: [NetlistPortMismatch] = [],
        referenceDeviceCount: Int = 0
    ) {
        self.unmatchedExtractedDevices = unmatchedExtractedDevices
        self.unmatchedReferenceDevices = unmatchedReferenceDevices
        self.parameterMismatches = parameterMismatches
        self.portMismatches = portMismatches
        self.referenceDeviceCount = referenceDeviceCount
    }

    public var passed: Bool {
        unmatchedExtractedDevices.isEmpty
            && unmatchedReferenceDevices.isEmpty
            && parameterMismatches.isEmpty
            && portMismatches.isEmpty
    }

    /// Reference devices with a topological match in the layout.
    public var matchedReferenceDeviceCount: Int {
        referenceDeviceCount - unmatchedReferenceDevices.count
    }
}
