// Renders a minimalist macOS app icon (1024×1024 master PNG) using CoreGraphics.
// Design: a "calendar page" — rounded card with a subtle gradient, an accent header
// band with two binding tabs, and a clean grid of day cells with one accent "today".
// Big Sur icon-grid proportions: 824×824 content centered in a 1024 canvas (100px
// margins), corner radius ≈ 0.225 · side, with a soft drop shadow.

import AppKit

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])!
}

// Squircle path (continuous rounded rect) via NSBezierPath for a nicer corner curve.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

let margin: CGFloat = 100
let card = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius = card.width * 0.2237
let cardPath = squircle(card, radius: radius)

// ---- soft drop shadow under the card ----
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44,
              color: rgb(0, 0, 0, 0.28))
ctx.addPath(cardPath); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
ctx.restoreGState()

// ---- card background: subtle vertical gradient (near-white paper) ----
ctx.saveGState()
ctx.addPath(cardPath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(255, 255, 255), rgb(240, 241, 244)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: card.maxY),
                       end: CGPoint(x: 0, y: card.minY), options: [])

// ---- accent header band (top ~27% of the card) ----
let accentTop = rgb(255, 92, 74)     // warm coral
let accentBot = rgb(240, 62, 74)     // deeper red
let bandH = card.height * 0.27
let bandRect = CGRect(x: card.minX, y: card.maxY - bandH, width: card.width, height: bandH)
ctx.saveGState()
ctx.addRect(bandRect); ctx.clip()   // clip band to card (already clipped) + its own rect
let bandGrad = CGGradient(colorsSpace: cs, colors: [accentTop, accentBot] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bandGrad, start: CGPoint(x: 0, y: bandRect.maxY),
                       end: CGPoint(x: 0, y: bandRect.minY), options: [])
ctx.restoreGState()

// ---- two binding tabs straddling the band's bottom edge ----
let tabW = card.width * 0.055
let tabH = card.height * 0.11
let tabY = bandRect.minY - tabH * 0.42
let graphite = rgb(58, 60, 66)
for frac in [0.34, 0.66] as [CGFloat] {
    let x = card.minX + card.width * frac - tabW/2
    let r = CGRect(x: x, y: tabY, width: tabW, height: tabH)
    ctx.addPath(squircle(r, radius: tabW/2)); ctx.setFillColor(graphite); ctx.fillPath()
}

// ---- day grid in the body: 4 cols × 3 rows of rounded cells; one accent "today" ----
let body = CGRect(x: card.minX, y: card.minY, width: card.width, height: bandRect.minY - card.minY)
let cols = 4, rows = 3
let padX = body.width * 0.14
let padTop = body.height * 0.20
let padBot = body.height * 0.18
let gridW = body.width - 2*padX
let gridH = body.height - padTop - padBot
let gap = gridW * 0.055
let cell = min((gridW - CGFloat(cols-1)*gap) / CGFloat(cols),
               (gridH - CGFloat(rows-1)*gap) / CGFloat(rows))
let usedW = CGFloat(cols)*cell + CGFloat(cols-1)*gap
let usedH = CGFloat(rows)*cell + CGFloat(rows-1)*gap
let ox = body.minX + (body.width - usedW)/2
let oyTop = body.maxY - padTop        // grid grows downward from here
let dim = rgb(214, 216, 222)
let todayCol = 1, todayRow = 1        // 0-indexed (col from left, row from top)
for row in 0..<rows {
    for col in 0..<cols {
        let x = ox + CGFloat(col)*(cell+gap)
        let y = oyTop - CGFloat(row+1)*cell - CGFloat(row)*gap
        let r = CGRect(x: x, y: y, width: cell, height: cell)
        let isToday = (col == todayCol && row == todayRow)
        ctx.addPath(squircle(r, radius: cell*0.28))
        ctx.setFillColor(isToday ? accentBot : dim)
        ctx.fillPath()
    }
}
ctx.restoreGState()

// ---- write PNG ----
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
