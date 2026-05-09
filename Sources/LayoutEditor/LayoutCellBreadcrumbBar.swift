import SwiftUI
import LayoutCore

struct LayoutCellBreadcrumbBar: View {
    @Bindable var viewModel: LayoutEditorViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.navigateBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .opacity(viewModel.canNavigateBack ? 1 : 0.35)
            .disabled(!viewModel.canNavigateBack)
            .help("Back")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let cells = viewModel.breadcrumbCells
                    ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                        Button {
                            viewModel.navigateToBreadcrumb(index: index)
                        } label: {
                            Text(cell.name)
                                .font(.system(size: 11, weight: index == cells.count - 1 ? .semibold : .regular))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background {
                                    if index == cells.count - 1 {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.quaternary)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)

                        if index < cells.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            Menu {
                ForEach(viewModel.allCells, id: \.id) { cell in
                    Button(cell.name) {
                        viewModel.openCell(cell.id)
                    }
                }
            } label: {
                Label("Modules", systemImage: "square.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)

            if viewModel.canOpenSelectedInstanceCell {
                Button("Open Instance") {
                    viewModel.openSelectedInstanceCell()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .help("Open referenced module from selected instance")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}
