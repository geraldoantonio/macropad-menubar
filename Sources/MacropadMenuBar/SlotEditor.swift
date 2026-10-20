import AppKit
import MacropadCore
import SwiftUI
import UniformTypeIdentifiers

/// Edits what one slot does: a key combo/sequence, a media key, a mouse action or nothing.
struct SlotEditor: View {
    enum Kind: String, CaseIterable, Identifiable {
        case keys = "Teclas", media = "Mídia", mouse = "Mouse", program = "Programa", none = "Nada"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: PadModel
    @StateObject private var recorder = ShortcutRecorder()

    let slot: Slot
    let layer: Int
    let current: String?
    let initialCommand: Command?

    @State private var kind: Kind
    @State private var keysText: String
    @State private var media: String
    @State private var mouse: String
    @State private var mouseMods: Set<String>
    @State private var recordedSteps = 0
    @State private var commandKind: Command.Kind
    @State private var commandValue: String

    init(slot: Slot, layer: Int, current: String?, command: Command?) {
        self.slot = slot
        self.layer = layer
        self.current = current
        self.initialCommand = command
        _commandKind = State(initialValue: command?.kind ?? .openApp)
        _commandValue = State(initialValue: command?.value ?? "")
        let action = current.flatMap { try? Action(parsing: $0) }
        var kind = Kind.none, keysText = "", media = "volume-up", mouse = "click", mods = Set<String>()
        switch action {
        case .keys?:
            kind = .keys
            keysText = action?.canonical ?? current ?? ""
        case .media(let code)?:
            kind = .media
            media = Keys.mediaName(for: code) ?? media
        case .mouse(let buttons, let wheel, let m)?:
            kind = .mouse
            mouse = Keys.mouseName(buttons: buttons, wheel: wheel) ?? mouse
            mods = Set(Action.modifierNames(m))
        case nil:
            if let current, !current.isEmpty { kind = .keys; keysText = current }
        }
        if command != nil { kind = .program }
        _kind = State(initialValue: kind)
        _keysText = State(initialValue: keysText)
        _media = State(initialValue: media)
        _mouse = State(initialValue: mouse)
        _mouseMods = State(initialValue: mods)
    }

    /// The action text the editor currently describes (nil = clear the slot).
    private var actionText: String? {
        switch kind {
        case .keys: keysText
        case .media: media
        case .mouse: (Keys.modifiers.map(\.name).filter { mouseMods.contains($0) } + [mouse]).joined(separator: "+")
        case .program, .none: nil
        }
    }

    private var parsed: Result<Action, Error>? {
        actionText.map { text in Result { try Action(parsing: text) } }
    }

    private var command: Command { Command(kind: commandKind, value: commandValue) }

    private var isUnchanged: Bool {
        if kind == .program { return command == initialCommand }
        if initialCommand != nil { return false }
        guard let text = actionText else { return current == nil }
        guard let current, let a = try? Action(parsing: text), let b = try? Action(parsing: current) else { return false }
        return a == b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(slot.title).font(.subheadline.weight(.semibold))
                Spacer()
            }
            Picker(L("Tipo"), selection: $kind) {
                ForEach(Kind.allCases) { Text(L($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .keys: keysEditor
            case .media: mediaEditor
            case .mouse: mouseEditor
            case .program: programEditor
            case .none:
                Text(L("A tecla não faz nada.")).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                validation
                Spacer()
                Button(kind == .none ? L("Limpar no pad") : L("Gravar no pad")) {
                    recorder.stop()
                    if kind == .program { model.setCommand(slot, command) }
                    else if let text = actionText { model.set(slot, to: text) } else { model.clear(slot) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canWrite)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .onDisappear { recorder.stop() }
    }

    private var canWrite: Bool {
        guard model.connected, !model.busy, !isUnchanged else { return false }
        if kind == .program { return command.isValid }
        if case .failure? = parsed { return false }
        return true
    }

    // MARK: Editors

    private var keysEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(L("ex.: shift+cmd+4  ou  cmd+a, cmd+c"), text: $keysText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(recorder.isRecording)
                Button {
                    if recorder.isRecording { recorder.stop() } else { startRecording() }
                } label: {
                    Label(recorder.isRecording ? L("Parar") : L("Gravar"),
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .foregroundStyle(recorder.isRecording ? .red : .primary)
                .help(L("Aperte o atalho no teclado; cada aperto vira um passo (até %@)", String(Action.maxSteps)))
            }
            Text(recorder.isRecording
                 ? L("Gravando… aperte até %@ atalhos (%@/%@). Atalhos do sistema, como ⇧⌘4, precisam ser digitados.", String(Action.maxSteps), String(recordedSteps), String(Action.maxSteps))
                 : L("Modificadores: ctrl, opt, shift, cmd (+ r para o lado direito). Separe passos de uma sequência com vírgula."))
                .font(.caption2)
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mediaEditor: some View {
        Picker(L("Tecla de mídia"), selection: $media) {
            ForEach(Keys.media.map(\.name), id: \.self) { name in
                Text(Action.mediaTitle(name)).tag(name)
            }
        }
    }

    private var mouseEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("Ação do mouse"), selection: $mouse) {
                ForEach(Keys.mouse.map(\.name), id: \.self) { name in
                    Text(Action.mouseTitle(name)).tag(name)
                }
            }
            HStack(spacing: 10) {
                Text(L("Segurando:")).font(.caption).foregroundStyle(.secondary)
                ForEach([("ctrl", "⌃ ctrl"), ("opt", "⌥ opt"), ("shift", "⇧ shift"), ("cmd", "⌘ cmd")], id: \.0) { name, title in
                    Toggle(title, isOn: Binding(
                        get: { mouseMods.contains(name) },
                        set: { if $0 { mouseMods.insert(name) } else { mouseMods.remove(name) } }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var validation: some View {
        if kind == .program {
            if let trigger = model.layout.text(layer: layer, slot: slot), initialCommand != nil, command == initialCommand,
               let action = try? Action(parsing: trigger) {
                Label(L("A tecla envia %@", action.displayLabel), systemImage: "keyboard")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        } else {
            keyValidation
        }
    }

    @ViewBuilder private var keyValidation: some View {
        switch parsed {
        case .success(let action)?:
            HStack(spacing: 4) {
                Image(systemName: action.usesUnverifiedKeys ? "exclamationmark.triangle" : "checkmark")
                    .foregroundStyle(action.usesUnverifiedKeys ? .orange : .green)
                Text(action.usesUnverifiedKeys
                     ? action.canonical + L(" — o firmware pode não enviar esta tecla")
                     : action.canonical)
                    .font(.caption.monospaced())
                    .lineLimit(2)
            }
        case .failure(let error)?:
            Label(error.localizedDescription, systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private var programEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("Ação"), selection: $commandKind) {
                Text(L("Abrir app")).tag(Command.Kind.openApp)
                Text(L("Abrir link ou arquivo")).tag(Command.Kind.openURL)
                Text(L("Executar script (zsh)")).tag(Command.Kind.shell)
                Text(L("Rodar atalho do app Atalhos")).tag(Command.Kind.shortcut)
            }
            .labelsHidden()
            .onChange(of: commandKind) { _ in commandValue = "" }

            switch commandKind {
            case .openApp:
                HStack {
                    if commandValue.isEmpty {
                        Text(L("Nenhum app escolhido")).foregroundStyle(.secondary)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: commandValue))
                            .resizable().frame(width: 18, height: 18)
                        Text(Command(kind: .openApp, value: commandValue).label).lineLimit(1)
                    }
                    Spacer()
                    AppPickerMenu(onPick: { commandValue = $0.path }) { Text(L("Escolher…")) }
                        .fixedSize()
                }
            case .openURL:
                TextField(L("https://… , obsidian://… ou file:///…"), text: $commandValue)
                    .textFieldStyle(.roundedBorder)
            case .shell:
                TextField(L("ex.: open -a Terminal ~/projeto && say pronto"), text: $commandValue, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...4)
            case .shortcut:
                TextField(L("Nome do atalho, ex.: Modo foco"), text: $commandValue)
                    .textFieldStyle(.roundedBorder)
            }

            Text(commandKind == .shell
                 ? L("Roda no zsh com seu PATH de login. A saída vai para ~/Library/Logs/Macropad.log. O app Macropad precisa estar aberto.")
                 : L("O pad envia um atalho reservado (⌃⌥⇧⌘ + tecla) e o Macropad faz o resto. O app precisa estar aberto."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startRecording() {
        recordedSteps = 0
        recorder.start { step in
            keysText = recordedSteps == 0 ? step : keysText + ", " + step
            recordedSteps += 1
            return recordedSteps < Action.maxSteps
        }
    }
}
