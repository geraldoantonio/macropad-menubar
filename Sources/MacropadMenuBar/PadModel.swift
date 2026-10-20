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
    /// This pad has a single layer: the firmware ignores the layer byte and the last write to a
    /// slot wins (docs/protocol.md in vibe-coder-keyboard). The app always uses layer 1.
    let layer = 1
    @Published var selectedSlot: Slot? = .key1
    @Published var message: Message?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Program/script commands and per-app rules (`~/.config/macropad/app.json`).
    @Published private(set) var config = AppConfig.load()
    /// The preset last put on the pad by the per-app automation.
    @Published private(set) var activePresetID: String?
    @Published private(set) var frontAppName: String?
    @Published private(set) var updating = false

    let layoutURL = Layout.defaultURL
    private let presetStore = PresetStore()
    private var monitor: PadMonitor?
    private var queue: [Job] = []
    private var autoTask: Task<Void, Never>?

    private struct Job {
        var packets: [[UInt8]]
        var success: String
        var update: ((inout Layout) -> Void)?
        var after: (() -> Void)?
        var quiet: Bool
    }

    init() {
        reload()
        monitor = PadMonitor { [weak self] connected in
            Task { @MainActor in self?.connected = connected }
        }
        monitor?.start()
        HotKeyCenter.shared.onTrigger = { [weak self] trigger in
            Task { @MainActor in self?.runTrigger(trigger) }
        }
        syncHotKeys()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.frontAppChanged(app) }
        }
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
        // Layers 2–3 (e.g. from a CLI or imported file) can't exist on this pad; keep layer 1.
        let newLayout = Layout(led: newLayout.led, layers: newLayout.layers[1].map { [1: $0] } ?? [:])
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
        apply(preset.layout, name: preset.name) {
            self.undoLayout = previous
            self.activePresetID = preset.id
        }
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
                       after: (() -> Void)? = nil, quiet: Bool = false) {
        // A manual edit means the pad no longer matches the automatic preset.
        if !quiet { activePresetID = nil }
        queue.append(Job(packets: packets, success: success, update: update, after: after, quiet: quiet))
        if !busy { runNext() }
    }

    /// Writes queued jobs one at a time, so an automatic preset switch never collides with an edit.
    private func runNext() {
        guard !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let (packets, success, update, after) = (job.packets, job.success, job.update, job.after)
        busy = true
        if !job.quiet { message = nil; undoLayout = nil }
        Task.detached(priority: .userInitiated) {
            let result = Result { try PadUSB.send(packets) }
            await MainActor.run {
                defer { self.busy = false; self.runNext() }
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
                    self.pruneCommands()
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
            pruneCommands()
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    func importPreset() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 }
        panel.message = "Escolha um layout YAML (formato do macropad CLI)"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try layout.save(to: url) } catch { show(error.localizedDescription, error: true) }
    }

    func revealLayoutFile() {
        NSWorkspace.shared.activateFileViewerSelecting([layoutURL])
    }

    // MARK: Program / script keys

    var allPresets: [Preset] { Preset.builtIns + userPresets }

    func preset(id: String?) -> Preset? { allPresets.first { $0.id == id } }

    /// What the pad drawing shows on a slot: the program it opens, or the keys it sends.
    func label(for slot: Slot) -> String {
        let text = layout.text(layer: layer, slot: slot)
        if let command = config.command(forActionText: text) { return "▸ " + command.label }
        return text.map { (try? Action(parsing: $0))?.displayLabel ?? $0 } ?? ""
    }

    /// The command a slot's current action triggers, if any.
    func command(for slot: Slot) -> Command? {
        config.command(forActionText: layout.text(layer: layer, slot: slot))
    }

    /// Binds `slot` to a fresh trigger shortcut and remembers what to run when it arrives.
    func setCommand(_ slot: Slot, _ command: Command) {
        guard command.isValid else { show("Preencha o que a tecla deve abrir ou executar", error: true); return }
        let inUse = Set(([layout] + userPresets.map(\.layout)).flatMap { $0.layers.values.flatMap(\.values) }
            .compactMap { try? Action(parsing: $0).canonical })
        guard let trigger = config.freeTrigger(reserved: inUse), let action = try? Action(parsing: trigger) else {
            show("Todos os atalhos-gatilho estão em uso; limpe alguma tecla de programa", error: true)
            return
        }
        let layer = self.layer
        write(PadProtocol.bindPackets(slot: slot, layer: layer, action: action),
              success: "\(slot.title) abre “\(command.label)” (envia \(action.displayLabel))",
              update: { layout in try? layout.set(layer: layer, slot: slot, actionText: trigger) },
              after: {
                  self.config.commands[trigger] = command
                  self.saveConfig()
              })
    }

    func runTrigger(_ trigger: String) {
        guard let command = config.commands[trigger] else { return }
        do { try CommandRunner.run(command) } catch { show(error.localizedDescription, error: true) }
    }

    /// Forgets commands no layout uses any more and re-registers the global shortcuts.
    private func pruneCommands() {
        var pruned = config
        pruned.pruneCommands(keeping: [layout] + userPresets.map(\.layout))
        if pruned != config { config = pruned; saveConfig() } else { syncHotKeys() }
    }

    private func saveConfig() {
        do { try config.save() } catch { show("Não consegui salvar \(AppConfig.defaultURL.path): \(error.localizedDescription)", error: true) }
        syncHotKeys()
    }

    private func syncHotKeys() {
        let failed = HotKeyCenter.shared.sync(Set(config.commands.keys))
        if !failed.isEmpty {
            show("Outro app já usa \(failed.joined(separator: ", ")); essas teclas não vão abrir nada", error: true)
        }
    }

    // MARK: Per-app presets

    func setAutoSwitch(_ enabled: Bool) {
        config.autoSwitch = enabled
        saveConfig()
        if enabled { frontAppChanged(NSWorkspace.shared.frontmostApplication, force: true) }
    }

    func setRule(bundleID: String, appName: String, presetID: String) {
        config.setRule(AutoRule(bundleID: bundleID, appName: appName, preset: presetID))
        saveConfig()
    }

    func removeRule(bundleID: String) {
        config.removeRule(bundleID: bundleID)
        saveConfig()
    }

    func setDefaultPreset(_ presetID: String?) {
        config.defaultPreset = presetID
        saveConfig()
    }

    private var ownBundleID: String { Bundle.main.bundleIdentifier ?? "com.geraldoantonio.macropad-menubar" }

    private func frontAppChanged(_ app: NSRunningApplication?, force: Bool = false) {
        guard let app, let bundleID = app.bundleIdentifier, bundleID != ownBundleID else { return }
        frontAppName = app.localizedName
        guard config.autoSwitch, !identifying, connected,
              let presetID = config.presetID(for: bundleID), let preset = preset(id: presetID) else { return }
        guard force || presetID != activePresetID else { return }
        // Quick app switches (⌘-Tab through several apps) only write the one you land on.
        autoTask?.cancel()
        autoTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.applyAutomatically(preset, appName: app.localizedName ?? bundleID)
        }
    }

    private func applyAutomatically(_ preset: Preset, appName: String) {
        guard let packets = try? PadProtocol.applyPackets(preset.layout) else { return }
        activePresetID = preset.id
        write(packets, success: "\(appName): preset “\(preset.name)”",
              update: { layout in layout = preset.layout }, quiet: true)
    }

    // MARK: Updates

    func checkForUpdates() {
        guard !updating else { return }
        updating = true
        show("Procurando atualizações…", error: false)
        Task { @MainActor in
            defer { updating = false }
            switch await Updater.check() {
            case .upToDate:
                show("Você já está na versão mais nova (\(Updater.versionDescription)).", error: false)
            case .failed(let reason):
                show("Não consegui verificar atualizações: \(reason)", error: true)
            case .available(let commit):
                show("Baixando a versão \(commit.prefix(7))… o Macropad vai fechar e abrir de novo sozinho.", error: false)
                let reason = await Updater.install()
                show("A atualização falhou: \(reason)", error: true)
            }
        }
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
