import AppKit
import SwiftUI
import Testing
@testable import SwiftCut

/// Space plays and pauses even after clicking a slider or button (which takes keyboard focus),
/// but still types a space in text fields.
@MainActor
struct SpaceBarTests {
    final class Counter { var presses = 0 }

    private func space(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: " ",
                         charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    }

    private func makeWindow(counter: Counter) -> (NSWindow, NSSlider, NSTextField) {
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        let field = NSTextField(string: "name")
        let stack = NSStackView(views: [slider, field])
        let host = NSHostingView(rootView: Color.clear.frame(width: 50, height: 50).spaceBarPlaysAndPauses { counter.presses += 1 })
        stack.addArrangedSubview(host)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = stack
        window.orderFront(nil)
        return (window, slider, field)
    }

    @Test func spaceWorksWhileASliderHasFocus() async throws {
        let counter = Counter()
        let (window, slider, _) = makeWindow(counter: counter)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(slider)
        NSApp.sendEvent(space(in: window))
        #expect(counter.presses == 1)
    }

    @Test func spaceStillTypesInTextFields() async throws {
        let counter = Counter()
        let (window, _, field) = makeWindow(counter: counter)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(field)
        #expect(window.firstResponder is NSTextView, "editing the field")
        NSApp.sendEvent(space(in: window))
        #expect(counter.presses == 0)
    }
}
