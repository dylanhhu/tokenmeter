import CoreGraphics

/// Where the drop-down sits relative to the status item that opened it.
///
/// The panel is placed once, when it is shown, from the item's frame on screen.
/// Content that arrives afterwards can change the panel's height, so the top
/// edge — the one the eye reads as attached to the menu bar — is held in place
/// instead of letting the window grow upward under the bar.
public enum PopoverPlacement {
    /// Vertical clearance between the menu bar and the panel's top edge.
    public static let gap: CGFloat = 6

    /// Clearance kept between the panel and the edges of the display.
    public static let margin: CGFloat = 8

    /// The rect the panel hangs from.
    ///
    /// macOS 27 composes the menu bar itself and leaves each item's window as a
    /// stub at the origin, so `NSStatusItem.button.window` no longer describes
    /// where the item is drawn. A frame that intersects a display is real and is
    /// used as is; anything else is a stub, and the click that opened the panel
    /// is then the only reliable statement about where the item is — sessions
    /// are started by clicking it.
    public static func anchor(
        itemRect: CGRect,
        screens: [CGRect],
        pointer: CGPoint,
        menuBarHeight: CGFloat
    ) -> CGRect {
        let drawnInABar = screens.contains { screen in
            menuBar(of: screen, height: menuBarHeight).intersects(itemRect)
        }
        if itemRect.width > 0, itemRect.height > 0, drawnInABar {
            return itemRect
        }
        let screen = screens.first { $0.contains(pointer) } ?? screens.first ?? .zero
        let height = min(menuBarHeight, screen.height)
        return CGRect(x: pointer.x - 1, y: screen.maxY - height, width: 2, height: height)
    }

    /// The band a status item is drawn in: the top edge of a display.
    private static func menuBar(of screen: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
            .insetBy(dx: 0, dy: -2)
    }

    /// Origin for a panel of `size` hanging below `itemRect`, in screen
    /// coordinates (origin bottom left), kept inside `screen` and centred on the
    /// item where there is room.
    public static func origin(itemRect: CGRect, size: CGSize, screen: CGRect) -> CGPoint {
        let centred = itemRect.midX - size.width / 2
        let lowestX = screen.minX + margin
        let highestX = screen.maxX - margin - size.width
        // A panel wider than the display has no valid range; keep its left edge
        // on screen rather than producing a negative one.
        let x = min(max(centred, lowestX), max(lowestX, highestX))
        let y = max(itemRect.minY - gap - size.height, screen.minY + margin)
        return CGPoint(x: x, y: y)
    }

    /// Origin that holds `current`'s top edge while the panel takes `height`.
    public static func topAnchoredOrigin(current: CGRect, height: CGFloat) -> CGPoint {
        CGPoint(x: current.minX, y: current.maxY - height)
    }
}
