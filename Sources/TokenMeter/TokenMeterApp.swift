import AppKit
import SwiftUI
import TokenMeterKit

@main
struct TokenMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            SpendPopoverView(model: model)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Window("TokenMeter Settings", id: WindowID.settings) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        switch model.settings.menuBarStyle {
        case .iconAndAmount:
            Label(model.menuBarText, systemImage: "chart.bar.fill")
                .labelStyle(.titleAndIcon)
                .help(model.menuBarTooltip)
        case .amount, .amountAndWindow:
            Text(model.menuBarText)
                .monospacedDigit()
                .help(model.menuBarTooltip)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: the Info.plist sets LSUIElement, but running the loose
        // binary from `swift run` does not read it.
        NSApp.setActivationPolicy(.accessory)
        if Snapshot.runIfRequested() {
            return
        }
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
