import AppKit
import MacropadCore
import SwiftUI

/// `MacropadMenuBar --screenshots <dir>` renders the panel with sample data into PNGs and quits.
/// Used by .github/workflows/screenshots.yml to keep the README images in sync with the app.
/// Nothing is read from or written to the pad, the config files or the global shortcuts.
@MainActor
enum ScreenshotMode {
    nonisolated static var outputDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Sample layout: a mix of shortcuts, media and one program key.
        let appPath = "/System/Applications/Calculator.app"
        let trigger = AppConfig.triggerPool[0]
        var config = AppConfig()
        config.commands[trigger] = Command(kind: .openApp, value: appPath)
        config.autoSwitch = true
        config.rules = [
            AutoRule(bundleID: "com.apple.Terminal", appName: "Terminal", preset: Preset.vibeCoder.id),
            AutoRule(bundleID: "com.apple.Safari", appName: "Safari", preset: Preset.browsing.id),
            AutoRule(bundleID: "com.apple.Music", appName: "Music", preset: Preset.media.id),
        ]
        config.defaultPreset = Preset.editing.id
        let layout = Layout(led: 2, layers: [1: [
            .key1: trigger, .key2: "play", .key3: "next",
            .key4: "shift+cmd+4", .key5: "mute", .key6: "cmd+a, cmd+c",
            .knobLeft: "volume-down", .knobPress: "mute", .knobRight: "volume-up",
        ]])

        let shots: [(name: String, language: Language, selected: Slot, expanded: Bool, message: String?)] = [
            ("painel", .pt, .key4, false, nil),
            ("programa", .pt, .key1, false, nil),
            ("preset-por-app", .pt, .key2, true, nil),
            ("panel-en", .en, .key4, false, nil),
        ]

        for shot in shots {
            L10n.override = shot.language
            let model = PadModel(demo: true)
            model.loadDemo(layout: layout, config: config, selected: shot.selected,
                           message: shot.message.map { .init(text: $0, isError: false) },
                           frontApp: "Terminal", activePreset: Preset.vibeCoder.id, expanded: shot.expanded)
            let url = directory.appendingPathComponent(shot.name).appendingPathExtension("png")
            do {
                try render(ContentView().environmentObject(model), to: url)
                print("wrote \(url.path)")
            } catch {
                FileHandle.standardError.write(Data("\(shot.name): \(error)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }

    /// Draws the view in a real (off-screen) window so AppKit-backed controls render too.
    private static func render<V: View>(_ view: V, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI finish a couple of layout passes (async images, app icons, segmented controls).
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        // Retina (2x) regardless of the runner's display.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(hosting.bounds.width * scale),
                                         pixelsHigh: Int(hosting.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        rep.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        window.orderOut(nil)
    }
}
