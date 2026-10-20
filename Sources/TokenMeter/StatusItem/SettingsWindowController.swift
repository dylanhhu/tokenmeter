import AppKit
import SwiftUI

/// The settings window, created on demand.
///
/// It is an ordinary `NSWindow` around `SettingsView` rather than a SwiftUI
/// `Window` scene, because the app has no scene graph: the popover, hosted in an
/// `NSWindow`, has no `openWindow` action to call.
@MainActor
final class SettingsWindowController {
    private static let minimumWidth: CGFloat = 560

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "TokenMeter Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        let fitting = hosting.view.fittingSize
        window.setContentSize(NSSize(width: max(Self.minimumWidth, fitting.width), height: fitting.height))
        return window
    }
}
