import Testing
@testable import TokenMeterKit

@Suite("Menu bar label")
struct MenuBarLabelTests {
    @Test("the accessibility identity is a constant, not the reading")
    func identityIsStable() {
        let first = MenuBarLabel(style: .amount, text: "$8.40", toolTip: "$8.40 today")
        let second = MenuBarLabel(style: .amount, text: "$12.10", toolTip: "$12.10 today")
        #expect(first.accessibilityIdentifier == "com.dylanhu.TokenMeter.menuBarItem")
        #expect(first.accessibilityIdentifier == second.accessibilityIdentifier)
        #expect(first.accessibilityLabel == second.accessibilityLabel)
        #expect(first.title == "$8.40")
        #expect(second.title == "$12.10")
    }

    @Test("only the icon style carries a symbol")
    func iconOnlyWithIconStyle() {
        #expect(MenuBarLabel(style: .iconAndAmount, text: "$1", toolTip: "").systemImage == "chart.bar.fill")
        #expect(MenuBarLabel(style: .amount, text: "$1", toolTip: "").systemImage == nil)
        #expect(MenuBarLabel(style: .amountAndWindow, text: "$1", toolTip: "").systemImage == nil)
    }

    @Test("the tooltip carries the precise reading")
    func toolTipPassesThrough() {
        #expect(MenuBarLabel(style: .amount, text: "$1", toolTip: "$1.04 today").toolTip == "$1.04 today")
    }
}
