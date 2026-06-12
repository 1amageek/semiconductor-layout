import SwiftUI

/// Always-on trust panel: every verification axis with its live verdict,
/// staleness, and — crucially — what is NOT being verified.
public struct LayoutTrustDashboard: View {
    @Bindable var viewModel: LayoutEditorViewModel

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let report = viewModel.trustReport
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                Text("Trust").font(.caption.bold())
                if report.verificationPending {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.yellow)
                        .help("In-place gesture edits have not re-verified yet.")
                }
            }
            axisRow("DRC", report.drc, extra: report.staleDRCKinds.isEmpty
                ? nil
                : "stale: \(report.staleDRCKinds.joined(separator: ", "))")
            axisRow("Connect", report.connectivity)
            axisRow("Constraint", report.constraints)
            axisRow("LVS", report.lvs)
            axisRow("Electrical", report.electrical)
        }
        .padding(10)
        .frame(width: 180, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    @ViewBuilder
    private func axisRow(
        _ name: String,
        _ verdict: LayoutTrustReport.AxisVerdict,
        extra: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            switch verdict {
            case .clean:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(name).font(.caption2)
            case .findings(let count):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("\(name): \(count)").font(.caption2)
            case .unavailable(let reason):
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
                Text(name).font(.caption2).foregroundStyle(.secondary)
                    .help(reason)
            }
            Spacer(minLength: 0)
        }
        if let extra {
            Text(extra)
                .font(.caption2)
                .foregroundStyle(.yellow)
                .padding(.leading, 18)
        }
    }
}
