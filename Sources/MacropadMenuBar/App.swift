import AppKit
import MacropadCore
import SwiftUI

@main
struct MacropadMenuBarApp: App {
    @StateObject private var model: PadModel

    init() {
        if let directory = ScreenshotMode.outputDirectory {
            // Screenshot mode: a model with no side effects, and render once the app is running.
            _model = StateObject(wrappedValue: PadModel(demo: true))
            Task { @MainActor in ScreenshotMode.run(into: directory) }
        } else {
            _model = StateObject(wrappedValue: PadModel())
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.connected ? "square.grid.3x2.fill" : "square.grid.3x2")
                .accessibilityLabel(model.connected ? L("Macropad conectado") : L("Macropad desconectado"))
        }
        .menuBarExtraStyle(.window)
    }
}
