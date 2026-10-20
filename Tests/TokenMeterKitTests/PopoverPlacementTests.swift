import CoreGraphics
import Testing
@testable import TokenMeterKit

@Suite("Popover placement")
struct PopoverPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let panel = CGSize(width: 372, height: 700)
    /// A status item near the right end of the bar. The item's bottom edge is
    /// where the panel's top edge should sit, just clear of the bar.
    private let item = CGRect(x: 1200, y: 876, width: 58, height: 24)

    @Test("hangs centred below the item")
    func centredBelowItem() {
        let origin = PopoverPlacement.origin(itemRect: item, size: panel, screen: screen)
        #expect(origin.x == item.midX - panel.width / 2)
        #expect(origin.y == item.minY - PopoverPlacement.gap - panel.height)
    }

    @Test("pulls back from the right edge when the item is the last one shown")
    func clampsAtRightEdge() {
        let last = CGRect(x: 1400, y: 876, width: 40, height: 24)
        let origin = PopoverPlacement.origin(itemRect: last, size: panel, screen: screen)
        #expect(origin.x == screen.maxX - PopoverPlacement.margin - panel.width)
    }

    @Test("pulls back from the left edge on a display left of the main one")
    func clampsAtLeftEdge() {
        let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let first = CGRect(x: -1920, y: 1056, width: 40, height: 24)
        let origin = PopoverPlacement.origin(itemRect: first, size: panel, screen: leftScreen)
        #expect(origin.x == leftScreen.minX + PopoverPlacement.margin)
    }

    @Test("keeps the whole panel above the bottom of a short display")
    func clampsAtBottom() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 720)
        let itemOnShort = CGRect(x: 1200, y: 696, width: 58, height: 24)
        let origin = PopoverPlacement.origin(itemRect: itemOnShort, size: panel, screen: short)
        #expect(origin.y == short.minY + PopoverPlacement.margin)
    }

    @Test("a status item's staging frame is not trusted as an anchor")
    func rejectsStagingFrame() {
        // What macOS 27 reports for an item that lives inside the bar's composite
        // window: a window at the origin with no height.
        let staging = CGRect(x: 0, y: -11, width: 30, height: 22)
        let anchor = PopoverPlacement.anchor(
            itemRect: staging,
            screens: [screen],
            pointer: CGPoint(x: 1200, y: 970),
            menuBarHeight: 33
        )
        #expect(anchor.minY == screen.maxY - 33)
        #expect(anchor.midX == 1200)
    }

    @Test("a real item frame wins over the pointer")
    func prefersItemFrame() {
        let anchor = PopoverPlacement.anchor(
            itemRect: item,
            screens: [screen],
            pointer: CGPoint(x: 10, y: 10),
            menuBarHeight: 33
        )
        #expect(anchor == item)
    }

    @Test("resizing the content keeps the top edge under the item")
    func topAnchoredWhileGrowing() {
        let current = CGRect(x: 200, y: 120, width: 372, height: 624)
        let origin = PopoverPlacement.topAnchoredOrigin(current: current, height: 812)
        #expect(origin == CGPoint(x: 200, y: current.maxY - 812))
    }
}
