import AppKit
import MacropadCore

/// Captures key presses in the app's window and turns them into action steps (`shift+cmd+4`).
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?

    /// Calls `onStroke` with each step; recording stops when it returns false.
    func start(onStroke: @escaping (String) -> Bool) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard let key = MacKeyCodes.names[event.keyCode] else { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var parts: [String] = []
            if flags.contains(.control) { parts.append("ctrl") }
            if flags.contains(.option) { parts.append("opt") }
            if flags.contains(.shift) { parts.append("shift") }
            if flags.contains(.command) { parts.append("cmd") }
            parts.append(key)
            if !onStroke(parts.joined(separator: "+")) { self.stop() }
            return nil  // swallow it: the press is being recorded, not typed
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    deinit { stop() }
}
