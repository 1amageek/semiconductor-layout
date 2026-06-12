import SwiftUI
import LayoutCore

/// Floating tool options panel shown at the top of the canvas.
///
/// Displays context-sensitive parameters for the active tool:
/// - Path: width, end-cap style
/// - All drawing tools: angle constraint mode
/// - Ruler: distance display
struct LayoutToolOptionsOverlay: View {
    @Bindable var viewModel: LayoutEditorViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Angle constraint (shown for drawing tools)
            if showsAngleConstraint {
                angleConstraintPicker
            }

            // Path width (shown for path-like tools). Routes are rectangle
            // segments, so the end-cap option applies to paths only.
            if viewModel.tool == .path || viewModel.tool == .route {
                pathWidthField
            }
            if viewModel.tool == .path {
                endCapPicker
            }
            if viewModel.tool == .route {
                Toggle("Shove", isOn: $viewModel.routeShoveEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Push same-layer neighbours out of the way instead of stopping at them")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private var showsAngleConstraint: Bool {
        // Routes are always axis-aligned L-segments; showing the angle
        // picker for them would be an inert control.
        switch viewModel.tool {
        case .polygon, .path, .ruler:
            return true
        default:
            return false
        }
    }

    // MARK: - Angle Constraint

    private var angleConstraintPicker: some View {
        HStack(spacing: 4) {
            Text("Angle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $viewModel.angleConstraint) {
                ForEach(LayoutAngleConstraint.allCases, id: \.self) { mode in
                    Text(mode.displayLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
    }

    // MARK: - Path Width

    private var pathWidthField: some View {
        HStack(spacing: 4) {
            Text("W")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Width", value: $viewModel.pathWidth, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .font(.caption.monospacedDigit())
            Text("\u{00B5}m")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - End Cap

    private var endCapPicker: some View {
        HStack(spacing: 4) {
            Text("Cap")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $viewModel.pathEndCap) {
                ForEach(LayoutPathEndCap.allCases, id: \.self) { cap in
                    Text(cap.displayLabel).tag(cap)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 90)
        }
    }
}
