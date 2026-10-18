import AppKit
import SwiftUI

extension View {
    /// Holds a `MenuBarExtra` window where it opened.
    ///
    /// Menu bar items are laid out from the right, so any change to an item's
    /// width shifts its origin, and the window-style drop-down re-anchors itself
    /// under the item whenever that happens. The label carries the current spend
    /// figure, so a refresh that widens it — "$8.40" becoming "$12.10" — slides
    /// the item left and drags the open popover with it, mid-read. Pinning the
    /// window's origin for as long as it is on screen keeps the drop-down still
    /// under the cursor; the next open re-anchors as usual.
    func anchoredWhileOpen() -> some View {
        background(AnchoredWindowAnchor())
    }
}

private struct AnchoredWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        AnchoredWindowView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Zero-size view that finds its window and keeps it from moving while it shows.
private final class AnchoredWindowView: NSView {
    /// Moves within this interval of the window being ordered in are its own
    /// placement, not a status item sliding underneath it, so they are adopted
    /// rather than undone.
    private static let placementGrace: TimeInterval = 0.25

    private var visibility: NSKeyValueObservation?
    private var moveObserver: NSObjectProtocol?
    /// Only the horizontal position is pinned. A menu bar item slides along the
    /// bar; the window's vertical origin belongs to the system, which moves it
    /// when the drop-down is placed or resized.
    private var pinnedX: CGFloat?
    private var placementDeadline = Date.distantPast

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach(to: window)
    }

    private func attach(to window: NSWindow?) {
        detach()
        guard let window else { return }
        // `isVisible` tracks the drop-down being ordered in and out, which is
        // when the window is placed. Key status is a worse proxy: it also flips
        // when the settings window takes focus. AppKit posts no ordered-on/off-
        // screen notification to observe instead.
        visibility = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.visibilityDidChange() }
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidMove() }
        }
    }

    private func detach() {
        visibility?.invalidate()
        visibility = nil
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        moveObserver = nil
        pinnedX = nil
    }

    private func visibilityDidChange() {
        guard window?.isVisible == true else {
            pinnedX = nil
            return
        }
        placementDeadline = Date().addingTimeInterval(Self.placementGrace)
        pinnedX = window?.frame.origin.x
    }

    private func windowDidMove() {
        guard let window, window.isVisible else { return }
        let origin = window.frame.origin
        // Still settling into the position the system picked for this showing:
        // follow it and remember where it landed.
        guard Date() >= placementDeadline, let pinnedX else {
            pinnedX = origin.x
            return
        }
        guard origin.x != pinnedX else { return }
        window.setFrameOrigin(NSPoint(x: pinnedX, y: origin.y))
    }
}
