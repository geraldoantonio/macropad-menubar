import MacropadCore
import SwiftUI

@main
struct MacropadMenuBarApp: App {
    @StateObject private var model = PadModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.connected ? "square.grid.3x2.fill" : "square.grid.3x2")
                .accessibilityLabel(model.connected ? "Macropad conectado" : "Macropad desconectado")
        }
        .menuBarExtraStyle(.window)
    }
}
