import AppKit
import SwiftUI

/// Seats the close, minimize and zoom buttons inside the floating glass panel.
/// AppKit has no setting for this and resets the buttons during layout, so the
/// position is reapplied whenever the window or its title bar changes.
struct TrafficLightPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacerView { PlacerView() }
    func updateNSView(_ view: PlacerView, context: Context) { view.place() }

    final class PlacerView: NSView {
        // Relative to the window's top left corner. The panel starts 6 pt in.
        private let inset = CGPoint(x: 21, y: 21)
        private let spacing: CGFloat = 21
        private var observers: [NSObjectProtocol] = []
        private var placing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
            ]
            observers = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                }
            }
            if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
                container.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            place()
            // AppKit finishes its first title bar layout after this view appears.
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        func place() {
            guard !placing, let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let mini = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let bar = close.superview, let container = bar.superview else { return }
            placing = true
            defer { placing = false }
            let size = close.frame.size
            let height = inset.y * 2 + size.height
            // Only as wide as the buttons, so it never covers the header's controls.
            let width = inset.x + spacing * 2 + size.width + inset.x
            let frame = NSRect(x: 0, y: window.frame.height - height, width: width, height: height)
            if container.frame != frame { container.frame = frame }
            for (i, button) in [close, mini, zoom].enumerated() {
                let origin = NSPoint(x: inset.x + spacing * CGFloat(i), y: (bar.frame.height - button.frame.height) / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
