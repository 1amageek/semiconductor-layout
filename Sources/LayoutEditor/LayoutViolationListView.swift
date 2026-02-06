import SwiftUI

public struct LayoutViolationListView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DRC Violations")
                .font(.headline)
            if viewModel.violations.isEmpty {
                Text("No violations")
                    .foregroundStyle(.secondary)
            } else {
                List(viewModel.violations) { violation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(violation.message)
                            .font(.caption)
                        if let layer = violation.layer {
                            Text("Layer: \(layer.name)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
    }
}
