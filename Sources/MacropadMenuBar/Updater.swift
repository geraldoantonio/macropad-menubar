import AppKit
import Foundation
import MacropadCore

/// "Atualizar Macropad": downloads the newest release and swaps the installed app.
///
/// Every push to main makes CI publish a GitHub Release with `Macropad.zip` and `commit.txt`,
/// so `releases/latest/download/…` always points at the newest build (no login needed).
/// Installing happens after the app quits: the script waits for this process, replaces
/// /Applications/Macropad.app and opens the new one.
enum Updater {
    static let repo = "geraldoantonio/macropad-menubar"

    /// Commit the running build was made from (written to Info.plist by build-app.sh).
    static var currentCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "MacropadCommit") as? String
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var versionDescription: String {
        if let commit = currentCommit, !commit.isEmpty { return "\(version) (\(commit.prefix(7)))" }
        return version
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Macropad-update.log")
    }

    enum CheckResult {
        case upToDate
        case available(commit: String)
        case failed(String)
    }

    /// Asks GitHub (or the local clone) for the newest commit on main.
    static func check() async -> CheckResult {
        let output = await run(mode: "check")
        let lines = output.text.split(separator: "\n").map(String.init)
        if let latest = lines.first(where: { $0.hasPrefix("LATEST ") }) {
            let parts = latest.split(separator: " ").map(String.init)
            let commit = parts.count > 1 ? parts[1] : ""
            guard commit.count >= 7 else { return .failed(L("resposta inesperada do GitHub: %@", latest)) }
            if let current = currentCommit, current.count >= 7, commit.hasPrefix(current) || current.hasPrefix(commit) {
                return .upToDate
            }
            return .available(commit: commit)
        }
        let error = lines.last(where: { $0.hasPrefix("ERRO") }).map { message(for: String($0.dropFirst(5))) }
        return .failed(error ?? (output.text.isEmpty ? L("sem resposta do script de atualização") : output.text))
    }

    /// Downloads/builds the new version, then quits this app; the script installs and relaunches.
    /// Returns only if something went wrong before the swap.
    static func install() async -> String {
        let output = await run(mode: "install")
        // Success means the script killed us; reaching here means it failed.
        let lines = output.text.split(separator: "\n").map(String.init)
        return lines.last(where: { $0.hasPrefix("ERRO") }).map { message(for: String($0.dropFirst(5))) }
            ?? L("a atualização falhou; veja %@", logURL.path)
    }

    /// The script reports failures as short codes; this turns them into text.
    private static func message(for code: String) -> String {
        switch code {
        case "net": L("não consegui consultar o GitHub (sem internet?)")
        case "nocommit": L("a release mais nova não tem commit.txt")
        case "download": L("download falhou")
        case "zip": L("zip inválido")
        case "noapp": L("não achei o Macropad.app no download")
        case "copy": L("não consegui copiar para /Applications")
        case "zsh": L("não consegui rodar o zsh")
        default: code
        }
    }

    private static func run(mode: String) async -> (status: Int32, text: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", script, "macropad-update", mode, repo,
                                 String(ProcessInfo.processInfo.processIdentifier)]
            // Output goes to a file, not a pipe: in install mode this app is killed mid-run.
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                process.standardOutput = handle
                process.standardError = handle
            }
            process.terminationHandler = { process in
                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                continuation.resume(returning: (process.terminationStatus, text))
            }
            do { try process.run() } catch {
                continuation.resume(returning: (-1, "ERRO zsh"))
            }
        }
    }

    /// $1 mode (check|install), $2 repo, $3 pid of this app.
    private static let script = #"""
    set -u
    MODE="$1"; REPO="$2"; APP_PID="$3"
    fail() { echo "ERRO $*"; exit 1; }

    # The API answers with the newest tag right away; releases/latest/download can lag a few
    # minutes behind a new release. Assets are then fetched by tag, which never changes.
    TAG=$(curl -fsSL --max-time 20 -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$REPO/releases/latest" \
          | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    [ -n "$TAG" ] || fail net
    BASE="https://github.com/$REPO/releases/download/$TAG"
    LATEST=$(curl -fsSL --max-time 20 "$BASE/commit.txt" | tr -d '[:space:]') \
      || fail nocommit
    [ -n "$LATEST" ] || fail nocommit
    echo "LATEST $LATEST $TAG"
    [ "$MODE" = check ] && exit 0

    WORK="$(mktemp -d /tmp/macropad-update.XXXXXX)"
    echo "Baixando…"
    curl -fL --max-time 300 -o "$WORK/Macropad.zip" "$BASE/Macropad.zip" || fail download
    ditto -xk "$WORK/Macropad.zip" "$WORK/app" || fail zip
    NEW=$(find "$WORK/app" -maxdepth 2 -name 'Macropad.app' | head -1)
    [ -d "${NEW:-}" ] || fail noapp

    echo "Instalando…"
    kill "$APP_PID" 2>/dev/null
    for i in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.2; done
    rm -rf /Applications/Macropad.app.old
    [ -d /Applications/Macropad.app ] && mv /Applications/Macropad.app /Applications/Macropad.app.old
    if ditto "$NEW" /Applications/Macropad.app; then
      rm -rf /Applications/Macropad.app.old
    else
      [ -d /Applications/Macropad.app.old ] && mv /Applications/Macropad.app.old /Applications/Macropad.app
      open /Applications/Macropad.app
      fail copy
    fi
    xattr -dr com.apple.quarantine /Applications/Macropad.app 2>/dev/null
    open /Applications/Macropad.app
    echo "OK $LATEST"
    rm -rf "$WORK"
    """#
}
