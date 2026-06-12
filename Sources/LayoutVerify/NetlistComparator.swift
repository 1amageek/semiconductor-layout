import Foundation

public struct NetlistComparator: Sendable {
    public var relativeTolerance: Double

    public init(relativeTolerance: Double = 0.01) {
        self.relativeTolerance = relativeTolerance
    }

    public func compare(
        extracted: ComparisonNetlist,
        reference: ComparisonNetlist
    ) -> NetlistComparison {
        var unmatchedReference = Set(reference.devices.indices)
        var unmatchedExtracted: [ComparisonNetlist.Device] = []
        var parameterMismatches: [NetlistParameterMismatch] = []

        for extractedDevice in extracted.devices {
            // Candidates are scanned in ascending index order and a
            // parameter-exact candidate wins over the first topological
            // one, so the pairing (and therefore the mismatch report) is
            // deterministic even when several reference devices share a
            // topology key.
            let candidates = unmatchedReference
                .filter { topologyKey(reference.devices[$0]) == topologyKey(extractedDevice) }
                .sorted()
            guard let referenceIndex = candidates.first(where: {
                parametersMatch(extractedDevice.parameters, reference.devices[$0].parameters)
            }) ?? candidates.first else {
                unmatchedExtracted.append(extractedDevice)
                continue
            }
            unmatchedReference.remove(referenceIndex)
            let referenceDevice = reference.devices[referenceIndex]
            if !parametersMatch(extractedDevice.parameters, referenceDevice.parameters) {
                parameterMismatches.append(NetlistParameterMismatch(
                    extractedDeviceID: extractedDevice.id,
                    referenceDeviceID: referenceDevice.id,
                    extracted: extractedDevice.parameters,
                    reference: referenceDevice.parameters,
                    region: extractedDevice.region
                ))
            }
        }

        return NetlistComparison(
            unmatchedExtractedDevices: unmatchedExtracted.sorted { $0.id < $1.id },
            unmatchedReferenceDevices: unmatchedReference
                .map { reference.devices[$0] }
                .sorted { $0.id < $1.id },
            parameterMismatches: parameterMismatches.sorted {
                if $0.extractedDeviceID != $1.extractedDeviceID {
                    return $0.extractedDeviceID < $1.extractedDeviceID
                }
                return $0.referenceDeviceID < $1.referenceDeviceID
            },
            referenceDeviceCount: reference.devices.count
        )
    }

    private struct TopologyKey: Hashable {
        var kind: ComparisonDeviceKind
        var gate: ComparisonNetID?
        var sourceDrain: [ComparisonNetID]
        var bulk: ComparisonNetID?
    }

    private func topologyKey(_ device: ComparisonNetlist.Device) -> TopologyKey {
        let source = device.terminals[.source]
        let drain = device.terminals[.drain]
        return TopologyKey(
            kind: device.kind,
            gate: device.terminals[.gate],
            sourceDrain: [source, drain].compactMap { $0 }.sorted(),
            bulk: device.terminals[.bulk]
        )
    }

    private func parametersMatch(
        _ extracted: ComparisonDeviceParameters,
        _ reference: ComparisonDeviceParameters
    ) -> Bool {
        extracted.multiplier == reference.multiplier
            && nearlyEqual(extracted.width, reference.width)
            && nearlyEqual(extracted.length, reference.length)
    }

    private func nearlyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = max(abs(lhs), abs(rhs), 1e-12)
        return abs(lhs - rhs) <= scale * relativeTolerance
    }
}
