import SwiftUI

/// Captures macOS scroll wheel and trackpad pinch events for the layout canvas.
///
/// SwiftUI `Canvas` does not natively receive scroll-wheel events.
/// This `NSViewRepresentable` installs local event monitors to intercept
/// `scrollWheel` (pan / Cmd+zoom) and `magnify` (pinch-to-zoom) events
/// when the cursor is over the canvas area.
struct LayoutScrollEventOverlay: NSViewRepresentable {
    var onScroll: (_ deltaX: CGFloat, _ deltaY: CGFloat) -> Void
    var onZoom: (_ magnification: CGFloat, _ cursorLocation: CGPoint) -> Void
    var onBackSwipe: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = _FlippedNSView()
        context.coordinator.view = view
        context.coordinator.onScroll = onScroll
        context.coordinator.onZoom = onZoom
        context.coordinator.onBackSwipe = onBackSwipe
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onZoom = onZoom
        context.coordinator.onBackSwipe = onBackSwipe
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        weak var view: NSView?
        var onScroll: ((_ deltaX: CGFloat, _ deltaY: CGFloat) -> Void)?
        var onZoom: ((_ magnification: CGFloat, _ cursorLocation: CGPoint) -> Void)?
        var onBackSwipe: (() -> Void)?
        private var scrollMonitor: Any?
        private var magnifyMonitor: Any?
        private var backSwipeAccumulatedX: CGFloat = 0
        private var isTrackingBackSwipe = false

        func startMonitoring() {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view else { return event }
                let windowLocation = event.locationInWindow
                let location = MainActor.assumeIsolated { view.convert(windowLocation, from: nil) }
                let bounds = MainActor.assumeIsolated { view.bounds }
                guard bounds.contains(location) else { return event }

                if event.modifierFlags.contains(.command) {
                    let factor: CGFloat
                    if event.hasPreciseScrollingDeltas {
                        factor = event.scrollingDeltaY * 0.005
                    } else {
                        factor = event.scrollingDeltaY * 0.05
                    }
                    self.onZoom?(factor, location)
                } else {
                    let dx: CGFloat
                    let dy: CGFloat
                    if event.hasPreciseScrollingDeltas {
                        dx = event.scrollingDeltaX
                        dy = event.scrollingDeltaY
                    } else {
                        dx = event.scrollingDeltaX * 10
                        dy = event.scrollingDeltaY * 10
                    }

                    if self.handleBackSwipeGesture(event: event, location: location, dx: dx, dy: dy) {
                        return nil
                    }

                    self.onScroll?(dx, dy)
                }
                return nil
            }

            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self, let view = self.view else { return event }
                let windowLocation = event.locationInWindow
                let location = MainActor.assumeIsolated { view.convert(windowLocation, from: nil) }
                let bounds = MainActor.assumeIsolated { view.bounds }
                guard bounds.contains(location) else { return event }

                self.onZoom?(event.magnification, location)
                return nil
            }
        }

        func stopMonitoring() {
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
            if let m = magnifyMonitor { NSEvent.removeMonitor(m); magnifyMonitor = nil }
            isTrackingBackSwipe = false
            backSwipeAccumulatedX = 0
        }

        deinit { stopMonitoring() }

        private func handleBackSwipeGesture(event: NSEvent, location: CGPoint, dx: CGFloat, dy: CGFloat) -> Bool {
            guard onBackSwipe != nil else { return false }
            if event.modifierFlags.contains(.command) { return false }

            let mostlyHorizontal = abs(dx) > abs(dy) * 1.8
            let fromLeftEdge = location.x < 72

            if !isTrackingBackSwipe {
                guard mostlyHorizontal, dx > 0, fromLeftEdge else { return false }
                isTrackingBackSwipe = true
                backSwipeAccumulatedX = dx
                return true
            }

            backSwipeAccumulatedX += dx

            if backSwipeAccumulatedX > 160 {
                onBackSwipe?()
                isTrackingBackSwipe = false
                backSwipeAccumulatedX = 0
                return true
            }

            let ended = event.phase == .ended || event.phase == .cancelled ||
                event.momentumPhase == .ended || event.momentumPhase == .cancelled
            if ended || backSwipeAccumulatedX < -20 || abs(dy) > abs(dx) {
                isTrackingBackSwipe = false
                backSwipeAccumulatedX = 0
            }

            return true
        }
    }
}

/// NSView with flipped coordinate system to match SwiftUI's top-left origin.
private final class _FlippedNSView: NSView {
    override var isFlipped: Bool { true }
}
