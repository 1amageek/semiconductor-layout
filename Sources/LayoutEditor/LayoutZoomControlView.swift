import SwiftUI

/// Compact zoom control with step buttons, level menu, and fit-all.
struct LayoutZoomControlView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    private let columns: [GridItem] = [
        GridItem(.fixed(22), spacing: 0),
        GridItem(.flexible(), spacing: 0),
        GridItem(.fixed(22), spacing: 0),
        GridItem(.fixed(22), spacing: 0),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            stepButton(systemImage: "minus.magnifyingglass") {
                viewModel.zoomOutStep()
            }
            zoomLevelMenu
            stepButton(systemImage: "plus.magnifyingglass") {
                viewModel.zoomInStep()
            }
            stepButton(systemImage: "arrow.up.left.and.arrow.down.right") {
                viewModel.fitAll()
            }
        }
        .frame(width: 180)
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }

    private var zoomLevelMenu: some View {
        Menu {
            ForEach(LayoutEditorViewModel.zoomSteps, id: \.self) { step in
                Button(formatZoom(step)) {
                    viewModel.zoomToStep(step)
                }
            }
        } label: {
            Text(formatZoom(viewModel.zoom))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
    }

    private func formatZoom(_ z: CGFloat) -> String {
        if z >= 10000 {
            return String(format: "%.0fK×", z / 1000)
        } else if z >= 1000 {
            let k = z / 1000
            return k == floor(k)
                ? String(format: "%.0fK×", k)
                : String(format: "%.1fK×", k)
        } else if z >= 1 {
            return z == floor(z)
                ? String(format: "%.0f×", z)
                : String(format: "%.1f×", z)
        } else {
            return String(format: "%.2f×", z)
        }
    }
}

// MARK: - Scale Bar

/// Dynamic scale bar that shows a reference length at the current zoom level.
struct LayoutScaleBarView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    var body: some View {
        let (barWidth, label) = computeScaleBar()
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 0) {
                Rectangle().frame(width: 1, height: 5)
                Rectangle().frame(width: barWidth, height: 1.5)
                Rectangle().frame(width: 1, height: 5)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func computeScaleBar() -> (CGFloat, String) {
        guard viewModel.zoom > 0 else { return (60, "—") }

        let targetPx: CGFloat = 80
        let layoutLen = Double(targetPx / viewModel.zoom)
        guard layoutLen > 0 else { return (60, "—") }

        let mag = pow(10, floor(log10(layoutLen)))
        let norm = layoutLen / mag
        let nice: Double
        if norm < 1.5 { nice = 1 }
        else if norm < 3.5 { nice = 2 }
        else if norm < 7.5 { nice = 5 }
        else { nice = 10 }
        let niceLen = nice * mag
        let barPx = CGFloat(niceLen) * viewModel.zoom

        let label: String
        if niceLen >= 1 {
            label = niceLen == floor(niceLen)
                ? String(format: "%.0f µm", niceLen)
                : String(format: "%g µm", niceLen)
        } else {
            let nm = niceLen * 1000
            label = nm == floor(nm)
                ? String(format: "%.0f nm", nm)
                : String(format: "%g nm", nm)
        }

        return (barPx, label)
    }
}
