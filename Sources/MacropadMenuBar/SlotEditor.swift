import MacropadCore
import SwiftUI

/// Edits what one slot does: a key combo/sequence, a media key, a mouse action or nothing.
struct SlotEditor: View {
    enum Kind: String, CaseIterable, Identifiable {
        case keys = "Teclas", media = "Mídia", mouse = "Mouse", none = "Nada"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: PadModel
    @StateObject private var recorder = ShortcutRecorder()

    let slot: Slot
    let layer: Int
    let current: String?

    @State private var kind: Kind
    @State private var keysText: String
    @State private var media: String
    @State private var mouse: String
    @State private var mouseMods: Set<String>
    @State private var recordedSteps = 0

    init(slot: Slot, layer: Int, current: String?) {
        self.slot = slot
        self.layer = layer
        self.current = current
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
        case .none: nil
        }
    }

    private var parsed: Result<Action, Error>? {
        actionText.map { text in Result { try Action(parsing: text) } }
    }

    private var isUnchanged: Bool {
        guard let text = actionText else { return current == nil }
        guard let current, let a = try? Action(parsing: text), let b = try? Action(parsing: current) else { return false }
        return a == b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(slot.title).font(.subheadline.weight(.semibold))
                Text("· camada \(layer)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Tipo", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            switch kind {
            case .keys: keysEditor
            case .media: mediaEditor
            case .mouse: mouseEditor
            case .none:
                Text("A tecla não faz nada.").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                validation
                Spacer()
                Button(kind == .none ? "Limpar no pad" : "Gravar no pad") {
                    recorder.stop()
                    if let text = actionText { model.set(slot, to: text) } else { model.clear(slot) }
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
        if case .failure? = parsed { return false }
        return true
    }

    // MARK: Editors

    private var keysEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("ex.: shift+cmd+4  ou  cmd+a, cmd+c", text: $keysText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(recorder.isRecording)
                Button {
                    if recorder.isRecording { recorder.stop() } else { startRecording() }
                } label: {
                    Label(recorder.isRecording ? "Parar" : "Gravar",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .foregroundStyle(recorder.isRecording ? .red : .primary)
                .help("Aperte o atalho no teclado; cada aperto vira um passo (até \(Action.maxSteps))")
            }
            Text(recorder.isRecording
                 ? "Gravando… aperte até \(Action.maxSteps) atalhos (\(recordedSteps)/\(Action.maxSteps)). Atalhos do sistema, como ⇧⌘4, precisam ser digitados."
                 : "Modificadores: ctrl, opt, shift, cmd (+ r para o lado direito). Separe passos de uma sequência com vírgula.")
                .font(.caption2)
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mediaEditor: some View {
        Picker("Tecla de mídia", selection: $media) {
            ForEach(Keys.media.map(\.name), id: \.self) { name in
                Text(Action.mediaTitles[name] ?? name).tag(name)
            }
        }
    }

    private var mouseEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Ação do mouse", selection: $mouse) {
                ForEach(Keys.mouse.map(\.name), id: \.self) { name in
                    Text(Action.mouseTitles[name] ?? name).tag(name)
                }
            }
            HStack(spacing: 10) {
                Text("Segurando:").font(.caption).foregroundStyle(.secondary)
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
        switch parsed {
        case .success(let action)?:
            HStack(spacing: 4) {
                Image(systemName: action.usesUnverifiedKeys ? "exclamationmark.triangle" : "checkmark")
                    .foregroundStyle(action.usesUnverifiedKeys ? .orange : .green)
                Text(action.usesUnverifiedKeys
                     ? "\(action.canonical) — o firmware pode não enviar esta tecla"
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

    private func startRecording() {
        recordedSteps = 0
        recorder.start { step in
            keysText = recordedSteps == 0 ? step : keysText + ", " + step
            recordedSteps += 1
            return recordedSteps < Action.maxSteps
        }
    }
}
