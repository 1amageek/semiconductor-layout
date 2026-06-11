import SwiftUI
import LayoutVerify

/// Compact bar displaying DRC violation and connectivity summary at the
/// bottom of the layout editor.
///
/// Shows a summary row with violation count plus a live connectivity chip
/// (shorts / opens). Expands to reveal individual violation messages.
public struct LayoutDiagnosticsBar: View {
    let violations: [LayoutViolation]
    let staleKinds: Set<LayoutViolationKind>
    let connectivity: ConnectivityAnalysis?
    let constraintViolations: [LayoutConstraintViolation]
    @State private var isExpanded = false

    public init(
        violations: [LayoutViolation],
        staleKinds: Set<LayoutViolationKind> = [],
        connectivity: ConnectivityAnalysis? = nil,
        constraintViolations: [LayoutConstraintViolation] = []
    ) {
        self.violations = violations
        self.staleKinds = staleKinds
        self.connectivity = connectivity
        self.constraintViolations = constraintViolations
    }

    public var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Label(
                        "\(violations.count) violation\(violations.count == 1 ? "" : "s")",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    if !staleKinds.isEmpty {
                        Label(staleSummary, systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .help("These checks have not re-verified since the last edit; run DRC to refresh them.")
                    }
                    connectivityChip
                    constraintChip
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        connectivityRows
                        constraintRows
                        ForEach(violations.prefix(50)) { violation in
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                    .frame(width: 16)
                                Text(violation.message)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if let layer = violation.layer {
                                    Text(layer.name)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                        if violations.count > 50 {
                            Text("\(violations.count - 50) more...")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .background(.bar)
    }

    /// Live extraction verdict: shorts and opens with severity colors, or
    /// an explicit "off" marker when no analysis is available — never an
    /// implied clean.
    @ViewBuilder
    private var connectivityChip: some View {
        if let connectivity {
            if connectivity.shorts.isEmpty && connectivity.opens.isEmpty {
                Label("\(connectivity.nets.count) nets", systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.green)
                    .help("Live connectivity: no shorts, no opens.")
            } else {
                Label(
                    "\(connectivity.shorts.count) short\(connectivity.shorts.count == 1 ? "" : "s") · \(connectivity.opens.count) open\(connectivity.opens.count == 1 ? "" : "s")",
                    systemImage: "bolt.trianglebadge.exclamationmark"
                )
                .foregroundStyle(connectivity.shorts.isEmpty ? .yellow : .red)
                .help("Live connectivity: conductor pieces carrying several nets (shorts) or nets split into islands (opens).")
            }
        } else {
            Label("connectivity off", systemImage: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.tertiary)
                .help("Live connectivity extraction is unavailable.")
        }
    }

    /// Expanded rows for each live short and open.
    @ViewBuilder
    private var connectivityRows: some View {
        if let connectivity {
            ForEach(Array(connectivity.shorts.enumerated()), id: \.offset) { _, short in
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .frame(width: 16)
                    Text("Short: one conductor carries \(short.netIDs.count) nets (\(short.shapeIDs.count) shapes, \(short.viaIDs.count) vias)")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            ForEach(Array(connectivity.opens.enumerated()), id: \.offset) { _, open in
                HStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                        .frame(width: 16)
                    Text("Open: net split into \(open.islands.count) islands (\(open.flylines.count) flyline\(open.flylines.count == 1 ? "" : "s"))")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    /// Design-intent verdict: broken constraints (symmetry, matching,
    /// alignment, ...) — purple, apart from DRC orange.
    @ViewBuilder
    private var constraintChip: some View {
        if !constraintViolations.isEmpty {
            Label(
                "\(constraintViolations.count) constraint\(constraintViolations.count == 1 ? "" : "s")",
                systemImage: "ruler"
            )
            .foregroundStyle(.purple)
            .help("Design-intent constraints (symmetry, matching, alignment) that the current geometry breaks.")
        }
    }

    /// Expanded rows for each broken constraint.
    @ViewBuilder
    private var constraintRows: some View {
        ForEach(constraintViolations.prefix(50)) { violation in
            HStack(spacing: 8) {
                Image(systemName: "ruler")
                    .foregroundStyle(.purple)
                    .font(.caption)
                    .frame(width: 16)
                Text(violation.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(violation.kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private var staleSummary: String {
        let names = staleKinds.map(\.rawValue).sorted().joined(separator: ", ")
        return "stale: \(names)"
    }
}
