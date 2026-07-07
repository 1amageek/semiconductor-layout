import LayoutCore
import LayoutVerify

extension LayoutCommandRunner {
    func countElements(in document: LayoutDocument) -> (
        cells: Int,
        shapes: Int,
        vias: Int,
        labels: Int,
        nets: Int
    ) {
        (
            cells: document.cells.count,
            shapes: document.cells.reduce(0) { $0 + $1.shapes.count },
            vias: document.cells.reduce(0) { $0 + $1.vias.count },
            labels: document.cells.reduce(0) { $0 + $1.labels.count },
            nets: document.cells.reduce(0) { $0 + $1.nets.count }
        )
    }

    func resultStatus(for pendingArtifacts: [PendingCommandArtifact]) -> String {
        let statuses = pendingArtifacts.compactMap(\.status)
        if statuses.contains(where: Self.isFailedStatus) {
            return "failed"
        }
        if statuses.contains(where: Self.isPartialStatus) {
            return "partial"
        }
        return "passed"
    }

    func finishNetExplicitStatus(routeViolations: [LayoutViolation]) -> String {
        routeViolations.isEmpty ? "passed" : "failed"
    }

    func finishNetPlanStatus(
        plan: HeadlessFinishNetPlan,
        routeViolations: [LayoutViolation]
    ) -> String {
        if plan.opensAfter == 0, plan.shortsAfter == 0, routeViolations.isEmpty {
            return "passed"
        }
        if plan.opensAfter < plan.opensBefore, plan.shortsAfter == plan.shortsBefore, routeViolations.isEmpty {
            return "partial"
        }
        return "failed"
    }

    func finishNetPlanVerificationStatus(_ status: String) -> String {
        switch status {
        case "passed":
            return "open-net-auto-route-verified"
        case "partial":
            return "open-net-auto-route-partial"
        default:
            return "open-net-auto-route-failed"
        }
    }

    private static func isFailedStatus(_ status: String) -> Bool {
        switch status {
        case "failed", "error":
            return true
        default:
            return false
        }
    }

    private static func isPartialStatus(_ status: String) -> Bool {
        switch status {
        case "partial", "budget_exhausted", "fixed_point_with_residuals":
            return true
        default:
            return false
        }
    }
}
