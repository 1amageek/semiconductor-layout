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
                        HStack(spacing: 6) {
                            Text(violation.severity.rawValue.uppercased())
                                .font(.caption2)
                                .fontWeight(.semibold)
                            if let ruleID = violation.ruleID {
                                Text(ruleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(violation.message)
                            .font(.caption)
                        if let layer = violation.layer {
                            Text("Layer: \(layer.name)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let measured = violation.measured,
                           let required = violation.required,
                           let unit = violation.unit {
                            Text("Measured \(measured.formatted()) \(unit), required \(required.formatted()) \(unit)")
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
