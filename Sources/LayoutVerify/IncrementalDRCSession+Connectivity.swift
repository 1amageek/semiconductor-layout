import Foundation
import LayoutCore

extension IncrementalDRCSession {
    func nativeSnapshot() throws -> LayoutConductorSnapshot {
        guard let native = nativeConnectivity else { throw LayoutConductorCaptureError.invalidComposition }
        return native.currentSnapshot
    }

    func refreshElectricalBuckets(snapshot: LayoutConductorSnapshot,
        affectedNets: Set<LayoutConductorSnapshot.NetReference>? = nil) {
        let violations = service.electricalViolations(snapshot: snapshot)
        shortViolations = violations.filter { $0.kind == .overlapShort }
        if let affectedNets {
            for net in affectedNets { openByNet[net] = nil }
        } else { openByNet = [:] }
        for violation in violations where violation.kind == .disconnectedOpen {
            guard let net = violation.netReferences.first,
                  affectedNets.map({ $0.contains(net) }) ?? true else { continue }
            openByNet[net, default: []].append(violation)
        }
    }
}
