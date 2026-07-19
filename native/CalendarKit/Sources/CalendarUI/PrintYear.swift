// File ▸ Print… (⌘P) on the YEAR view. Renders a print-specific layout — NOT the live canvas — through
// the macOS system print pipeline: two landscape-letter pages (six stacked full-width month rows each,
// a quarter gap between Q1/Q2 and Q3/Q4), white background, light theme, flat fills, no header/footer.
//
// Pipeline: PrintYearPage (plain SwiftUI, fixed 792×612pt) → ImageRenderer.render into a PDF CGContext
// (vector text/shapes) → PDFDocument → NSPrintOperation (system print panel as a window sheet).
// Dev hook: CC_PRINT_PDF=<path> writes the PDF there and skips the panel (layout verification).

import SwiftUI
import AppKit
import PDFKit
import CalendarGeometry
import CalendarEngine

@MainActor
enum PrintYear {
    static let pageW: CGFloat = 792, pageH: CGFloat = 612   // landscape US Letter, points

    /// Build the 2-page PDF for `engine.year` and hand it to the system print panel.
    static func run(engine: CalendarEngine, window: NSWindow?) {
        let year = engine.year
        let bands = engine.displayBands(for: year)          // incl. recurrence, promoted ghosts, imports, tag filter
        let tracks = engine.items.trackNames
        guard let pdf = makePDF(year: year, bands: bands, tracks: tracks) else { return }

        // Dev hook: write the PDF for inspection instead of opening the (modal) print panel.
        if let out = ProcessInfo.processInfo.environment["CC_PRINT_PDF"], !out.isEmpty {
            try? pdf.write(to: URL(fileURLWithPath: out))
            return
        }
        guard let doc = PDFDocument(data: pdf) else { return }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)    // letter; autoRotate turns our landscape pages
        info.orientation = .landscape
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        op.showsPrintPanel = true
        if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
        else { op.run() }
    }

    /// Two vector PDF pages (Jan–Jun, Jul–Dec) rendered from PrintYearPage.
    private static func makePDF(year: Int, bands: [BandEvent], tracks: [[String]]) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        for half in 0..<2 {
            let page = PrintYearPage(year: year, firstMonth: half * 6, bands: bands, tracks: tracks)
                .frame(width: pageW, height: pageH)
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(width: pageW, height: pageH)
            ctx.beginPDFPage(nil)
            renderer.render { _, draw in draw(ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}

/// One landscape-letter page: six month rows (two quarters), stacked full-width like the on-screen year
/// view — wide day columns, compact lanes. Light theme, white paper; self-contained (plain data in, no
/// engine observation) so ImageRenderer can snapshot it.
struct PrintYearPage: View {
    let year: Int
    let firstMonth: Int        // 0 (Jan–Jun) or 6 (Jul–Dec)
    let bands: [BandEvent]
    let tracks: [[String]]

    private let theme = Theme(dark: false)
    private let pad: CGFloat = 22
    private let gutterW: CGFloat = 58        // month name + track names
    private let quarterGap: CGFloat = 14     // extra breathing room between the two quarters
    private let laneH: CGFloat = 17
    private let dayNumH: CGFloat = 9

    var body: some View {
        let contentW = PrintYear.pageW - pad * 2
        let rowGap: CGFloat = 7
        let rowH = (PrintYear.pageH - pad * 2 - quarterGap - rowGap * 5) / 6
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<6, id: \.self) { i in
                monthRow(firstMonth + i, width: contentW, height: rowH)
                if i < 5 { Spacer().frame(height: i == 2 ? rowGap + quarterGap : rowGap) }
            }
        }
        .padding(pad)
        .frame(width: PrintYear.pageW, height: PrintYear.pageH, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func monthRow(_ m: Int, width: CGFloat, height: CGFloat) -> some View {
        let dim = daysInMonth(year, m)
        let bandAreaW = width - gutterW
        let dayW = bandAreaW / 31                 // fixed 31-slot scale → day columns align across months
        return HStack(alignment: .top, spacing: 0) {
            // Gutter: month name + the month's track names.
            VStack(alignment: .leading, spacing: 0) {
                Text(MONTH_NAMES[m])
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(theme.text)
                    .frame(height: dayNumH + 2, alignment: .bottomLeading)
                ForEach(0..<4, id: \.self) { t in
                    Text(tracks.indices.contains(m) && tracks[m].indices.contains(t) ? tracks[m][t] : "")
                        .font(.system(size: 6)).foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                        .frame(height: laneH, alignment: .leading)
                }
            }
            .frame(width: gutterW, alignment: .leading)

            // Day grid + lanes + bands.
            ZStack(alignment: .topLeading) {
                // Weekend wash + day-number strip.
                ForEach(1...dim, id: \.self) { d in
                    let wd = dayOfWeek(year, m, d)
                    if wd == 0 || wd == 6 {
                        Rectangle().fill(theme.text.opacity(0.045))
                            .frame(width: dayW, height: dayNumH + 2 + laneH * 4)
                            .offset(x: CGFloat(d - 1) * dayW)
                    }
                    Text("\(d)")
                        .font(.system(size: 5.5)).foregroundStyle(theme.textMuted)
                        .frame(width: dayW, height: dayNumH)
                        .offset(x: CGFloat(d - 1) * dayW)
                }
                // Lane separators + outer border of the month's active day span.
                ForEach(0...4, id: \.self) { t in
                    Rectangle().fill(theme.sep.opacity(t == 0 || t == 4 ? 0.6 : 0.35))
                        .frame(width: dayW * CGFloat(dim), height: 0.5)
                        .offset(y: dayNumH + 2 + laneH * CGFloat(t))
                }
                // Bands: flat light-theme fills (the app's Performance-Mode look; glass doesn't print).
                ForEach(bands.filter { $0.month == m }, id: \.id) { b in
                    let x = CGFloat(b.startDay - 1) * dayW
                    let w = max(dayW, CGFloat(b.endDay - b.startDay + 1) * dayW)
                    let y = dayNumH + 2 + laneH * CGFloat(max(0, min(3, b.track))) + 1.5
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(theme.eventFill(b.color))
                        RoundedRectangle(cornerRadius: 2.5)
                            .strokeBorder(theme.eventBorder(b.color), lineWidth: 0.6)
                        Rectangle().fill(theme.eventBorder(b.color))
                            .frame(width: 1.6).padding(.vertical, 1.5)
                        Text(b.title)
                            .font(.custom("Comic Sans MS", size: 6.5))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                            .padding(.leading, 4)
                    }
                    .frame(width: w, height: laneH - 3)
                    .offset(x: x, y: y)
                }
            }
            .frame(width: bandAreaW, height: height, alignment: .topLeading)
            .clipped()
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}
