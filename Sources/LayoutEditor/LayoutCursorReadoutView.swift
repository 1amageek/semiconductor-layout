import SwiftUI
import LayoutCore

/// Live cursor coordinate readout in layout units (µm). The canvas
/// publishes the pointer position through
/// ``LayoutEditorViewModel/cursorPosition``; the readout keeps its
/// footprint when the cursor leaves so the control row does not jump.
struct LayoutCursorReadoutView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    var body: some View {
        HStack(spacing: 8) {
            axisValue("X", viewModel.cursorPosition?.x)
            axisValue("Y", viewModel.cursorPosition?.y)
            Text("µm")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private func axisValue(_ axis: String, _ value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(axis)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value.map { String(format: "%.3f", $0) } ?? "—")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
    }
}

#Preview("Cursor Readout") {
    let viewModel = LayoutEditorViewModel()
    viewModel.cursorPosition = LayoutPoint(x: 12.345, y: -3.21)
    return ZStack(alignment: .bottomLeading) {
        Color(nsColor: .controlBackgroundColor)
        LayoutCursorReadoutView(viewModel: viewModel)
            .padding(12)
    }
    .frame(width: 320, height: 100)
}

#Preview("Cursor Outside Canvas") {
    ZStack(alignment: .bottomLeading) {
        Color(nsColor: .controlBackgroundColor)
        LayoutCursorReadoutView(viewModel: LayoutEditorViewModel())
            .padding(12)
    }
    .frame(width: 320, height: 100)
}
