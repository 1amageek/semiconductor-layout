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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = _FlippedNSView()
        context.coordinator.view = view
        context.coordinator.onScroll = onScroll
        context.coordinator.onZoom = onZoom
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onZoom = onZoom
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        weak var view: NSView?
        var onScroll: ((_ deltaX: CGFloat, _ deltaY: CGFloat) -> Void)?
        var onZoom: ((_ magnification: CGFloat, _ cursorLocation: CGPoint) -> Void)?
        private var scrollMonitor: Any?
        private var magnifyMonitor: Any?

        func startMonitoring() {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }

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
                    self.onScroll?(dx, dy)
                }
                return nil
            }

            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self, let view = self.view else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }

                self.onZoom?(event.magnification, location)
                return nil
            }
        }

        func stopMonitoring() {
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
            if let m = magnifyMonitor { NSEvent.removeMonitor(m); magnifyMonitor = nil }
        }

        deinit { stopMonitoring() }
    }
}

/// NSView with flipped coordinate system to match SwiftUI's top-left origin.
private final class _FlippedNSView: NSView {
    override var isFlipped: Bool { true }
}
