import AppKit
import SwiftUI

extension View {
    /// Space plays and pauses, whatever has keyboard focus in the window (a slider, a button,
    /// the timeline), except where Space types a space (text fields).
    ///
    /// The Playback menu's Space shortcut alone isn't enough: a focused control gets Space first
    /// and treats it as a click, so the shortcut stops working after clicking a slider or button.
    func spaceBarPlaysAndPauses(_ action: @escaping () -> Void) -> some View {
        background(SpaceBarMonitor(action: action))
    }
}

private struct SpaceBarMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
    }

    final class MonitorView: NSView {
        var action: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard SpaceBarMonitor.isPlainSpace(event) else { return event }
                let windowNumber = event.windowNumber
                // Key events arrive on the main thread.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, window.windowNumber == windowNumber,
                          !SpaceBarMonitor.isTyping(in: window) else { return false }
                    self.action()
                    return true
                }
                return handled ? nil : event
            }
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    /// Space with no modifier keys (Shift is allowed, as some people play with Shift-Space).
    nonisolated static func isPlainSpace(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    /// Whether Space should type a space: a text field or text view is being edited.
    static func isTyping(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }
}
