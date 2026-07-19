// Libirabu.app — a macOS menu-bar agent that hosts the app and opens it in your default browser
// (docs/calendar-import-design.md §5.2 / §12). This replaces the Electron host: it's a native app,
// so your real Safari renders the front-end (no Chromium style constraints).
//
// WHY it fixes calendar permissions: launched via LaunchServices (double-click / `open`), THIS app
// is the TCC "responsible process". It spawns the Next.js server as a CHILD, so the server — and the
// EventKit bridge it execs — inherit this app's Calendar grant. The app declares the calendar usage
// string in Info.plist, so the first Sync prompts under "Libirabu".
//
// The project dir + node path are baked into Info.plist by build-app.sh (env vars override).

import Cocoa
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var server: Process?
    let calURL = "http://libirabu.localhost:8100/calendar"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startServer()
    }

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "📅"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open My Calendar", action: #selector(openCalendar), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reveal Server Log", action: #selector(revealLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Libirabu", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc func openCalendar() {
        if let url = URL(string: calURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func revealLog() {
        let p = logPath()
        NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: (p as NSString).deletingLastPathComponent)
    }

    @objc func quitApp() {
        stopServer(); NSApp.terminate(nil)
    }

    func logPath() -> String {
        NSHomeDirectory() + "/Library/Logs/Libirabu/next-server.log"
    }

    func startServer() {
        let info = Bundle.main.infoDictionary
        let env0 = ProcessInfo.processInfo.environment
        let dir = env0["LIBIRABU_DIR"] ?? (info?["LibirabuProjectDir"] as? String) ?? ""
        let node = env0["LIBIRABU_NODE"] ?? (info?["LibirabuNode"] as? String) ?? "/opt/homebrew/bin/node"
        guard !dir.isEmpty else { NSLog("Libirabu: no project dir configured"); return }

        let logp = logPath()
        try? FileManager.default.createDirectory(
            atPath: (logp as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logp, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logp)

        // LaunchServices gives a minimal PATH; add node's dir so any `node` lookups downstream resolve.
        // LaunchServices gives a minimal PATH; add node + common docker dirs so scripts/serve.sh
        // (which runs docker, prisma, next) resolves its tools. serve.sh also hardens PATH itself.
        var env = env0
        env["PORT"] = "8100"
        env["LIBIRABU_NODE"] = node
        let nodeDir = (node as NSString).deletingLastPathComponent
        env["PATH"] = nodeDir + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.docker/bin:" +
            (env0["PATH"] ?? "/usr/bin:/bin")

        // Run the production launcher (ensure DB → migrate → build-if-needed → next start), NOT dev.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [dir + "/scripts/serve.sh"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = env
        if let h = logHandle {
            p.standardOutput = h; p.standardError = h
        }
        do { try p.run(); server = p } catch { NSLog("Libirabu: failed to start server: \(error)") }
    }

    func stopServer() {
        server?.terminate(); server = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar agent — no Dock icon, no main window
let delegate = AppDelegate()
app.delegate = delegate
app.run()
