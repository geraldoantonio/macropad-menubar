import AppKit
import MacropadCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView()
            LayerPicker()
            PadView()
            if let slot = model.selectedSlot {
                SlotEditor(slot: slot, layer: model.layer,
                           current: model.layout.text(layer: model.layer, slot: slot),
                           command: model.command(for: slot))
                    .id("\(slot.rawValue)-\(model.layer)-\(model.layout.text(layer: model.layer, slot: slot) ?? "")-\(model.command(for: slot)?.value ?? "")")
            }
            Divider()
            LEDPicker()
            PresetsRow()
            AutomationView()
            MessageView()
            Divider()
            FooterView()
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if !model.busy { model.reload() }
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x2.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Macropad").font(.headline)
                Text("6 teclas + knob · USB 1189:8890").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            HStack(spacing: 5) {
                Circle()
                    .fill(model.connected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(model.connected ? "Conectado" : "Desconectado")
                    .font(.caption)
                    .foregroundStyle(model.connected ? .primary : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
    }
}

// MARK: - Layer

private struct LayerPicker: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Camada", selection: $model.layer) {
                ForEach(Array(PadProtocol.layers), id: \.self) { Text("Camada \($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.layer != 1 {
                Label("Neste pad a camada costuma ser ignorada: gravar na camada \(model.layer) sobrescreve a mesma tecla da camada 1.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The pad drawing

/// The pad drawn like the real thing: a brushed-aluminium plate on a black base, two rows of
/// black keycaps with RGB underglow (following the LED mode) and the knob at the back right,
/// beside the top row.
private struct PadView: View {
    @EnvironmentObject private var model: PadModel
    private let rows: [[Slot]] = [[.key1, .key2, .key3], [.key4, .key5, .key6]]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 10) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row) { slot in KeyCap(slot: slot) }
                    }
                }
            }
            KnobView()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(PadBody())
        .padding(.top, 8)  // room for the cable
        .padding(.bottom, 6)  // room for the base
        .frame(maxWidth: .infinity)
    }
}

private struct PadBody: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // USB cable leaving the back, behind the knob.
                Capsule()
                    .fill(Color(white: 0.12))
                    .frame(width: 7, height: 18)
                    .offset(x: geo.size.width - 66, y: -10)
                // Black base, a little thicker at the front.
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.1))
                    .offset(y: 5)
                // Brushed aluminium plate.
                RoundedRectangle(cornerRadius: 11)
                    .fill(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.80), Color(white: 0.90), Color(white: 0.78)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                // Corner screws.
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(Color(white: 0.6))
                        .overlay(Image(systemName: "plus").font(.system(size: 4, weight: .bold)).foregroundStyle(Color(white: 0.35)))
                        .frame(width: 6, height: 6)
                        .offset(x: i % 2 == 0 ? 5 : geo.size.width - 11, y: i < 2 ? 5 : geo.size.height - 11)
                }
            }
        }
    }
}

private struct KeyCap: View {
    @EnvironmentObject private var model: PadModel
    let slot: Slot

    /// Underglow colour: rainbow in mode 2, only the selected key in mode 1, off in mode 0.
    private var glow: Color? {
        switch model.layout.led {
        case 2?: Color(hue: (Double(Int(slot.deviceID) - 1) / 6.0 * 0.8 + 0.55).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 1)
        case 1?: model.selectedSlot == slot ? Color.cyan : nil
        default: nil
        }
    }

    var body: some View {
        let selected = model.selectedSlot == slot
        let text = model.layout.text(layer: model.layer, slot: slot)
        let label = model.label(for: slot)
        Button { model.selectedSlot = slot } label: {
            ZStack {
                if let glow {
                    Ellipse()
                        .fill(glow.opacity(0.85))
                        .frame(width: 58, height: 12)
                        .blur(radius: 6)
                        .offset(y: 26)
                }
                // Keycap skirt and the slightly lighter top face.
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 2)
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
                    .padding(EdgeInsets(top: 3, leading: 5, bottom: 8, trailing: 5))
                if selected {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .padding(-3)
                }
                Text(label.isEmpty ? "—" : label)
                    .font(.system(size: label.count > 6 ? 10 : 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(label.isEmpty ? 0.3 : 0.92))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
                    .padding(EdgeInsets(top: 3, leading: 7, bottom: 8, trailing: 7))
                Text(String(slot.rawValue.dropFirst(3)))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.leading, 8).padding(.top, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: 60, height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(slot.title): \(text ?? "sem ação")")
    }
}

private struct KnobView: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        VStack(spacing: 8) {
            Button { model.selectedSlot = .knobPress } label: {
                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: [Color(white: 0.08), Color(white: 0.3), Color(white: 0.1),
                                                       Color(white: 0.25), Color(white: 0.08)], center: .center))
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
                    // Knurled edge.
                    ForEach(0..<36, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1, height: 4)
                            .offset(y: -28)
                            .rotationEffect(.degrees(Double(i) * 10))
                    }
                    Circle().fill(Color(white: 0.13)).padding(6)
                    // White indicator line.
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 11).offset(y: -15).rotationEffect(.degrees(-55))
                    if model.selectedSlot == .knobPress {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3)
                    }
                }
                .frame(width: 62, height: 62)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Knob pressionar: \(model.layout.text(layer: model.layer, slot: .knobPress) ?? "sem ação")")

            HStack(spacing: 6) {
                turnButton(.knobLeft, systemImage: "arrow.counterclockwise")
                turnButton(.knobRight, systemImage: "arrow.clockwise")
            }
            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(white: 0.25))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 80)
        }
    }

    private var caption: String {
        guard let slot = model.selectedSlot, [.knobLeft, .knobPress, .knobRight].contains(slot) else { return "Knob" }
        let label = model.label(for: slot)
        return label.isEmpty ? "—" : label
    }

    private func turnButton(_ slot: Slot, systemImage: String) -> some View {
        let selected = model.selectedSlot == slot
        return Button { model.selectedSlot = slot } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(selected ? Color.white : Color(white: 0.2))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.white.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(slot.title): \(model.layout.text(layer: model.layer, slot: slot) ?? "sem ação")")
    }
}

// MARK: - LED, presets, messages, footer

private struct LEDPicker: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        HStack {
            Label("LED", systemImage: "light.max").font(.subheadline)
            Spacer()
            Picker("LED", selection: Binding<Int?>(
                get: { model.layout.led },
                set: { if let mode = $0, mode != model.layout.led { model.setLED(mode) } }
            )) {
                ForEach(PadProtocol.ledModes, id: \.self) { Text(PadModel.ledTitles[$0]).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)
            .disabled(!model.connected || model.busy)
        }
    }
}

private struct PresetsRow: View {
    @EnvironmentObject private var model: PadModel
    @State private var newName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Presets", systemImage: "square.stack.3d.up").font(.subheadline)
                Spacer()
                Menu("Aplicar preset") {
                    Section("Prontos") {
                        ForEach(Preset.builtIns) { preset in
                            Button(preset.name) { model.applyPreset(preset) }
                        }
                    }
                    if !model.userPresets.isEmpty {
                        Section("Meus presets") {
                            ForEach(model.userPresets) { preset in
                                Menu(preset.name) {
                                    Button("Aplicar") { model.applyPreset(preset) }
                                    Button("Excluir", role: .destructive) { model.deletePreset(preset) }
                                }
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(!model.connected || model.busy)
                Menu {
                    Button("Salvar layout atual como preset…") { newName = "" }
                    Button("Importar preset (YAML)…") { model.importPreset() }
                    Button("Exportar layout atual…") { model.exportLayout() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            if newName != nil {
                HStack {
                    TextField("Nome do preset", text: Binding(get: { newName ?? "" }, set: { newName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Salvar", action: save).disabled((newName ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancelar") { newName = nil }
                }
            }
        }
    }

    private func save() {
        guard let name = newName, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.savePreset(named: name)
        newName = nil
    }
}

private struct MessageView: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        if let message = model.message {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? .red : .green)
                Text(message.text)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if model.undoLayout != nil {
                    Button("Desfazer") { model.undo() }.controlSize(.small)
                }
                Button { model.message = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill((message.isError ? Color.red : Color.green).opacity(0.1)))
        }
    }
}

private struct FooterView: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        HStack {
            if model.identifying {
                Button("Restaurar layout") { model.reapplyCurrent() }
            } else {
                Button("Identificar teclas") { model.identify() }
                    .help("Cada tecla passa a digitar seu número (1–6; knob 7/8/9) para você descobrir qual é qual")
            }
            Button("Regravar tudo") { model.reapplyCurrent() }
                .help("Grava o layout inteiro de novo no pad (útil se ele foi programado por outro programa)")
            Spacer()
            Menu {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
                Button(model.updating ? "Atualizando…" : "Atualizar Macropad…") { model.checkForUpdates() }
                    .disabled(model.updating)
                Button("Mostrar arquivo de layout") { model.revealLayoutFile() }
                Button("Recarregar") { model.reload() }
                Divider()
                Button("Sair do Macropad") { NSApp.terminate(nil) }
                Divider()
                Text("Versão \(Updater.versionDescription)")
            } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
        .controlSize(.small)
        .disabled(model.busy)
    }
}
