import AppKit
import MacropadCore
import SwiftUI

/// "Trocar preset pelo app em uso": rules app -> preset, plus a default for the other apps.
struct AutomationView: View {
    @EnvironmentObject private var model: PadModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Label(L("Preset por app"), systemImage: "macwindow.on.rectangle").font(.subheadline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if model.config.autoSwitch, let active = model.preset(id: model.activePresetID) {
                    Text(active.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Toggle(L("Automático"), isOn: Binding(get: { model.config.autoSwitch }, set: { model.setAutoSwitch($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(L("Troca o preset do pad sozinho quando você muda de app"))
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if model.config.rules.isEmpty {
                        Text(L("Nenhum app ainda. Adicione um app e escolha o preset que ele usa."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.config.rules) { rule in
                        RuleRow(rule: rule)
                    }
                    HStack {
                        Image(systemName: "square.dashed").frame(width: 18).foregroundStyle(.secondary)
                        Text(L("Outros apps")).font(.callout)
                        Spacer()
                        PresetPicker(selection: Binding(
                            get: { model.config.defaultPreset },
                            set: { model.setDefaultPreset($0) }), allowNone: true)
                    }
                    HStack {
                        AppPickerMenu(onPick: { app in
                            guard let bundleID = app.bundleID else { return }
                            model.setRule(bundleID: bundleID, appName: app.name,
                                          presetID: model.activePresetID ?? Preset.vibeCoder.id)
                        }) { Label(L("Adicionar app"), systemImage: "plus") }
                            .fixedSize()
                        Spacer()
                        if let front = model.frontAppName {
                            Text(L("Em uso: %@", front)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                    Text(L("Edições feitas aqui valem até a próxima troca de app. Para guardar, salve como preset (⋯ → Salvar) com o mesmo nome."))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 4)
            }
        }
    }
}

private struct RuleRow: View {
    @EnvironmentObject private var model: PadModel
    let rule: AutoRule

    var body: some View {
        HStack {
            AppIcon(bundleID: rule.bundleID).frame(width: 18, height: 18)
            Text(rule.appName).font(.callout).lineLimit(1)
            Spacer()
            PresetPicker(selection: Binding(
                get: { rule.preset },
                set: { if let id = $0 { model.setRule(bundleID: rule.bundleID, appName: rule.appName, presetID: id) } }),
                allowNone: false)
            Button { model.removeRule(bundleID: rule.bundleID) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(L("Remover"))
        }
    }
}

private struct PresetPicker: View {
    @EnvironmentObject private var model: PadModel
    @Binding var selection: String?
    let allowNone: Bool

    var body: some View {
        Picker(L("Preset"), selection: $selection) {
            if allowNone { Text(L("Não mudar")).tag(String?.none) }
            ForEach(model.allPresets) { preset in
                Text(preset.displayName).tag(Optional(preset.id))
            }
        }
        .labelsHidden()
        .frame(width: 170)
        .controlSize(.small)
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed")
        }
    }
}
