import LayoutCore

extension LayoutEditorViewModel {
    // MARK: - Rulers

    public func addRuler(from start: LayoutPoint, to end: LayoutPoint) {
        rulers.append(LayoutRuler(start: start, end: end))
    }

    public func clearAllRulers() {
        rulers.removeAll()
    }

}
