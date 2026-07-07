import Foundation
import LayoutCore
import LayoutTech

extension IncrementalDRCSession {
    func setBucket(
        _ buckets: inout [LayoutLayerID: [LayoutViolation]],
        _ layer: LayoutLayerID,
        _ violations: [LayoutViolation]
    ) {
        buckets[layer] = violations.isEmpty ? nil : violations
    }

    static func layerOrder(_ a: LayoutLayerID, _ b: LayoutLayerID) -> Bool {
        if a.name != b.name { return a.name < b.name }
        return a.purpose < b.purpose
    }

    func assembleResult() -> LayoutDRCResult {
        var violations: [LayoutViolation] = []
        violations += terminalConflictViolations
        for layer in coverageByLayer.keys.sorted(by: Self.layerOrder) {
            violations += coverageByLayer[layer] ?? []
        }
        violations += forbiddenLayerViolations
        for layer in rectOnlyByLayer.keys.sorted(by: Self.layerOrder) {
            violations += rectOnlyByLayer[layer] ?? []
        }
        for layer in angleByLayer.keys.sorted(by: Self.layerOrder) {
            violations += angleByLayer[layer] ?? []
        }
        let clusterLayers = clusterStateByLayer.keys.sorted(by: Self.layerOrder)
        for layer in clusterLayers {
            guard let state = clusterStateByLayer[layer] else { continue }
            for clusterKey in state.widthAreaByCluster.keys.sorted() {
                violations += state.widthAreaByCluster[clusterKey] ?? []
            }
        }
        for layer in clusterLayers {
            guard let state = clusterStateByLayer[layer] else { continue }
            for clusterKey in state.spacingByCluster.keys.sorted() {
                violations += state.spacingByCluster[clusterKey] ?? []
            }
        }
        for ruleID in spacingByRuleID.keys.sorted() {
            violations += spacingByRuleID[ruleID] ?? []
        }
        for ruleID in enclosureByRuleID.keys.sorted() {
            violations += enclosureByRuleID[ruleID] ?? []
        }
        violations += viaEnclosureViolations
        violations += minimumCutViolations
        violations += exactOverlapViolations
        for layer in densityStateByLayer.keys.sorted(by: Self.layerOrder) {
            guard let state = densityStateByLayer[layer] else { continue }
            for windowIndex in state.violationByWindow.keys.sorted() {
                if let violation = state.violationByWindow[windowIndex] {
                    violations.append(violation)
                }
            }
        }
        violations += shortViolations
        for netID in openByNet.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            violations += openByNet[netID] ?? []
        }
        violations += antennaViolations
        return LayoutDRCResult(violations: violations)
    }
}
