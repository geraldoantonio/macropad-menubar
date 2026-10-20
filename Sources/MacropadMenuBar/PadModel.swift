import AppKit
import Foundation
import MacropadCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class PadModel: ObservableObject {
    struct Message: Equatable {
        var text: String
        var isError: Bool
    }

    @Published private(set) var layout = Layout()
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var identifying = false
    @Published private(set) var userPresets: [Preset] = []
    /// The layout from before the last preset was applied, for "Desfazer".
    @Published private(set) var undoLayout: Layout?
    @Published var layer = 1
    @Published var selectedSlot: Slot? = .key1
    @Published var message: Message?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let layoutURL = Layout.defaultURL
    private let presetStore = PresetStore()
    private var monitor: PadMonitor?

    init() {
        reload()
        monitor = PadMonitor { [weak self] connected in
            Task { @MainActor in self?.connected = connected }
        }
        monitor?.start()
    }

    /// Re-reads the layout file (the CLI may have changed it) and the user presets.
    func reload() {
        do {
            layout = try Layout.load(from: layoutURL)
        } catch {
            show("Layout em \(layoutURL.path) com problemas:\n\(error.localizedDescription)", error: true)
        }
        userPresets = presetStore.userPresets()
    }

    // MARK: Writing to the pad

    func set(_ slot: Slot, to text: String) {
        let action: Action
        do { action = try Action(parsing: text) } catch {
            show(error.localizedDescription, error: true)
            return
        }
        let layer = self.layer
        write(PadProtocol.bindPackets(slot: slot, layer: layer, action: action),
              success: "\(slot.title) = \(action.canonical)") { layout in
            try? layout.set(layer: layer, slot: slot, actionText: text)
        }
    }

    func clear(_ slot: Slot) {
        let layer = self.layer
        write(PadProtocol.bindPackets(slot: slot, layer: layer, action: nil),
              success: "\(slot.title) limpa") { layout in
            layout.clear(layer: layer, slot: slot)
        }
    }

    func setLED(_ mode: Int) {
        write(PadProtocol.ledPackets(mode: mode), success: "LED: \(Self.ledTitles[mode])") { layout in
            layout.led = mode
        }
    }

    /// Writes a whole layout; slots it doesn't map are cleared.
    func apply(_ newLayout: Layout, name: String, after: (() -> Void)? = nil) {
        let packets: [[UInt8]]
        do { packets = try PadProtocol.applyPackets(newLayout) } catch {
            show(error.localizedDescription, error: true)
            return
        }
        write(packets, success: "“\(name)” gravado no pad", update: { layout in
            layout = newLayout
        }, after: after)
    }

    func applyPreset(_ preset: Preset) {
        let previous = layout
        apply(preset.layout, name: preset.name) { self.undoLayout = previous }
    }

    func undo() {
        guard let previous = undoLayout else { return }
        apply(previous, name: "Layout anterior")
    }

    func reapplyCurrent() {
        apply(layout, name: "Layout atual") { self.identifying = false }
    }

    /// Makes each key type its slot number so you can learn the physical layout. The layout
    /// file isn't changed; `reapplyCurrent()` restores the pad.
    func identify() {
        write(PadProtocol.identifyPackets(),
              success: "Modo identificar: abra um campo de texto e aperte cada tecla. Depois clique em Restaurar.",
              update: nil) { self.identifying = true }
    }

    private func write(_ packets: [[UInt8]], success: String, update: ((inout Layout) -> Void)?,
                       after: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        message = nil
        undoLayout = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try PadUSB.send(packets) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success:
                    if let update {
                        var copy = self.layout
                        update(&copy)
                        self.layout = copy
                        do { try copy.save(to: self.layoutURL) } catch {
                            self.show("Gravado no pad, mas não consegui salvar \(self.layoutURL.path): \(error.localizedDescription)", error: true)
                            return
                        }
                    }
                    after?()
                    self.show(success, error: false)
                case .failure(let error):
                    self.show(error.localizedDescription, error: true)
                }
            }
        }
    }

    // MARK: Presets

    func savePreset(named name: String) {
        do {
            try presetStore.save(layout, named: name)
            userPresets = presetStore.userPresets()
            show("Preset “\(name)” salvo", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    func deletePreset(_ preset: Preset) {
        do {
            try presetStore.delete(preset)
            userPresets = presetStore.userPresets()
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    func importPreset() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 }
        panel.message = "Escolha um layout YAML (formato do macropad CLI)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try Layout.load(from: url)
            try presetStore.save(imported, named: url.deletingPathExtension().lastPathComponent)
            userPresets = presetStore.userPresets()
            show("Preset “\(url.deletingPathExtension().lastPathComponent)” importado", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    func exportLayout() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macropad-layout.yaml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try layout.save(to: url) } catch { show(error.localizedDescription, error: true) }
    }

    func revealLayoutFile() {
        NSWorkspace.shared.activateFileViewerSelecting([layoutURL])
    }

    // MARK: Misc

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("Abrir no login: \(error.localizedDescription)", error: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func show(_ text: String, error: Bool) {
        message = Message(text: text, isError: error)
    }

    static let ledTitles = ["Desligado", "Tecla pressionada", "Arco-íris"]
}
