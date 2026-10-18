import AppKit
import SwiftUI
import TokenMeterKit

/// Renders the popover offscreen to a PNG.
///
///     TokenMeter --snapshot <path> [--view popover|settings|empty]
///                                  [--appearance dark|light] [--width 372]
///
/// This exists so the interface can be inspected without a display, screen
/// recording permission, or clicking the menu bar item — useful for pull request
/// screenshots, README images, and anyone developing over SSH. It renders the
/// real view hierarchy against the synthetic provider and never touches the
/// user's settings or Keychain.
enum Snapshot {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--snapshot"),
              arguments.count > flagIndex + 1 else { return false }
        let path = arguments[flagIndex + 1]
        let appearanceName = value(for: "--appearance", in: arguments) ?? "dark"
        let view = value(for: "--view", in: arguments) ?? "popover"
        let window = value(for: "--window", in: arguments) ?? "daily"
        let width = value(for: "--width", in: arguments).flatMap(Double.init) ?? 372

        Task { @MainActor in
            do {
                try await render(to: path, view: view, window: window, appearance: appearanceName, width: width)
                FileHandle.standardOutput.write(Data("Wrote snapshot to \(path)\n".utf8))
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                NSApp.terminate(nil)
            }
        }
        return true
    }

    @MainActor
    private static func render(
        to path: String,
        view: String,
        window: String,
        appearance: String,
        width: Double
    ) async throws {
        // Isolated store: nothing is written to the real settings file.
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(fileURL: temporaryDirectory.appendingPathComponent("snapshot.json"))
        let model = AppModel(settingsStore: store, credentialStore: CredentialStore(service: "com.dylanhu.TokenMeter.snapshot"))
        model.updateSettings { settings in
            // `--view empty` renders the onboarding state instead.
            settings.enabledProviders = view == "empty" ? [] : [DemoProvider.providerID]
            settings.menuBarWindow = SpendWindow(rawValue: window) ?? .daily
        }
        if view != "empty" {
            await model.refreshForSnapshot()
        }

        // The real popover draws on a window material; offscreen there is no
        // backdrop, so paint one or dark-appearance text is white on nothing.
        let content = if view == "settings" {
            AnyView(SettingsView(model: model))
        } else {
            AnyView(SpendPopoverView(model: model))
        }
        let effectiveWidth = view == "settings" ? max(width, 560) : width
        let root = ZStack {
            Color(nsColor: .windowBackgroundColor)
            content
        }
        .frame(width: effectiveWidth)
        let hosting = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        hosting.appearance = appearance
        hosting.layoutSubtreeIfNeeded()

        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: effectiveWidth, height: max(1, size.height)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        // Text only rasterises once the hosting view belongs to a window; park it
        // far off-screen so nothing flashes on the user's display.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        hosting.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.orderOut(nil)
            throw SnapshotError.renderFailed
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        window.orderOut(nil)
        window.contentView = nil

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodeFailed
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }

    private enum SnapshotError: Error {
        case renderFailed
        case encodeFailed
    }
}
