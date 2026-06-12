import SwiftUI
import LayoutVerify

/// SDL intent panel: the reference netlist's devices the layout does not
/// realize yet, each one click away from generator-backed placement,
/// plus the LVS convergence meter.
public struct LayoutIntentPanel: View {
    @Bindable var viewModel: LayoutEditorViewModel

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let comparison = viewModel.lvsComparison {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                    Text("Intent \(comparison.matchedReferenceDeviceCount)/\(comparison.referenceDeviceCount)")
                        .font(.caption.bold())
                    if comparison.passed {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
                if !viewModel.unplacedIntentDevices.isEmpty {
                    Divider()
                    ForEach(viewModel.unplacedIntentDevices.prefix(12), id: \.id) { device in
                        Button {
                            viewModel.armIntentPlacement(device)
                        } label: {
                            HStack(spacing: 6) {
                                Text(device.kind == .nmos ? "N" : "P")
                                    .font(.caption2.bold())
                                    .frame(width: 14, height: 14)
                                    .background(
                                        device.kind == .nmos ? Color.blue.opacity(0.3) : Color.pink.opacity(0.3),
                                        in: Circle()
                                    )
                                Text(String(
                                    format: "W %.2f L %.2f x%d",
                                    device.parameters.width,
                                    device.parameters.length,
                                    device.parameters.multiplier
                                ))
                                .font(.caption2)
                                Spacer(minLength: 4)
                                Image(systemName: viewModel.pendingIntentDevice?.id == device.id
                                    ? "cursorarrow.click.badge.clock"
                                    : "plus.circle")
                                    .font(.caption2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click, then click the canvas to place this device")
                    }
                    if viewModel.unplacedIntentDevices.count > 12 {
                        Text("\(viewModel.unplacedIntentDevices.count - 12) more...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(10)
            .frame(width: 180, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }
}
