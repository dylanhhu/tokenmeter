import Foundation

/// What the status item shows, and how assistive technology and menu bar
/// managers identify it.
///
/// macOS 27 draws status items through `MenuBarAgent` rather than giving each
/// one a window, and readers find an item by its accessibility identifier.
/// SwiftUI's `MenuBarExtra` leaves that attribute unset, so a reader — Bartender
/// among them — gets `kAXErrorFailure` (-25200) instead of a name and cannot
/// track the item. The identifier is therefore a constant: it names the item,
/// while the title carries the reading and changes at every refresh.
public struct MenuBarLabel: Equatable, Sendable {
    /// The item's accessibility identifier. Never derived from the spend figure:
    /// an identity that changed every minute would be useless to anything that
    /// stores it.
    public static let identifier = "com.dylanhu.TokenMeter.menuBarItem"

    /// Stable name for assistive technology; the reading itself belongs in the
    /// value and the tooltip.
    public static let name = "TokenMeter spend"

    public let title: String
    public let systemImage: String?
    public let toolTip: String
    public let accessibilityIdentifier: String
    public let accessibilityLabel: String

    public init(style: MenuBarStyle, text: String, toolTip: String) {
        title = text
        systemImage = style == .iconAndAmount ? "chart.bar.fill" : nil
        self.toolTip = toolTip
        accessibilityIdentifier = Self.identifier
        accessibilityLabel = Self.name
    }
}
