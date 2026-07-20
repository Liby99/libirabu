// Renders the DMG volume icon: the system's standard disk-image icon with the MagiCal app icon
// composited in its center — the classic "disk with the app inside" a mounted MagiCal.dmg shows.
//
// The base comes from NSWorkspace.icon(for: .diskImage) — whatever icon THIS macOS uses for
// disk images — so the artwork tracks the OS instead of a copied template rotting in the repo.
//
//   swift make-dmg-icon.swift <app-icon.(icns|png)> <out.icns>
//
// Writes a full iconset (16…512@2x) and compiles it with iconutil.

import AppKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-dmg-icon.swift <app-icon> <out.icns>\n".utf8))
    exit(1)
}
guard let appIcon = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("cannot load app icon: \(args[1])\n".utf8))
    exit(1)
}
let base = NSWorkspace.shared.icon(for: UTType.diskImage)

// Composite tuning: the app icon's size relative to the disk, and a slight downward shift so it
// sits on the disk's body rather than optically floating high (the disk artwork is bottom-heavy).
let overlayScale: CGFloat = 0.62
let overlayYShift: CGFloat = -0.02 // fraction of the edge; negative = down

func renderPNG(_ px: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let edge = CGFloat(px)
    base.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
    let s = edge * overlayScale
    appIcon.draw(in: NSRect(x: (edge - s) / 2, y: (edge - s) / 2 + edge * overlayYShift,
                            width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("dmgicon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    renderPNG(size, to: tmp.appendingPathComponent("icon_\(size)x\(size).png"))
    renderPNG(size * 2, to: tmp.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let out = URL(fileURLWithPath: args[2])
try? fm.removeItem(at: out)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: tmp)
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(out.path)")
