// Contents of the macOS "File" menu (hosted by the app via `CommandGroup(replacing: .importExport)`):
// import an `.ics` calendar file, and import/export a `.mdc` backup (a zip mirroring the web app's data
// export — see MDCBackup). Panels + alerts are AppKit; the actual work lives on the engine.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CalendarEngine
import CalendarGeometry   // isoDayString

public struct FileCommands: View {
    let engine: CalendarEngine
    public init(engine: CalendarEngine) { self.engine = engine }

    public var body: some View {
        Button { importICS() } label: { Label("Import .ics…", systemImage: "calendar.badge.plus") }
        Divider()
        Button { importMDC() } label: { Label("Import Backup (.mdc)…", systemImage: "square.and.arrow.down") }
        Button { exportMDC() } label: { Label("Export Backup (.mdc)…", systemImage: "square.and.arrow.up") }
    }

    // ── .ics: additive import ──────────────────────────────────────────────────────────
    private func importICS() {
        guard let url = openPanel([UTType(filenameExtension: "ics") ?? .plainText, .plainText]) else { return }
        do {
            let n = try engine.importICS(from: url)
            info("Imported \(n) item\(n == 1 ? "" : "s") from “\(url.lastPathComponent)”.")
        } catch { report("Couldn’t import that .ics file.", error) }
    }

    // ── .mdc: full restore (destructive — confirm first) ───────────────────────────────
    private func importMDC() {
        let mdc = UTType(filenameExtension: "mdc") ?? .data
        guard let url = openPanel([mdc, .zip]) else { return }
        let a = NSAlert()
        a.messageText = "Replace all calendar data?"
        a.informativeText = "Importing “\(url.lastPathComponent)” replaces your current events, deadlines, notes, and track names with the backup’s contents. You can undo this with ⌘Z."
        a.alertStyle = .warning
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try engine.importMDC(from: url) }
        catch { report("Couldn’t import that backup.", error) }
    }

    private func exportMDC() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mdc") ?? .data]
        panel.nameFieldStringValue = "MagiCal-\(isoDayString()).mdc"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.exportMDC(to: url) }
        catch { report("Couldn’t export the backup.", error) }
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────
    private func openPanel(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func info(_ text: String) {
        let a = NSAlert(); a.messageText = text; a.alertStyle = .informational; a.addButton(withTitle: "OK"); a.runModal()
    }
    private func report(_ text: String, _ error: Error) {
        let a = NSAlert(); a.messageText = text
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning; a.addButton(withTitle: "OK"); a.runModal()
    }
}
