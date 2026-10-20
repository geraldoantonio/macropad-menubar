import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An installed application.
struct InstalledApp: Identifiable, Hashable {
    let name: String
    let path: String
    let bundleID: String?
    var id: String { path }
    var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

enum AppCatalog {
    /// Apps in the usual folders (one level of subfolders, e.g. /Applications/Utilities).
    static func installed() -> [InstalledApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/System/Applications", "\(home)/Applications"]
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            for path in appPaths(in: root, depth: 2) {
                let app = make(path)
                if seen.insert(app.bundleID ?? app.path).inserted { apps.append(app) }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Regular apps that are running now (the ones you'd see in the Dock).
    static func running() -> [InstalledApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { $0.bundleURL.map { make($0.path) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func make(_ path: String) -> InstalledApp {
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        return InstalledApp(name: name, path: path, bundleID: Bundle(path: path)?.bundleIdentifier)
    }

    private static func appPaths(in directory: String, depth: Int) -> [String] {
        guard depth > 0, let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var paths: [String] = []
        for entry in entries where !entry.hasPrefix(".") {
            let path = (directory as NSString).appendingPathComponent(entry)
            if entry.hasSuffix(".app") {
                paths.append(path)
            } else {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    paths += appPaths(in: path, depth: depth - 1)
                }
            }
        }
        return paths
    }

    /// Fallback file panel, raised above the menu bar window so it doesn't open behind it.
    static func chooseWithPanel(message: String) -> InstalledApp? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = message
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return make(url.path)
    }
}

/// A menu of apps (running first, then everything installed) that stays inside the popover.
struct AppPickerMenu<LabelView: View>: View {
    let onPick: (InstalledApp) -> Void
    @ViewBuilder let label: () -> LabelView

    @State private var installed: [InstalledApp] = []
    @State private var running: [InstalledApp] = []

    var body: some View {
        Menu {
            if !running.isEmpty {
                Section("Abertos agora") {
                    ForEach(running) { item($0) }
                }
            }
            Section("Aplicativos") {
                ForEach(installed) { item($0) }
            }
            Divider()
            Button("Outro…") {
                if let app = AppCatalog.chooseWithPanel(message: "Escolha um app") { onPick(app) }
            }
        } label: {
            label()
        }
        .onAppear(perform: refresh)
    }

    private func item(_ app: InstalledApp) -> some View {
        Button {
            onPick(app)
        } label: {
            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
        }
    }

    private func refresh() {
        running = AppCatalog.running()
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = AppCatalog.installed()
            DispatchQueue.main.async { installed = apps }
        }
    }
}
