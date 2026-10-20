import AppKit
import SwiftUI
import TokenMeterKit

/// An AppKit application whose interface happens to be SwiftUI.
///
/// A SwiftUI `App` was the wrong shell for the menu bar item: `MenuBarExtra`
/// hides the `NSStatusItem` it creates, so the app could neither give the item an
/// accessibility identity — which menu bar managers read, and which `MenuBarExtra`
/// leaves unset — nor take part in the expanded interface sessions macOS 27 uses
/// to track a custom drop-down. Owning the item (see `StatusItemController`)
/// means owning the app lifecycle around it. Dropping the scene graph also means
/// there is no scene to open a settings window at launch: the item and the
/// windows are created when they are wanted.
@main
enum TokenMeterApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: the Info.plist sets LSUIElement, but running the loose
        // binary from `swift run` does not read it.
        NSApp.setActivationPolicy(.accessory)
        if Snapshot.runIfRequested() {
            return
        }
        let settingsWindow = SettingsWindowController(model: model)
        self.settingsWindow = settingsWindow
        statusItem = StatusItemController(model: model) { [weak settingsWindow] in
            settingsWindow?.show()
        }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
