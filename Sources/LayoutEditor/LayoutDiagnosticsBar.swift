import SwiftUI
import LayoutVerify

/// Compact bar displaying DRC violation summary at the bottom of the layout editor.
///
/// Shows a summary row with violation count. Expands to reveal individual violation messages.
public struct LayoutDiagnosticsBar: View {
    let violations: [LayoutViolation]
    @State private var isExpanded = false

    public init(violations: [LayoutViolation]) {
        self.violations = violations
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
}
