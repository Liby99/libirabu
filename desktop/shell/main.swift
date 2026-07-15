// libirabu — native macOS menu-bar shell.
//
// A tiny agent app (no Dock icon). On launch it spawns the bundled Node "supervisor" (which starts the
// embedded Postgres + the Next.js server), reads "READY <port>" from its stdout, then shows a status-bar
// menu. "Open" launches the DEFAULT BROWSER at the local server. Quit stops the supervisor cleanly.
//
// Paths resolve for a packaged .app (Contents/Resources/runtime/…) OR, in dev, from env overrides:
//   LIBIRABU_NODE, LIBIRABU_SUPERVISOR, LIBIRABU_ROOT, LIBIRABU_SERVER, LIBIRABU_HOME

import Cocoa

struct Paths {
    let node: String
    let supervisor: String
    let root: String
    let server: String
    let home: String
    var logs: String { home + "/logs" }
}

func resolvePaths() -> Paths? {
    let env = ProcessInfo.processInfo.environment
    let home = env["LIBIRABU_HOME"] ?? (NSHomeDirectory() + "/Library/Application Support/libirabu")
    // Packaged: Contents/Resources/runtime/ holds everything.
    if let res = Bundle.main.resourcePath,
       FileManager.default.fileExists(atPath: res + "/runtime/supervisor.cjs") {
        let rt = res + "/runtime"
        return Paths(node: rt + "/node", supervisor: rt + "/supervisor.cjs",
                     root: rt, server: rt + "/server/server.js", home: home)
    }
    // Dev: explicit overrides so we can run the shell against the repo.
    guard let node = env["LIBIRABU_NODE"], let sup = env["LIBIRABU_SUPERVISOR"],
          let root = env["LIBIRABU_ROOT"], let server = env["LIBIRABU_SERVER"] else { return nil }
    return Paths(node: node, supervisor: sup, root: root, server: server, home: home)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    let openItem = NSMenuItem(title: "Open libirabu", action: #selector(openApp), keyEquivalent: "o")
    var supervisor: Process?
    var port: Int?
    var stdoutBuf = Data()
    var paths: Paths!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
        buildStatusItem()
        guard let p = resolvePaths() else {
            statusLine.title = "Config error (no runtime found)"
            NSApp.presentError(NSError(domain: "libirabu", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Could not locate the bundled runtime. In dev, set LIBIRABU_NODE / LIBIRABU_SUPERVISOR / LIBIRABU_ROOT / LIBIRABU_SERVER."]))
            return
        }
        paths = p
        startSupervisor()
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "calendar", accessibilityDescription: "libirabu") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "◧"
        }
        let menu = NSMenu()
        openItem.target = self
        openItem.isEnabled = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(openItem)
        let logs = NSMenuItem(title: "Open Logs Folder", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit libirabu", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func startSupervisor() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: paths.node)
        proc.arguments = [paths.supervisor]
        var env = ProcessInfo.processInfo.environment
        env["LIBIRABU_HOME"] = paths.home
        env["LIBIRABU_ROOT"] = paths.root
        env["LIBIRABU_SERVER"] = paths.server
        proc.environment = env
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice // supervisor already mirrors to its log file
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { return }
            DispatchQueue.main.async { self?.onStdout(data) }
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.onSupervisorExit(p.terminationStatus) }
        }
        do {
            try proc.run()
            supervisor = proc
        } catch {
            statusLine.title = "Failed to launch runtime"
            NSApp.presentError(error)
        }
    }

    // Parse the supervisor's line protocol on stdout: READY <port> / ERROR <msg> / EXIT <code>.
    func onStdout(_ data: Data) {
        stdoutBuf.append(data)
        while let nl = stdoutBuf.firstIndex(of: 0x0A) {
            let lineData = stdoutBuf.subdata(in: stdoutBuf.startIndex..<nl)
            stdoutBuf.removeSubrange(stdoutBuf.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first {
            case "READY":
                if parts.count > 1, let p = Int(parts[1]) { becameReady(port: p) }
            case "ERROR":
                statusLine.title = "Failed to start"
                NSApp.presentError(NSError(domain: "libirabu", code: 2, userInfo: [NSLocalizedDescriptionKey: parts.count > 1 ? parts[1] : "Startup error. See logs."]))
            default:
                break
            }
        }
    }

    func becameReady(port: Int) {
        self.port = port
        statusLine.title = "Running on :\(port)"
        openItem.isEnabled = true
        openBrowser() // auto-open once on first ready
    }

    func onSupervisorExit(_ code: Int32) {
        port = nil
        openItem.isEnabled = false
        statusLine.title = "Stopped"
    }

    @objc func openApp() { openBrowser() }

    func openBrowser() {
        guard let port = port, let url = URL(string: "http://127.0.0.1:\(port)/calendar") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openLogs() {
        try? FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: paths.logs))
    }

    @objc func quit() {
        if let sup = supervisor, sup.isRunning {
            sup.terminate() // SIGTERM → supervisor stops Next + Postgres, then exits
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(10)
                while sup.isRunning && Date() < deadline { usleep(100_000) }
                if sup.isRunning { sup.interrupt() }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        if let sup = supervisor, sup.isRunning { sup.terminate() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
