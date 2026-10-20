import AppKit
import SwiftUI
import TokenMeterKit

/// Owns the menu bar item and the drop-down it opens.
///
/// SwiftUI's `MenuBarExtra` cannot serve here. On macOS 27 the bar is composed by
/// `MenuBarAgent`, which tells items apart by the accessibility identifier on
/// their button. `MenuBarExtra` never sets one: reading the attribute returns
/// `kAXErrorFailure` (-25200), so a menu bar manager such as Bartender cannot
/// index, move, or click the item and reports that it could not read the item's
/// accessibility identity. `MenuBarExtra` also has no way to take part in an
/// expanded interface session, the macOS 27 mechanism that keeps a custom
/// drop-down in step with menu bar tracking.
///
/// Both need an `NSStatusItem` whose button — label, identity, and click
/// handling — belongs to us. On 27 and later the system starts and ends sessions
/// through `expandedInterfaceDelegate`; older systems get the plain
/// target/action toggle that `MenuBarExtra` used to provide.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item: NSStatusItem
    private let openSettings: @MainActor () -> Void
    private var eventMonitors: [Any] = []
    private lazy var panel = PopoverPanel(
        rootView: SpendPopoverView(model: model) { [weak self] in
            self?.dismiss()
            self?.openSettings()
        }
    )

    init(model: AppModel, openSettings: @escaping @MainActor () -> Void) {
        self.model = model
        self.openSettings = openSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // The autosave name persists the item's position and visibility, and gives
        // menu bar managers a second stable handle on it across launches.
        item.autosaveName = MenuBarLabel.identifier
        if #available(macOS 27.0, *) {
            item.expandedInterfaceDelegate = self
        } else {
            item.button?.target = self
            item.button?.action = #selector(toggleFromButton)
        }
        applyLabel()
        observeModel()
    }

    /// Rebuilds the item's visible label from the current settings and reading.
    /// The accessibility identity stays put: only the title and tooltip track the
    /// data.
    private func applyLabel() {
        guard let button = item.button else { return }
        let label = model.menuBarLabel
        button.title = label.title
        button.toolTip = label.toolTip
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.alignment = .center
        if let symbol = label.systemImage {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }
        button.setAccessibilityIdentifier(label.accessibilityIdentifier)
        button.setAccessibilityLabel(label.accessibilityLabel)
        button.setAccessibilityHelp(label.toolTip)
        item.length = NSStatusItem.variableLength
    }

    /// `AppModel` is `@Observable`; re-arming after each change keeps the reading
    /// current without polling the model on a timer.
    private func observeModel() {
        withObservationTracking {
            _ = model.menuBarLabel
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeModel()
                self?.applyLabel()
            }
        }
    }

    // MARK: - Showing and hiding

    private func present() {
        guard let button = item.button else { return }
        let rawItemRect = if let window = button.window {
            window.convertToScreen(button.convert(button.bounds, to: nil))
        } else {
            button.accessibilityFrame()
        }
        let pointer = NSEvent.mouseLocation
        guard let openingScreen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            return
        }
        let anchor = PopoverPlacement.anchor(
            itemRect: rawItemRect,
            screens: NSScreen.screens.map(\.frame),
            pointer: pointer,
            menuBarHeight: openingScreen.frame.maxY - openingScreen.visibleFrame.maxY
        )
        if anchor != rawItemRect {
            Log.app.debug("status item: item frame unusable, anchoring the drop-down at the pointer")
        }
        let centre = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? openingScreen
        NSApp.activate()
        panel.show(below: anchor, on: screen)
        installEventMonitors()
        model.refreshIfStale()
    }

    private func hidePanel() {
        removeEventMonitors()
        panel.hide()
    }

    /// Closes the drop-down as the result of something the app did — a button in
    /// the popover, Escape, a click elsewhere. On 27 and later the session must be
    /// told, or the menu bar keeps believing an interface is open; the delegate
    /// callout that follows hides the panel.
    private func dismiss() {
        guard panel.isVisible else { return }
        if #available(macOS 27.0, *), let session = item.expandedInterfaceSession {
            session.cancel()
        } else {
            hidePanel()
        }
    }

    @objc private func toggleFromButton() {
        if panel.isVisible {
            dismiss()
        } else {
            present()
        }
    }

    // MARK: - Dismissal

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        // Escape is the only local event the panel needs to see. Clicks inside the
        // panel — including the menu and picker windows it opens — belong to it;
        // clicks on another application arrive through the global monitor, and on
        // 27 and later the system ends the session when focus leaves.
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Monitors are delivered on the main thread; only the decision
            // crosses the closure boundary because `NSEvent` is not `Sendable`.
            let swallow = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return swallow ? nil : event
        }
        if let local {
            eventMonitors.append(local)
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        if let global {
            eventMonitors.append(global)
        }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }

    /// Escape closes the drop-down, as it did under `MenuBarExtra`. Returns
    /// whether the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel.isVisible, event.keyCode == 53 else { return false }
        dismiss()
        return true
    }
}

@available(macOS 27.0, *)
extension StatusItemController: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        present()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        hidePanel()
    }
}
