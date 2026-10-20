import AppKit
import SwiftUI
import TokenMeterKit

/// The window under the menu bar item.
///
/// A borderless panel rather than a popover: the content is a full SwiftUI view
/// with its own controls, and a popover's arrow and placement logic would fight
/// the item's own position on macOS 27, where the item is drawn by
/// `MenuBarAgent` and has no window of its own to anchor to.
@MainActor
final class PopoverPanel: NSPanel {
    private let hosting: NSHostingController<AnyView>
    /// Screen-space top edge to hold while the content changes height.
    private var topEdge: CGFloat?

    init(rootView: some View) {
        hosting = NSHostingController(rootView: AnyView(PopoverMaterial(content: rootView)))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        contentViewController = hosting
        delegate = self
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Sizes the panel to its content, hangs it below `itemRect`, and orders it
    /// in. The top edge is recorded so a later change in content height grows
    /// the panel downward instead of under the menu bar.
    func show(below itemRect: CGRect, on screen: NSScreen) {
        let size = hosting.view.fittingSize
        setContentSize(size)
        setFrameOrigin(PopoverPlacement.origin(itemRect: itemRect, size: size, screen: screen.visibleFrame))
        topEdge = frame.maxY
        makeKeyAndOrderFront(nil)
    }

    func hide() {
        topEdge = nil
        orderOut(nil)
    }
}

extension PopoverPanel: NSWindowDelegate {
    /// Content that arrives while the panel is open changes its height; AppKit
    /// keeps the origin instead, which would slide the top edge up behind the
    /// menu bar.
    func windowDidResize(_ notification: Notification) {
        guard isVisible, let topEdge, frame.height > 0, frame.maxY != topEdge else { return }
        setFrameOrigin(PopoverPlacement.topAnchoredOrigin(current: frame, height: frame.height))
    }
}

/// The drop-down's material, matching what `MenuBarExtra` drew behind the same
/// content before the item became ours.
private struct PopoverMaterial<Content: View>: View {
    let content: Content

    private let cornerRadius: CGFloat = 10

    var body: some View {
        content
            .background {
                VisualEffect(material: .popover, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
