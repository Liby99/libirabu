// Help-GIF demo scenes (move-resize … daily-dashboard) + the synthetic-cursor panel window.
// Split from DemoController.swift (audit round, 2026-08-02).

import AppKit
import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

extension DemoController {
    /// ── Help-GIF scenes (docs/help-gif-suggestions.md) ──────────────────────────────────────────
    /// MOVE then RESIZE a timed event in week view: drag its body to a later slot, then drag its bottom
    /// edge to lengthen it — both through the real pointer paths, so previews track live. The target is
    /// aimed by its LIVE on-screen rect (the week's scroll follows the clock, so fixed fractions break).
    func sceneMoveResize() async {
        guard let engine else { return }
        // Full-window recording (no crop).
        engine.demoClearEvents()
        seedWeek()
        let target = engine.demoAddTimed(month: 6, day: 14, startHour: 10.25, endHour: 11.75,
                                         title: "Client call", color: "purple")
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        engine.demoSelect(target)
        engine.demoRevealSelected() // scroll the timeline so the target is comfortably visible
        try? await pause(0.9)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // MOVE: grab the event's centre and drag it ~2 hours later.
        guard let r0 = engine.demoEventRectView(target) else { return }
        let perHour = r0.height / 1.5 // the event spans 1.5h → px per hour
        let grab = CGPoint(x: r0.midX, y: r0.midY)
        cursor = CGPoint(x: grab.x - 60, y: grab.y - 46)
        await move(to: grab, over: 0.7)
        pressed = true
        engine.demoPointerDown(atView: grab)
        await drag(from: grab, to: CGPoint(x: grab.x, y: grab.y + perHour * 2), over: 1.2) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: grab.x, y: grab.y + perHour * 2))
        pressed = false
        try? await pause(1.0)

        // RESIZE: re-read the moved event's rect, grab its bottom edge, pull it an hour longer.
        guard let r1 = engine.demoEventRectView(target) else { return }
        let edge = CGPoint(x: r1.midX, y: r1.maxY - 2)
        await move(to: edge, over: 0.7)
        pressed = true
        engine.demoPointerDown(atView: edge)
        await drag(from: edge, to: CGPoint(x: edge.x, y: edge.y + perHour), over: 1.0) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: edge.x, y: edge.y + perHour))
        pressed = false
        try? await pause(1.4)
    }

    /// EDIT in the drawer: double-click an event → drawer opens (event highlighted) → pick a new color
    /// (cursor over the swatches; the change applies through the engine, so the event recolors live).
    func sceneEditDrawer() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        let id = engine.demoAddTimed(month: 6, day: 16, startHour: 14, endHour: 16,
                                     title: "Paper draft review", color: "purple")
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // Aim by the event's LIVE rect (the week's scroll follows the pinned clock — fixed fractions miss).
        guard let evRect = engine.demoEventRectView(id) else { return }
        let evPt = CGPoint(x: evRect.midX, y: evRect.midY)
        cursor = CGPoint(x: evPt.x - 44, y: evPt.y - 34)
        await move(to: evPt, over: 0.7)
        await doubleClickPulse()
        engine.demoDoubleClick(atView: evPt)
        try? await pause(1.5)

        // Glide across the swatch row with LIVE hover previews, then click ORANGE. Swatch geometry from
        // the drawer's layout: card right margin 10 + width 410 → content left = W−420+18; 17pt circles at
        // 8pt spacing → center x = left + 8.5 + i·25 (EVENT_COLORS order; orange = 7). Row y ≈ 142/840.
        let rowY = size.height * 0.169
        func swatchX(_ i: Int) -> CGFloat {
            size.width - 420 + 18 + 8.5 + CGFloat(i) * 25
        }
        await move(to: CGPoint(x: swatchX(4), y: rowY), over: 0.8)
        engine.setColorPreview(id, "green") // the drawer's real hover preview
        try? await pause(0.55)
        await move(to: CGPoint(x: swatchX(7), y: rowY), over: 0.5)
        engine.setColorPreview(id, "orange")
        try? await pause(0.55)
        pressed = true
        engine.clearColorPreview()
        engine.update(id) { $0.color = "orange" } // commit (what the swatch tap does)
        try? await pause(0.18)
        pressed = false
        try? await pause(2.0)
    }

    /// ADD a DEADLINE via the hover "+": glide along a day column until the quick-add spot appears,
    /// click it (real pointer path → deadline created, drawer opens with the title selected).
    func sceneDeadlineAdd() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        signalReady()
        await waitForGo()
        try? await pause(0.4)

        // The "+" appears only while hovering NEAR A DAY COLUMN'S LEFT EDGE on an hour line — sweep
        // hover probes (invisible) around Thursday ~afternoon until the engine offers the spot, then
        // glide the visible cursor straight onto it and click through the real pointer path.
        let target = CGPoint(x: size.width * 0.665, y: size.height * 0.47)
        cursor = CGPoint(x: target.x - 70, y: target.y - 50)
        await move(to: target, over: 0.8)
        var plus: CGPoint?
        sweep: for dx in stride(from: -34.0, through: 44.0, by: 3.0) {
            for dy in stride(from: -24.0, through: 24.0, by: 6.0) {
                engine.demoHover(atView: CGPoint(x: target.x + dx, y: target.y + dy))
                if let s = engine.demoDeadlineSpotView() {
                    plus = s; break sweep
                }
            }
        }
        guard let plus else { return }
        // Press a few px RIGHT of the spot: the "+" sits exactly on the day's left boundary, and a
        // fraction left of it resolves to the PREVIOUS day (a plain click there navigates instead).
        // Still well inside the click's 12px tolerance.
        let press = CGPoint(x: plus.x + 5, y: plus.y)
        await move(to: press, over: 0.6)
        engine.demoHover(atView: press) // over the "+" → it brightens
        try? await pause(0.6)
        pressed = true
        engine.demoPointerDown(atView: press)
        engine.demoPointerUp(atView: press)
        try? await pause(0.18)
        pressed = false
        try? await pause(1.0)
    }

    /// RECURRING: drag-create a BAND in year view, open its drawer, expand Configuration, and set a
    /// weekly repeat — ghost bars populate across the following weeks/months, which the year view makes
    /// instantly visible (a timed event's ghosts would hide inside single weeks).
    func sceneRecurring() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedYear()
        engine.demoGoToYear(centerMonth: 6) // July centered
        try? await pause(0.5)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // Drag-create a short band on July's Travel lane (same mechanics as the band-year scene).
        let (x0, x1) = (size.width * 0.30, size.width * 0.37)
        let y = size.height * 0.52
        cursor = CGPoint(x: x0 - 40, y: y)
        await move(to: CGPoint(x: x0, y: y), over: 0.6)
        pressed = true
        engine.demoPointerDown(atView: CGPoint(x: x0, y: y))
        await drag(from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), over: 0.9) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: x1, y: y))
        engine.demoRenameSelectedBand("Sprint")
        pressed = false
        try? await pause(0.9)

        // Double-click the band → its drawer opens.
        let mid = CGPoint(x: (x0 + x1) / 2, y: y)
        await doubleClickPulse()
        engine.demoDoubleClick(atView: mid)
        try? await pause(1.4)

        // Expand Configuration, then choose a weekly repeat with an end date — ghost bars appear across
        // the year view's months as the rule lands (driven through the drawer's own state + commit).
        await move(to: CGPoint(x: size.width * 0.79, y: size.height * 0.205), over: 0.8)
        pressed = true; try? await pause(0.15); pressed = false
        configPulse += 1
        try? await pause(1.0)
        await move(to: CGPoint(x: size.width * 0.80, y: size.height * 0.30), over: 0.6)
        pressed = true; try? await pause(0.15); pressed = false
        repeatFeed = Repeat(kind: "weekly")
        try? await pause(1.3)
        await move(to: CGPoint(x: size.width * 0.79, y: size.height * 0.36), over: 0.5)
        pressed = true; try? await pause(0.15); pressed = false
        repeatFeed = Repeat(kind: "weekly", until: String(format: "%04d-09-30", engine.year))
        try? await pause(2.0)
    }

    /// SEARCH: open the toolbar search, type a fuzzy/date query, and fly to the top hit.
    func sceneSearchDemo() async {
        guard let engine, let search = searchState else { return }
        // Full window: toolbar field + dropdown + the fly-to.
        engine.demoClearEvents()
        seedWeek()
        engine.demoGoToYear(centerMonth: 6)
        try? await pause(1.2)
        signalReady()
        await waitForGo()
        try? await pause(0.6)

        // Cursor → the toolbar search button, click, bar expands.
        let btn = CGPoint(x: size.width * 0.885, y: size.height * 0.035)
        cursor = CGPoint(x: btn.x - 60, y: btn.y + 40)
        await move(to: btn, over: 0.7)
        pressed = true; try? await pause(0.15); pressed = false
        openSearchHook?()
        try? await pause(0.7)

        // Type the query (drives the bound SearchState; the async matcher fills the dropdown).
        let query = "coffee wed"
        for i in 1 ... query.count {
            search.query = String(query.prefix(i))
            try? await pause(0.07)
        }
        try? await pause(1.4)
        // Fly to the top hit (what Enter does), then close the bar.
        if let hit = search.results.first {
            engine.revealAndSelect(id: hit.id)
        }
        try? await pause(2.2)
        search.reset()
        try? await pause(0.5)
    }

    /// PROMOTE: right-click an early-morning DEADLINE in week view → "Promote" mirrors it onto the top
    /// track lane (T1) — then drag the ghost bar DOWN two lanes (the lane-only promoted-band drag) to T3.
    func scenePromote() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        let did = engine.createDeadline(year: engine.year, month: 6, day: 16, hour: 7 + 59.0 / 60.0,
                                        title: "Milestone due", color: "red")
        engine.demoSelect(nil)
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        engine.demoScrollTimelineToHour(10) // bring the 7:59 deadline on screen (scroll pins to 16:00)
        try? await pause(0.8)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // Right-click the deadline's moment line → the context callout opens.
        guard let pt = engine.demoDeadlinePointView(did) else { return }
        cursor = CGPoint(x: pt.x - 70, y: pt.y + 55)
        await move(to: pt, over: 0.8)
        pressed = true; try? await pause(0.15); pressed = false
        eventMenuHook?(did, CGRect(x: pt.x, y: pt.y, width: 2, height: 2))
        try? await pause(1.1)

        // Glide down the menu to "Promote" and click it → ghost bar appears on the TOP free lane (T1).
        await move(to: CGPoint(x: pt.x + 180, y: pt.y + 40), over: 0.9) // the callout's Promote row
        pressed = true; try? await pause(0.15); pressed = false
        closeEventMenuHook?()
        engine.togglePromote(did)
        try? await pause(1.5)

        // Drag the ghost DOWN two lanes → T3 (only the lane moves; the date mirrors the deadline).
        guard let ghost = engine.viewBands().first(where: { sourceId(of: $0.id) == did }),
              let r = engine.demoBandRectView(ghost.id) else { return }
        let from = CGPoint(x: r.midX, y: r.midY)
        await move(to: from, over: 0.8)
        pressed = true
        engine.demoPointerDown(atView: from)
        let to = CGPoint(x: from.x, y: from.y + r.height * 2.4)
        await drag(from: from, to: to, over: 1.1) { p in engine.demoPointerDrag(atView: p) }
        engine.demoPointerUp(atView: to)
        pressed = false
        try? await pause(1.4)
    }

    /// PROMOTE (manual): stage the promote scene — seeded week + the 7:59 deadline, morning in view —
    /// then just stay alive: the USER drives the real mouse while the recorder captures.
    func scenePromoteManual() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        _ = engine.createDeadline(year: engine.year, month: 6, day: 16, hour: 7 + 59.0 / 60.0,
                                  title: "Milestone due", color: "red")
        engine.demoSelect(nil)
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut()
        try? await pause(1.6)
        engine.demoScrollTimelineToHour(10)
        try? await pause(0.6)
        signalReady()
        await waitForGo()
        while true {
            engine.wake(); try? await pause(0.5)
        } // recorder kills the app when done
    }

    /// DAILY DASHBOARD: day view's TODO list — varied items (priorities, due dates, tags, people,
    /// links; from the daily note AND an event's notes) — then a click checks one off live.
    func sceneDailyDashboard() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedWeek()
        let gr = engine.demoAddTimed(month: 6, day: 15, startHour: 15, endHour: 16,
                                     title: "Grant review", color: "indigo")
        engine.setNotes(gr, """
        - [ ] Score the proposals p:!! due:2026-07-17
        - [ ] Send summary to the committee @chair
        """)
        let iso = String(format: "%04d-07-15", engine.year)
        let note = """
        ## Today
        - [ ] Review the draft due:today p:!!!
        - [ ] Email Alex about the demo @alex
        - [ ] Book flights for the conference #travel due:2026-07-22
        - [ ] Read [the segmentation paper](https://arxiv.org) #reading
        - [x] Post the standup notes
        """
        engine.setDailyNote(iso, note)
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.6)
        signalReady()
        await waitForGo()
        try? await pause(1.0)

        // Cursor onto the FIRST row's checkbox, then the webview's real toggle path — focus the row and
        // activate it, so the genuine check animation + strike-through plays and the note persists.
        _ = iso
        let row = CGPoint(x: size.width * 0.452, y: size.height * 0.414 - 35)
        cursor = CGPoint(x: row.x - 70, y: row.y + 60)
        await move(to: row, over: 0.9)
        dashTodoFocusHook?()
        try? await pause(0.6)
        pressed = true; try? await pause(0.16); pressed = false
        dashTodoToggleHook?()
        try? await pause(2.2)
    }

    /// Float the synthetic cursor in a borderless, click-through panel window pinned over the main
    /// window's content area — above EVERY window layer, including NSPopover callouts (which sit over the
    /// whole SwiftUI hierarchy and would otherwise cover an in-tree cursor overlay).
    func installCursorPanel() {
        guard cursorPanel == nil, let win = NSApp.mainWindow, let content = win.contentView else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.contentView = NSHostingView(rootView: DemoCursorOverlay(demo: self))
        panel.setFrame(win.convertToScreen(content.convert(content.bounds, to: nil)), display: true)
        win.addChildWindow(panel, ordered: .above)
        cursorPanel = panel
        cursorPanelUp = true
    }
}
