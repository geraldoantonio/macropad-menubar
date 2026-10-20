import AppKit
import Carbon.HIToolbox
import Foundation
import MacropadCore

/// Global shortcuts via Carbon's RegisterEventHotKey: works while any app is in front and needs
/// no Accessibility or Input Monitoring permission. The registered combo is swallowed, so the
/// front app never sees it.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Called on the main thread with the trigger text (e.g. `ctrl+opt+shift+cmd+1`).
    var onTrigger: ((String) -> Void)?

    private var refs: [String: EventHotKeyRef] = [:]
    private var idsToTrigger: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private static let signature: OSType = 0x4D_50_41_44  // 'MPAD'

    private static let virtualKeyCodes: [String: UInt16] =
        Dictionary(MacKeyCodes.names.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

    /// Registers exactly `triggers`, unregistering any others. Returns the ones that failed
    /// (another app already owns that shortcut, or it can't be expressed as a hot key).
    @discardableResult
    func sync(_ triggers: Set<String>) -> [String] {
        installHandler()
        for (trigger, ref) in refs where !triggers.contains(trigger) {
            UnregisterEventHotKey(ref)
            refs[trigger] = nil
            idsToTrigger = idsToTrigger.filter { $0.value != trigger }
        }
        var failed: [String] = []
        for trigger in triggers.sorted() where refs[trigger] == nil {
            guard let (keyCode, modifiers) = Self.carbonCombo(trigger) else { failed.append(trigger); continue }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(keyCode), modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[trigger] = ref
                idsToTrigger[id] = trigger
            } else {
                failed.append(trigger)
            }
        }
        return failed
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = HotKeyCenter.shared
            if let trigger = center.idsToTrigger[hotKeyID.id] {
                DispatchQueue.main.async { center.onTrigger?(trigger) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// `ctrl+opt+shift+cmd+1` -> (virtual key code, Carbon modifier mask).
    static func carbonCombo(_ trigger: String) -> (UInt16, UInt32)? {
        guard let action = try? Action(parsing: trigger), case .keys(let steps) = action, steps.count == 1,
              let name = Keys.keyName(for: steps[0].code), let keyCode = virtualKeyCodes[name] else { return nil }
        let mods = steps[0].mods
        var carbon: UInt32 = 0
        if mods & 0x11 != 0 { carbon |= UInt32(controlKey) }
        if mods & 0x44 != 0 { carbon |= UInt32(optionKey) }
        if mods & 0x22 != 0 { carbon |= UInt32(shiftKey) }
        if mods & 0x88 != 0 { carbon |= UInt32(cmdKey) }
        return (keyCode, carbon)
    }
}

/// Runs what a command describes.
enum CommandRunner {
    static func run(_ command: Command) throws {
        let value = command.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch command.kind {
        case .openApp:
            let url = URL(fileURLWithPath: value)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CommandError("App não encontrado: \(value)")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        case .openURL:
            guard let url = URL(string: value) else { throw CommandError("Link inválido: \(value)") }
            NSWorkspace.shared.open(url)
        case .shell:
            try launch("/bin/zsh", ["-lc", value])
        case .shortcut:
            try launch("/usr/bin/shortcuts", ["run", value])
        }
    }

    /// Starts the process and returns; output goes to ~/Library/Logs/Macropad.log.
    private static func launch(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Macropad.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data("\n[\(Date())] \(([path] + arguments).joined(separator: " "))\n".utf8))
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
    }
}

struct CommandError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
