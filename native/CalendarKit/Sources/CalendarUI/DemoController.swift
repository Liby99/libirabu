// Automated tutorial-GIF recording. When the app is launched with env CC_DEMO=<scene>, this drives a
// deterministic, scripted "scene" — a synthetic cursor + engine actions over a fixed timeline — while an
// external script (scripts/record-tutorial.sh) screen-records a fixed window rect and ffmpeg-crops it to a
// GIF. The engine runs against a throwaway store with Apple import off (see ItemStore / isDemoMode), so a
// recording never touches personal data.
//
// Scenes drive the app through its OWN public APIs (jumpToDay, demoAddTimed, cmdZoom*) rather than OS-level
// event injection — deterministic, no Accessibility permission, and it sidesteps the un-synthesizable pinch
// gesture (zoom is driven directly). The cursor is a drawn sprite, not the OS pointer.

import AppKit
import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

@MainActor @Observable
public final class DemoController {
    public var cursor: CGPoint? // calendar-view-local point of the synthetic cursor (nil = hidden)
    public var pressed = false // mouse-down visual (a small ring around the cursor)
    public var pinchDots: (CGPoint, CGPoint)? // two fingertips for the pinch-zoom gesture (nil = hidden)
    public private(set) var active = false

    // ai-assistant scene: an in-window demo panel showing a staged (offline) conversation. The real
    // assistant is a separate window/popover the recorder can't frame; this reuses ConversationView in a
    // panel overlaid on the main window so the whole exchange sits inside the recorded rect.
    public var showAssistantPanel = false
    public var assistant: AssistantState?

    // markdown-notes scene: text streamed into the open drawer's editor (typed live) + the edit/preview cue.
    public var noteFeed = ""
    public var notePreview = false

    // recurring scene: expand the drawer's Configuration section + apply a repeat rule through the drawer.
    public var configPulse = 0
    public var repeatFeed: Repeat?

    // promote scene hooks (wired by CalendarView): open/close the right-click event callout.
    @ObservationIgnored var eventMenuHook: ((String, CGRect) -> Void)?
    @ObservationIgnored var closeEventMenuHook: (() -> Void)?

    // daily-dashboard scene hooks (wired by CalendarView): drive the dashboard webview's REAL todo
    // toggle — keyboard-focus the first row, then activate it (check animation + strike-through + persist).
    @ObservationIgnored var dashTodoFocusHook: (() -> Void)?
    @ObservationIgnored var dashTodoToggleHook: (() -> Void)?
    // The dashboard webview conduit (wired by CalendarView): bench scenes record the PAGE's own
    // rAF frame cadence through it — the web content process janks invisibly to benchTick.
    @ObservationIgnored var dashWebCarousel: DashboardCarousel?

    // search-demo scene hooks (wired by CalendarView.setupOnAppear): open the toolbar search bar, and the
    // live SearchState the field binds to — the scene types into it and reads the results.
    @ObservationIgnored var openSearchHook: (() -> Void)?
    @ObservationIgnored var searchState: SearchState?

    // The synthetic cursor is hosted in its own transparent, click-through PANEL WINDOW above the app:
    // the right-click callout is an NSPopover (an AppKit child window over the whole SwiftUI tree), so an
    // in-tree overlay would draw UNDER it. True → CalendarView skips its in-tree cursor overlay.
    @ObservationIgnored public private(set) var cursorPanelUp = false
    @ObservationIgnored private var cursorPanel: NSPanel?

    private weak var engine: CalendarEngine?
    private var size: CGSize = .zero
    private var goTime: Date? // set when recording starts (go.txt) → measures on-camera duration

    // bench-year-scroll: per-frame timestamps recorded while the scripted scroll runs (see benchTick).
    // @ObservationIgnored: these mutate EVERY FRAME from the render closure — they must not churn the
    // observation machinery or invalidate any view.
    @ObservationIgnored private var benchActive = false
    @ObservationIgnored private var benchMoves: [(Double, Double)] = [] // moving-phase windows (start, end)
    @ObservationIgnored private var moveStart: Double = 0
    @ObservationIgnored private var benchFrames: [Double] = []

    public init() {}

    /// Kick off the scene named by CC_DEMO once the view has a real size. Safe to call repeatedly.
    public func startIfDemo(engine: CalendarEngine, size: CGSize) {
        guard CalendarEngine.isDemoMode, !active, size.width > 100 else { return }
        active = true
        self.engine = engine
        self.size = size
        // The manual-benchmark scene ("idle") drives NOTHING — the human scrolls the real pointer — so it
        // must NOT install the synthetic click-through cursor panel that scripted scenes use.
        if !Self.isIdleScene { installCursorPanel() }
        Task { await run(CalendarEngine.demoScene) }
    }

    /// CC_DEMO=idle (or bench-idle): the manual-benchmark mode. isDemoMode is TRUE, so every background
    /// source (iCloud sync, ICS feeds, Apple-Calendar import, notifications, the now-timer) is off and the
    /// store is the throwaway CC_DEMO_DATADIR — identical to the CalendarMac bench — but no scene scripts
    /// input. Point CC_DEMO_DATADIR at a dir holding a data.json copy of bench/year-display-2026.json and
    /// turn on CC_FPS_HUD=1 to A/B the Xcode CalendarApp against the CalendarMac harness by hand.
    static var isIdleScene: Bool { CalendarEngine.demoScene == "idle" || CalendarEngine.demoScene == "bench-idle" }

    private func run(_ scene: String) async {
        switch scene {
        case "idle", "bench-idle": return // manual benchmark: load fixture, everything off, human drives
        case "timed-week": await sceneTimedWeek()
        case "band-year": await sceneBandYear()
        case "pinch-zoom": await scenePinchZoom()
        case "markdown-notes": await sceneMarkdownNotes()
        case "ai-assistant": await sceneAIAssistant()
        case "move-resize": await sceneMoveResize()
        case "edit-drawer": await sceneEditDrawer()
        case "deadline-add": await sceneDeadlineAdd()
        case "recurring": await sceneRecurring()
        case "search-demo": await sceneSearchDemo()
        case "promote": await scenePromote()
        case "promote-manual": await scenePromoteManual()
        case "daily-dashboard": await sceneDailyDashboard()
        case "bench-year-scroll": await sceneBenchYearScroll()
        case "bench-year-fling": await sceneBenchYearFling()
        case "bench-month-swipe": await sceneBenchMonthSwipe()
        case "bench-week-swipe": await sceneBenchWeekSwipe()
        case "bench-dash-toggle": await sceneBenchDashToggle()
        case "bench-dash-edit": await sceneBenchDashEdit()
        case "bench-dash-zoomin": await sceneBenchDashZoomIn()
        case "bench-pinch-zoom": await sceneBenchPinchZoom()
        case "bench-notify-plan": await sceneBenchNotifyPlan()
        default:
            NSLog("DemoController: UNKNOWN scene '%@' — falling back to timed-week (check the CC_DEMO value)", scene)
            await sceneTimedWeek()
        }
        // Signal the scene's exact end so the recorder can trim the GIF to length (screencapture -V can't be
        // stopped early, so it over-records and we cut back to here). Then idle on the final frame.
        signalDone()
    }

    /// ── Scenes ───────────────────────────────────────────────────────────────────────────────
    /// Timed event in WEEK view: a vertical drag on a day column's timeline creates it (live grow-preview).
    private func sceneTimedWeek() async {
        guard let engine else { return }
        writeCrop(x: 0.09, y: 0.24, w: 0.56, h: 0.42) // hour labels + a few columns around the event
        // OFF-CAMERA setup: seed, then land on the WEEK view (the jump-in + zoom-out animations happen before
        // recording starts, so the GIF is just the drag-create).
        engine.demoClearEvents()
        seedWeek()
        engine.jumpToDay(engine.year, 6, 15) // into the day…
        try? await pause(2.2)
        engine.cmdZoomOut() // …out one level to the WEEK
        try? await pause(1.6)
        signalReady()
        await waitForGo()
        try? await pause(0.3)

        // ON CAMERA: drag down a day column (Mon, ~centered in the crop). x lands inside a column; y0 an
        // empty morning slot.
        let x = size.width * 0.34
        let (y0, y1) = (size.height * 0.40, size.height * 0.60)
        cursor = CGPoint(x: x, y: y0 - 46)
        await move(to: CGPoint(x: x, y: y0), over: 0.55)
        pressed = true
        engine.demoPointerDown(atView: CGPoint(x: x, y: y0))
        await drag(from: CGPoint(x: x, y: y0), to: CGPoint(x: x, y: y1), over: 1.2) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: x, y: y1))
        engine.demoRenameSelected("Coffee with Sam")
        pressed = false
        try? await pause(1.3)
    }

    /// Multi-day BAND in YEAR view: a horizontal drag across days on a month's lane creates it.
    private func sceneBandYear() async {
        guard let engine else { return }
        writeCrop(x: 0.0, y: 0.28, w: 1.0, h: 0.36) // the centered month's row (full day span)
        // OFF-CAMERA setup: seed + land on the year view with July centered, then hold ready.
        engine.demoClearEvents()
        seedYear() // ambient bands across months/lanes so the year isn't empty
        engine.demoGoToYear(centerMonth: 6) // July centered
        try? await pause(0.4)
        signalReady()
        await waitForGo()
        try? await pause(0.4)

        // ON CAMERA: drag horizontally across ~a week on a lane row of the centered month.
        let (x0, x1) = (size.width * 0.30, size.width * 0.46)
        let y = size.height * 0.52
        cursor = CGPoint(x: x0 - 40, y: y)
        await move(to: CGPoint(x: x0, y: y), over: 0.6)
        pressed = true
        engine.demoPointerDown(atView: CGPoint(x: x0, y: y))
        await drag(from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), over: 1.2) { p in
            engine.demoPointerDrag(atView: p)
        }
        engine.demoPointerUp(atView: CGPoint(x: x1, y: y))
        engine.demoRenameSelectedBand("Conference")
        pressed = false
        try? await pause(1.9)
    }

    /// ── Ambient (decoy) data so the recordings don't look empty ────────────────────────────────
    /// Generic timed events across the visible week (Sun 12 – Sat 18 July). Mon (13) is left clear over
    /// ~10:30–13:45 so the drag has an empty slot to create in.
    private func seedWeek(wedCoffee: Bool = true) {
        guard let e = engine else { return }
        let m = 6
        e.demoAddTimed(month: m, day: 13, startHour: 8, endHour: 9, title: "Standup", color: "blue")
        e.demoAddTimed(month: m, day: 13, startHour: 16.5, endHour: 17.5, title: "Gym", color: "green")
        e.demoAddTimed(month: m, day: 12, startHour: 11, endHour: 12, title: "Brunch", color: "orange")
        e.demoAddTimed(month: m, day: 14, startHour: 9, endHour: 10, title: "1:1 with Alex", color: "purple")
        e.demoAddTimed(month: m, day: 14, startHour: 12.5, endHour: 14, title: "Design review", color: "cyan")
        e.demoAddTimed(month: m, day: 15, startHour: 10, endHour: 11, title: "Sprint planning", color: "blue")
        if wedCoffee { // the ai-assistant scene omits this so its created "Coffee chat with Sam" is unique
            e.demoAddTimed(month: m, day: 15, startHour: 13.5, endHour: 14.5, title: "Coffee chat", color: "yellow")
        }
        e.demoAddTimed(month: m, day: 16, startHour: 9, endHour: 9.5, title: "Standup", color: "blue")
        e.demoAddTimed(month: m, day: 16, startHour: 12, endHour: 13, title: "Lunch", color: "orange")
        e.demoAddTimed(month: m, day: 17, startHour: 10.5, endHour: 11.5, title: "Interview", color: "red")
        e.demoAddTimed(month: m, day: 17, startHour: 15, endHour: 16, title: "Retro", color: "green")
        e.demoAddTimed(month: m, day: 18, startHour: 11, endHour: 12, title: "Yoga", color: "purple")
    }

    /// Generic all-day bands across several months + lanes. July's Travel lane (track 3) is left clear over
    /// days ~5–17 so the horizontal drag creates its band there.
    private func seedYear() {
        guard let e = engine else { return }
        e.demoAddBand(month: 6, track: 0, startDay: 3, endDay: 8, title: "Course prep", color: "blue")
        e.demoAddBand(month: 6, track: 1, startDay: 10, endDay: 15, title: "Paper draft", color: "purple")
        e.demoAddBand(month: 6, track: 2, startDay: 19, endDay: 24, title: "Committee", color: "green")
        e.demoAddBand(month: 6, track: 3, startDay: 23, endDay: 28, title: "Retreat", color: "orange")
        e.demoAddBand(month: 5, track: 0, startDay: 12, endDay: 18, title: "Workshop", color: "cyan")
        e.demoAddBand(month: 5, track: 2, startDay: 22, endDay: 27, title: "Review", color: "red")
        e.demoAddBand(month: 7, track: 1, startDay: 5, endDay: 11, title: "Summit", color: "indigo")
        e.demoAddBand(month: 7, track: 3, startDay: 14, endDay: 20, title: "Vacation", color: "green")
        e.demoAddBand(month: 4, track: 1, startDay: 8, endDay: 14, title: "Sprint", color: "yellow")
        e.demoAddBand(month: 8, track: 0, startDay: 3, endDay: 9, title: "Onboarding", color: "blue")
    }

    /// Interpolated drag in any direction: moves the synthetic cursor AND feeds each point to `step` (the
    /// engine's real drag handler), so the created event/band tracks the cursor precisely.
    private func drag(from a: CGPoint, to b: CGPoint, over duration: Double, steps: Int = 34,
                      step: (CGPoint) -> Void) async {
        for i in 1 ... steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let p = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            cursor = p; step(p)
            try? await pause(duration / Double(steps))
        }
    }

    private func scenePinchZoom() async {
        guard let engine else { return }
        // No crop: the pinch spans the whole view (year → month → week → day), so record the full window.
        try? await pause(0.5)
        engine.demoClearEvents()
        seedYear() // bands so the year/month levels have content…
        seedWeek() // …and timed events so the week/day levels do too
        engine.demoGoToYear(centerMonth: 6)
        // A distinct, mid-cell pinch location per zoom level (never on a day boundary), so the three zooms
        // don't look static and each clearly targets one month/week/day.
        let centers = [
            CGPoint(x: size.width * 0.46, y: size.height * 0.48), // year → month  (over July's row)
            CGPoint(x: size.width * 0.52, y: size.height * 0.45), // month → week
            CGPoint(x: size.width * 0.58, y: size.height * 0.52), // week → day
        ]

        // Set up off-camera, then wait for the recorder's "go" so the GIF opens exactly on the year view
        // (see record-tutorial.sh), then hold a generous pre-roll on the year view before the first pinch.
        signalReady()
        await waitForGo()
        try? await pause(2.0)

        // Zoom IN through every level (year → month → week → day), then a single zoom-OUT back to the week
        // to show the pinch works both ways — without the full return trip (keeps the GIF short).
        for i in 0 ..< 3 {
            await pinch(around: centers[i], over: 0.55, spreadOut: true); try? await pause(0.9)
        }
        try? await pause(0.7)
        await pinch(around: centers[2], over: 0.55, spreadOut: false) // day → week
        try? await pause(0.9)
        pinchDots = nil
        try? await pause(0.6)
    }

    /// Markdown NOTES in an event: double-click a right-side event → its drawer opens (event highlighted),
    /// then type a markdown TODO checklist into the notes editor and hit Preview to render it.
    private func sceneMarkdownNotes() async {
        guard let engine else { return }
        writeCrop(x: 0.30, y: 0.0, w: 0.70, h: 1.0) // the selected event (recentred) + the drawer
        // OFF-CAMERA: seed the week, add the focus event with EMPTY notes (so its drawer opens in edit mode),
        // land on the week. Thursday (16) sits in the right half → within the crop, a clean double-click target.
        engine.demoClearEvents()
        seedWeek()
        let id = engine.demoAddTimed(month: 6, day: 16, startHour: 14, endHour: 16,
                                     title: "Paper draft review", color: "purple")
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut() // → week view
        try? await pause(1.6)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // ON CAMERA — double-click the event on Thursday (right half of the week; 14:00–16:00, well below
        // the day's other seeds so the double-click lands on it cleanly).
        // Aim by the event's LIVE rect (the week's scroll follows the pinned clock — fixed fractions miss).
        guard let evRect = engine.demoEventRectView(id) else { return }
        let evPt = CGPoint(x: evRect.midX, y: evRect.midY)
        cursor = CGPoint(x: evPt.x - 44, y: evPt.y - 34)
        await move(to: evPt, over: 0.7)
        await doubleClickPulse() // two press rings
        engine.demoDoubleClick(atView: evPt) // select + open drawer (event highlights, slides beside drawer)
        try? await pause(1.3)

        // Click into the notes editor, then type the checklist live.
        let editorPt = CGPoint(x: size.width * 0.86, y: size.height * 0.52)
        await move(to: editorPt, over: 0.7)
        pressed = true; try? await pause(0.16); pressed = false
        try? await pause(0.4)
        await typeNote("""
        ## Prep checklist
        - [ ] Run final experiments  due:2026-07-20 p:!!!
        - [ ] Polish figures  #paper
        - [ ] Email co-authors  @alex
        """)
        try? await pause(0.7)

        // Click the Preview toggle (the eye, bottom-left of the drawer footer) → the markdown renders. Kept
        // above the window's visible bottom (the SwiftUI space overflows the window; see the crop clamp).
        let previewBtn = CGPoint(x: size.width * 0.74, y: size.height * 0.855)
        await move(to: previewBtn, over: 0.8)
        pressed = true; notePreview = true; try? await pause(0.16); pressed = false
        try? await pause(2.6)
    }

    /// Reveal `text` in the drawer's editor progressively, as if typed (a few chars per tick).
    private func typeNote(_ text: String) async {
        noteFeed = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let step = min(2, chars.count - i) // 2 chars/tick → brisk but legibly "typing"
            i += step
            noteFeed = String(chars[0 ..< i])
            try? await pause(0.05)
        }
    }

    /// Two quick press rings — the double-click affordance.
    private func doubleClickPulse() async {
        for _ in 0 ..< 2 {
            pressed = true; try? await pause(0.11)
            pressed = false; try? await pause(0.10)
        }
    }

    /// AI ASSISTANT: click the toolbar AI button, then a staged (offline) conversation plays out in an
    /// in-window panel — the user asks, a tool-activity chip appears, the assistant replies — while the
    /// requested event is really added to the calendar behind it.
    private func sceneAIAssistant() async {
        guard let engine else { return }
        // Record the RIGHT HALF: the chat panel plus the strip of calendar beside it (where the created
        // event lands). The real AI button is a native toolbar item we can't overlay a synthetic cursor onto
        // cleanly, so this scene doesn't fake the click — the panel simply opens.
        writeCrop(x: 0.50, y: 0.0, w: 0.50, h: 1.0)
        engine.demoClearEvents()
        seedWeek(wedCoffee: false) // omit the seed "Coffee chat" on Wed → no name clash
        engine.jumpToDay(engine.year, 6, 15)
        try? await pause(2.2)
        engine.cmdZoomOut() // week view
        try? await pause(1.6)

        // Build the offline assistant session (no network — turns are staged directly).
        let a = AssistantState(store: ConversationStore())
        a.engine = engine
        assistant = a
        signalReady()
        await waitForGo()
        try? await pause(0.8)

        // The panel opens (no faked toolbar click — the real AI button is a native toolbar item).
        withAnimationPanel { showAssistantPanel = true }
        try? await pause(0.7)

        // Cursor into the composer, then TYPE the message live (drives state.draft → the real editor).
        let composerPt = CGPoint(x: size.width * 0.82, y: size.height * 0.62)
        cursor = CGPoint(x: composerPt.x - 40, y: composerPt.y + 44)
        await move(to: composerPt, over: 0.7)
        pressed = true; try? await pause(0.14); pressed = false
        try? await pause(0.3)
        let prompt = "Coffee chat with Sam, Wed at 3pm" // fits the composer on one line (no clip/wrap)
        await typeDraft(a, prompt)
        try? await pause(0.4)

        // Move to the send button (bottom-right of the pill) and click it.
        let sendBtn = CGPoint(x: size.width * 0.965, y: size.height * 0.62)
        await move(to: sendBtn, over: 0.6)
        pressed = true; try? await pause(0.18); pressed = false

        // Send (no network): the draft becomes a user bubble, then the assistant "works" — a typing dot, a
        // tool-activity chip for the create, another typing dot, then the reply.
        a.draft = ""
        a.messages.append(ChatTurn(role: .user, text: prompt))
        try? await pause(0.9)
        a.messages.append(ChatTurn(role: .typing, text: ""))
        try? await pause(1.4)
        // Really add the event on Wednesday (visible beside the panel) and select it so it appears
        // highlighted, as a real create would.
        let id = engine.demoAddTimed(month: 6, day: 15, startHour: 15, endHour: 16,
                                     title: "Coffee chat with Sam", color: "blue")
        engine.demoSelect(id)
        a.messages.removeAll { $0.role == .typing }
        a.messages.append(ChatTurn(role: .action, text: "Created “Coffee chat with Sam”", icon: "calendar.badge.plus"))
        try? await pause(1.0)
        a.messages.append(ChatTurn(role: .typing, text: ""))
        try? await pause(1.2)
        a.messages.removeAll { $0.role == .typing }
        a.messages.append(ChatTurn(role: .assistant,
                                   text: "Done — added **Coffee chat with Sam** on Wednesday, July 15 from 3:00–4:00 PM."))
        try? await pause(0.5) // hold on the rendered reply, then end (recorder trims to here)
    }

    /// Reveal `text` in the assistant composer progressively, as if typed (drives state.draft, which the
    /// editor reflects live).
    private func typeDraft(_ a: AssistantState, _ text: String) async {
        a.draft = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let step = min(2, chars.count - i)
            i += step
            a.draft = String(chars[0 ..< i])
            try? await pause(0.045)
        }
    }

    /// A tiny wrapper so the panel's appearance animates (SwiftUI `withAnimation` needs a synchronous body).
    private func withAnimationPanel(_ body: () -> Void) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { body() }
    }

    /// Animate two fingertips spreading apart (`spreadOut`, zoom IN) or together (zoom OUT), driving the real
    /// pinch path (`demoMagnify`) anchored on the centre `c` so the zoom target matches the drawn gesture.
    /// Hides the arrow cursor for the duration so only the two dots + centre marker show.
    private func pinch(around c: CGPoint, over duration: Double, spreadOut: Bool, steps: Int = 24) async {
        guard let engine else { return }
        cursor = nil
        let near: CGFloat = 20, far: CGFloat = 130
        // Total magnification to cross exactly one level: PINCH_SENS=1.6, so ~0.7·1.6≈1.1 Δz — past the .5
        // snap boundary, short of a double jump. `ended` then settles onto the rounded level.
        let totalMag: CGFloat = spreadOut ? 0.70 : -0.70
        func ease(_ x: Double) -> Double {
            x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        }
        var prevE = 0.0
        for i in 0 ... steps {
            let e = ease(Double(i) / Double(steps))
            let r = spreadOut ? near + (far - near) * CGFloat(e) : far - (far - near) * CGFloat(e)
            pinchDots = (CGPoint(x: c.x - r, y: c.y + r * 0.32),
                         CGPoint(x: c.x + r, y: c.y - r * 0.32))
            if i == 0 {
                engine.demoMagnify(delta: 0, atView: c, began: true, ended: false)
            } else if i == steps {
                engine.demoMagnify(delta: 0, atView: c, began: false, ended: true)
            } else {
                engine.demoMagnify(delta: totalMag * CGFloat(e - prevE), atView: c, began: false, ended: false)
            }
            prevE = e
            try? await pause(duration / Double(steps))
        }
    }

    // ── Help-GIF scenes (docs/help-gif-suggestions.md) ──────────────────────────────────────────
    /// MOVE then RESIZE a timed event in week view: drag its body to a later slot, then drag its bottom
    /// edge to lengthen it — both through the real pointer paths, so previews track live. The target is
    /// aimed by its LIVE on-screen rect (the week's scroll follows the clock, so fixed fractions break).
    private func sceneMoveResize() async {
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
        engine.demoRevealSelected()            // scroll the timeline so the target is comfortably visible
        try? await pause(0.9)
        signalReady()
        await waitForGo()
        try? await pause(0.5)

        // MOVE: grab the event's centre and drag it ~2 hours later.
        guard let r0 = engine.demoEventRectView(target) else { return }
        let perHour = r0.height / 1.5                       // the event spans 1.5h → px per hour
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
    private func sceneEditDrawer() async {
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
        func swatchX(_ i: Int) -> CGFloat { size.width - 420 + 18 + 8.5 + CGFloat(i) * 25 }
        await move(to: CGPoint(x: swatchX(4), y: rowY), over: 0.8)
        engine.setColorPreview(id, "green")           // the drawer's real hover preview
        try? await pause(0.55)
        await move(to: CGPoint(x: swatchX(7), y: rowY), over: 0.5)
        engine.setColorPreview(id, "orange")
        try? await pause(0.55)
        pressed = true
        engine.clearColorPreview()
        engine.update(id) { $0.color = "orange" }     // commit (what the swatch tap does)
        try? await pause(0.18)
        pressed = false
        try? await pause(2.0)
    }

    /// ADD a DEADLINE via the hover "+": glide along a day column until the quick-add spot appears,
    /// click it (real pointer path → deadline created, drawer opens with the title selected).
    private func sceneDeadlineAdd() async {
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
                if let s = engine.demoDeadlineSpotView() { plus = s; break sweep }
            }
        }
        guard let plus else { return }
        // Press a few px RIGHT of the spot: the "+" sits exactly on the day's left boundary, and a
        // fraction left of it resolves to the PREVIOUS day (a plain click there navigates instead).
        // Still well inside the click's 12px tolerance.
        let press = CGPoint(x: plus.x + 5, y: plus.y)
        await move(to: press, over: 0.6)
        engine.demoHover(atView: press)    // over the "+" → it brightens
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
    private func sceneRecurring() async {
        guard let engine else { return }
        engine.demoClearEvents()
        seedYear()
        engine.demoGoToYear(centerMonth: 6)   // July centered
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
    private func sceneSearchDemo() async {
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
        for i in 1...query.count {
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
    private func scenePromote() async {
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
        engine.demoScrollTimelineToHour(10)   // bring the 7:59 deadline on screen (scroll pins to 16:00)
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
        await move(to: CGPoint(x: pt.x + 180, y: pt.y + 40), over: 0.9)   // the callout's Promote row
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
    private func scenePromoteManual() async {
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
        while true { engine.wake(); try? await pause(0.5) }   // recorder kills the app when done
    }

    /// DAILY DASHBOARD: day view's TODO list — varied items (priorities, due dates, tags, people,
    /// links; from the daily note AND an event's notes) — then a click checks one off live.
    private func sceneDailyDashboard() async {
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
    private func installCursorPanel() {
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

    /// ── Benchmarks (CC_DEMO=bench-*: measure, don't record) ───────────────────────────────────
    /// Live FPS HUD toggle (works in ANY run: Xcode-attached, standalone, the signed app). Enable with the
    /// env var CC_FPS_HUD=1 (add it to the Xcode scheme) or `defaults write … cc.fpsHUD -bool YES`.
    private static let envHUD = ProcessInfo.processInfo.environment["CC_FPS_HUD"] != nil
    public static var hudEnabled: Bool { envHUD || UserDefaults.standard.bool(forKey: "cc.fpsHUD") }
    @ObservationIgnored private var hudRing: [Double] = [] // recent frame timestamps (HUD window)

    /// Per-frame hook from the render TimelineView (one evaluation = one rendered frame). A cheap no-op
    /// unless a bench scene is recording or the HUD is on; same-date re-evaluations dedupe.
    public func benchTick(_ date: Date) {
        guard benchActive || Self.hudEnabled else { return }
        let t = date.timeIntervalSinceReferenceDate
        if benchActive, benchFrames.last != t {
            benchFrames.append(t)
        }
        if Self.hudEnabled, hudRing.last != t {
            hudRing.append(t)
            if hudRing.count > 480 {
                hudRing.removeFirst(hudRing.count - 480)
            }
        }
    }

    /// Stats over the last second of rendered frames (nil while idle/paused — no frames to judge).
    public func hudStats() -> (fps: Double, p95ms: Double, maxms: Double)? {
        let now = Date().timeIntervalSinceReferenceDate
        let recent = hudRing.filter { $0 > now - 1.0 }
        guard recent.count >= 5 else { return nil }
        let deltas = zip(recent.dropFirst(), recent).map { $0 - $1 }.filter { $0 > 0 }
        guard !deltas.isEmpty else { return nil }
        let sorted = deltas.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return (Double(deltas.count) / (recent.last! - recent.first!), p95 * 1000, sorted.last! * 1000)
    }

    /// YEAR-view scroll benchmark. The payload (bench/year-bands-2026.json — a real year of bands) is
    /// pre-copied into the throwaway store as data.json, so the engine loads it like user data. Glide
    /// Jan→Dec→Jan with the pace-locked keyboard-scroll tween while recording per-frame timestamps, then
    /// write fps/frame-time stats to $CC_DEMO_DATADIR/bench.json for the script to print.
    private func sceneBenchYearScroll() async {
        guard let engine else { return }
        try? await pause(1.2) // launch settle: store load + first layout
        engine.demoGoToYear(centerMonth: 0) // January at the top
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        // CC_BENCH_HOVER=1 → wiggle a synthetic pointer over the content during the glide, exercising the
        // real per-move hover/hit-test path a trackpad scroll pays (mouseMoved → onHover → bandAt).
        let hover = ProcessInfo.processInfo.environment["CC_BENCH_HOVER"] != nil
        var hoverStep = 0
        for target in [11, 0] { // Jan → Dec, then back to Jan
            engine.demoScrollYearToMonth(target)
            while !engine.demoYearScrollSettled { // keep the render loop awake through the glide
                engine.wake()
                if hover {
                    hoverStep += 1 // drift horizontally over the band lanes
                    let x = size.width * (0.25 + 0.5 * abs(sin(Double(hoverStep) * 0.11)))
                    engine.demoHover(atView: CGPoint(x: x, y: size.height * 0.5))
                }
                try? await pause(0.016) // ~per-frame, like a trackpad's move events
            }
            try? await pause(0.25)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Fling-speed year scroll through the REAL scroll-mirror path (`setYearScroll`, the same
    /// call the NSScrollView driver makes per event) — much faster than the pace-locked glide:
    /// the full year sweeps in ~1s each way, with a per-frame hover like a real trackpad.
    private func sceneBenchYearFling() async {
        guard let engine else { return }
        try? await pause(1.2)
        engine.demoGoToYear(centerMonth: 0)
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        let maxY = yearMaxScroll(engine.viewport)
        var hoverStep = 0
        // Sweep speed is tunable: CC_BENCH_FLING_STEPS=N sets the frames-per-sweep (default 120 ≈ a ~1s
        // heavy fling). FEWER steps ⇒ a bigger scroll jump per frame ⇒ a FASTER scroll (e.g. 30 sweeps the
        // whole year in ~0.25s — a violent flick that stresses per-frame scene rebuild the hardest). Passes
        // through the SAME setYearScroll mirror a real trackpad drives, so it stays representative.
        let steps = max(2, ProcessInfo.processInfo.environment["CC_BENCH_FLING_STEPS"].flatMap { Int($0) } ?? 120)
        for (from, to) in [(CGFloat(0), maxY), (maxY, CGFloat(0))] { // fast down, fast up
            engine.beginYearScrollGesture()
            for i in 0 ... steps {
                let t = CGFloat(i) / CGFloat(steps)
                engine.setYearScroll(from + (to - from) * t)
                hoverStep += 1
                let x = size.width * (0.25 + 0.5 * abs(sin(Double(hoverStep) * 0.11)))
                engine.demoHover(atView: CGPoint(x: x, y: size.height * 0.5))
                engine.wake()
                try? await pause(0.008)
            }
            engine.endYearScrollGesture()
            try? await pause(0.25)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Month-view page turns across the DENSE months (Jun→Sep and back): drives the pager mirror
    /// (`setMonthProgress`) through full page-turn ramps, so `monthAnim` is live — the path that
    /// renders BOTH months' grids + event overlays every frame. This is the "swipe between
    /// monthly views" cost the year-scroll scenes never measure.
    private func sceneBenchMonthSwipe() async {
        guard let engine else { return }
        try? await pause(1.2)
        engine.setView(zoom: "month", focusedMonth: 5) // June
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        let pageH = size.height
        let dwell = ProcessInfo.processInfo.environment["CC_BENCH_DWELL"] != nil
        let env = ProcessInfo.processInfo.environment
        // Swipe SPEED: CC_BENCH_SWIPE_STEPS=N frames per page-turn (default 40 ≈ a relaxed swipe). FEWER
        // steps ⇒ a bigger progress jump per frame ⇒ a FASTER flick — set 8–12 for the "very very rapid"
        // back-and-forth a real trackpad does. CC_BENCH_SWIPE_GAP=secs is the settle between turns (default
        // 0.15; drop to ~0.02 so turns land in rapid succession and the 1-second HUD window stays inside the
        // churn — that's when the neighbor-month pre-mount hitches stack up and the visible fps sags).
        let steps = max(2, Int(env["CC_BENCH_SWIPE_STEPS"].flatMap { Int($0) } ?? 40))
        let gap = Double(env["CC_BENCH_SWIPE_GAP"].flatMap { Double($0) } ?? 0.15)
        // CC_BENCH_MONTHS="5,6,7" → walk Jun→Jul→Aug and back, adjacent turns only, ×3 (a two- or
        // N-month list both work). Default: the Jun→Sep tour with revisits.
        var pairs: [(Int, Int)] = [(5, 6), (6, 7), (7, 8), (8, 7), (7, 6), (6, 7), (7, 8), (8, 7), (7, 6)]
        if let spec = env["CC_BENCH_MONTHS"] {
            let mm = spec.split(separator: ",").compactMap { Int($0) }
            if mm.count >= 2 {
                // adjacent transitions forward then backward (5→6→7→6→5), repeated for a sustained run
                let fwd = zip(mm, mm.dropFirst()).map { ($0, $1) }
                let leg = fwd + fwd.reversed().map { ($0.1, $0.0) }
                pairs = leg + leg + leg
            }
        }
        for (from, to) in pairs {
            engine.beginMonthGesture()
            if dwell { // A/B: let the neighbor pre-mount land on STATIC frames before moving
                for _ in 0 ..< 30 { engine.wake(); try? await pause(0.016) }
            }
            moveStart = Date.timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = easeOutQuad(CGFloat(i) / CGFloat(steps))
                let y = (CGFloat(from) + (CGFloat(to - from)) * t) * pageH
                engine.setMonthProgress(y, pageH: pageH)
                engine.wake()
                try? await pause(0.008)
            }
            benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
            engine.endMonthGesture()
            try? await pause(gap)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    private func easeOutQuad(_ t: CGFloat) -> CGFloat { 1 - (1 - t) * (1 - t) }

    /// Week-view page turns inside ONE month: drives the week pager mirror (`setWeekProgress`, the
    /// same call the WeekPager's scroll observation makes) through full swipe ramps, so the 7-day
    /// window slides between adjacent weeks with events/deadline pills/dashboard live — the "swipe
    /// between weekly views" cost none of the month/year scenes measure. Speed reuses the month
    /// scene's knobs (CC_BENCH_SWIPE_STEPS frames per turn, CC_BENCH_SWIPE_GAP settle secs).
    /// CC_BENCH_WEEK_MONTH picks the month (0-based, default 0 = January — the reproduced real-world
    /// dip) and CC_BENCH_WEEKS the walked week indices (0-based within the month's weekly rows,
    /// default "2,3" — the breadcrumb's Week 3⇄Week 4), forward then back, ×3 for a sustained run.
    private func sceneBenchWeekSwipe() async {
        guard let engine else { return }
        try? await pause(1.2)
        let env = ProcessInfo.processInfo.environment
        let month = max(0, min(11, env["CC_BENCH_WEEK_MONTH"].flatMap { Int($0) } ?? 0))
        var weeks = env["CC_BENCH_WEEKS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [2, 3]
        if weeks.count < 2 { weeks = [2, 3] }
        engine.demoGoToWeek(month: month, week: CGFloat(weeks[0]))
        try? await pause(0.8)
        // CC_BENCH_DASH=1 → run the same swipes with the ⌘B side panel PINNED OPEN (the reported
        // regression: week paging with the dashboard out). Pin before recording so the pin tween
        // itself doesn't pollute the swipe stats (bench-dash-toggle measures that separately).
        if env["CC_BENCH_DASH"] != nil, !engine.dashPinned {
            engine.toggleDashPin()
            for _ in 0 ..< 50 { engine.wake(); try? await pause(0.016) } // ride out the 0.3s reveal
        }
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        dashWebCarousel?.benchWebStart() // page-side rAF recorder (no-op when no webview mounted)
        RenderProf.mark("benchBegin")
        // The pager's cell width — mirrors WeekPager: the visible window inside the padding + gutter.
        let dayW = max(1, (size.width - Layout.padLeft - Layout.padRight - Layout.labelW) / Layout.weekDaysVisible)
        let steps = max(2, env["CC_BENCH_SWIPE_STEPS"].flatMap { Int($0) } ?? 40)
        let gap = env["CC_BENCH_SWIPE_GAP"].flatMap { Double($0) } ?? 0.15
        // Adjacent transitions forward then backward (2→3→2), repeated — same shape as the month tour.
        let fwd = zip(weeks, weeks.dropFirst()).map { ($0, $1) }
        let leg = fwd + fwd.reversed().map { ($0.1, $0.0) }
        for (from, to) in leg + leg + leg {
            engine.beginWeekGesture()
            moveStart = Date.timeIntervalSinceReferenceDate
            for i in 0 ... steps {
                let t = easeOutQuad(CGFloat(i) / CGFloat(steps))
                let x = (CGFloat(from) + CGFloat(to - from) * t) * 7 * dayW
                engine.setWeekProgress(x, dayW: dayW)
                engine.wake()
                try? await pause(0.008)
            }
            benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
            engine.endWeekGesture()
            try? await pause(gap)
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        let web = await dashWebCarousel?.benchWebCollect()
            ?? (frames: [], longTasks: [], units: [], epoch: [])
        writeBenchResults(webFrames: web.frames, webLongTasks: web.longTasks, webUnits: web.units,
                          webEpoch: web.epoch)
    }

    /// ⌘B dashboard-pin toggle benchmark: repeatedly open/retract the pinned side panel at MONTH or
    /// WEEK level (CC_BENCH_DASH_LEVEL=month|week, default month; CC_BENCH_WEEK_MONTH picks the month
    /// for both). Each toggle runs the 0.3s dashPinTween, during which dashPin re-derives the WHOLE
    /// month/week geometry every frame (day widths shrink/grow) AND the panel webview rides the mask
    /// edge — the reported "⌘B drops the framerate" cost. Toggle windows are recorded as moving
    /// phases so the stats isolate the tween frames from the settles between.
    private func sceneBenchDashToggle() async {
        guard let engine else { return }
        try? await pause(1.2)
        let env = ProcessInfo.processInfo.environment
        let month = max(0, min(11, env["CC_BENCH_WEEK_MONTH"].flatMap { Int($0) } ?? 5))
        if env["CC_BENCH_DASH_LEVEL"] == "week" {
            engine.demoGoToWeek(month: month, week: 2)
        } else {
            engine.setView(zoom: "month", focusedMonth: month)
        }
        try? await pause(1.0)
        // Deterministic start: panel retracted (dashPinned persists in UserDefaults across runs).
        if engine.dashPinned {
            engine.toggleDashPin()
            for _ in 0 ..< 40 { engine.wake(); try? await pause(0.016) }
        }
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        dashWebCarousel?.benchWebStart() // page-side rAF recorder (no-op when no webview mounted)
        RenderProf.mark("benchBegin")
        // CC_BENCH_DASH_PERIOD=secs → RAPID toggling: fire ⌘B every `period` seconds (0.35 ≈ the
        // "hammering cmd+b 2-3×/sec" repro), so each toggle RETARGETS the still-running 0.3s pin
        // tween (and the gutter slide) mid-flight — the panel never rests. One continuous moving
        // window spans the whole burst. Without the env: 3 settled open/close cycles (the default).
        if let period = env["CC_BENCH_DASH_PERIOD"].flatMap({ Double($0) }) {
            let toggles = max(2, env["CC_BENCH_DASH_TOGGLES"].flatMap { Int($0) } ?? 12)
            moveStart = Date.timeIntervalSinceReferenceDate
            for _ in 0 ..< toggles {
                engine.toggleDashPin()
                let steps = max(1, Int(period / 0.016))
                for _ in 0 ..< steps { engine.wake(); try? await pause(0.016) }
            }
            // Ride out the last tween so its tail frames stay inside the moving window.
            for _ in 0 ..< 28 { engine.wake(); try? await pause(0.016) }
            benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
        } else {
            for _ in 0 ..< 6 { // 3 full open/close cycles
                engine.toggleDashPin()
                moveStart = Date.timeIntervalSinceReferenceDate
                // Keep the render loop awake through the 0.3s tween + a short settle (the wake loop
                // is what a real ⌘B gets from the tween's own animation pump). The MOVING window
                // records only the tween itself — deferred content that fills in on the settled
                // frames right after is by design (invisible), not jank.
                for _ in 0 ..< 28 { engine.wake(); try? await pause(0.016) }
                benchMoves.append((moveStart, moveStart + 0.32))
                try? await pause(0.25)
            }
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        let web = await dashWebCarousel?.benchWebCollect()
            ?? (frames: [], longTasks: [], units: [], epoch: [])
        writeBenchResults(webFrames: web.frames, webLongTasks: web.longTasks, webUnits: web.units,
                          webEpoch: web.epoch)
    }

    /// Dashboard EDIT-ECHO benchmark: with the ⌘B panel pinned open (month or week level, same
    /// CC_BENCH_DASH_LEVEL knob), append characters to TODAY's daily note at typing cadence.
    /// Every edit bumps editGen → a fresh dashboardDataJSON → CK.setData in the page — the path a
    /// notepad keystroke's echo takes, which re-renders every mounted panel. With a note-heavy
    /// store this is where "typing in the notepad feels laggy" lives. Measures native frames +
    /// the page's rAF cadence + slow setData/tick applies (web_* / WEB-SLOWTICK fields).
    private func sceneBenchDashEdit() async {
        guard let engine else { return }
        try? await pause(1.2)
        let env = ProcessInfo.processInfo.environment
        let month = max(0, min(11, env["CC_BENCH_WEEK_MONTH"].flatMap { Int($0) } ?? 6))
        if env["CC_BENCH_DASH_LEVEL"] == "week" {
            engine.demoGoToWeek(month: month, week: 2)
        } else {
            engine.setView(zoom: "month", focusedMonth: month)
        }
        try? await pause(1.0)
        if !engine.dashPinned {
            engine.toggleDashPin()
        }
        for _ in 0 ..< 60 { engine.wake(); try? await pause(0.016) } // panel out + first render settled
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        dashWebCarousel?.benchWebStart()
        RenderProf.mark("benchBegin")
        // Type a burst into today's note: 40 appends at ~70ms (a brisk ~14 cps typist). The note
        // already carries a todo line so every keystroke re-tokenizes real content.
        let iso = String(format: "%04d-%02d-15", engine.year, month + 1)
        let base = engine.dailyNote(iso)
        var text = base.isEmpty ? "- [ ] bench typing target" : base
        moveStart = Date.timeIntervalSinceReferenceDate
        for i in 0 ..< 40 {
            text += String(UnicodeScalar(97 + i % 26)!)
            engine.setDailyNote(iso, text)
            for _ in 0 ..< 4 { engine.wake(); try? await pause(0.0175) }
        }
        benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
        RenderProf.mark("benchEnd")
        benchActive = false
        engine.setDailyNote(iso, base) // leave the throwaway store's note as found
        let web = await dashWebCarousel?.benchWebCollect()
            ?? (frames: [], longTasks: [], units: [], epoch: [])
        writeBenchResults(webFrames: web.frames, webLongTasks: web.longTasks, webUnits: web.units,
                          webEpoch: web.epoch)
    }

    /// The user's "click into July" freeze repro: launch at YEAR view with the dashboard PINNED,
    /// then an ANIMATED zoom into the month — the panel presents mid-tween, paying the cold
    /// todo-feed parse + the panel's first mount inside the animation. Frames are recorded through
    /// the zoom; afterwards a forced cold rebuild of the feed is timed on its own (noteGen bump →
    /// todoFeed) and written alongside the frame stats.
    private func sceneBenchDashZoomIn() async {
        guard let engine else { return }
        try? await pause(1.4)
        engine.demoGoToYear(centerMonth: 6)
        engine.pinDashboard() // persisted-pin case: the panel pops as the month opens
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        dashWebCarousel?.benchWebStart()
        RenderProf.mark("benchBegin")
        moveStart = Date.timeIntervalSinceReferenceDate
        engine.setView(zoom: "month", focusedMonth: 6) // the animated year→month zoom
        for _ in 0 ..< 70 { engine.wake(); try? await pause(0.016) }
        benchMoves.append((moveStart, moveStart + 0.7))
        RenderProf.mark("benchEnd")
        benchActive = false
        // Cold-feed rebuild cost, measured off the animation: bump noteGen, time todoFeed.
        engine.setDailyNote("2099-01-01", "- [ ] rebuild probe")
        let t0 = Date()
        _ = engine.todoFeed(today: NativeDashPanel.todayIso())
        let feedMs = Date().timeIntervalSince(t0) * 1000
        engine.setDailyNote("2099-01-01", "")
        if let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty {
            try? String(format: "%.1f\n", feedMs)
                .write(toFile: (dir as NSString).appendingPathComponent("todofeed-ms.txt"),
                       atomically: true, encoding: .utf8)
        }
        let web = await dashWebCarousel?.benchWebCollect() ?? (frames: [], longTasks: [], units: [], epoch: [])
        writeBenchResults(webFrames: web.frames, webLongTasks: web.longTasks, webUnits: web.units,
                          webEpoch: web.epoch)
    }

    /// Continuous pinch-zoom benchmark: year → day → year (z 0→3→0) driven through the REAL magnify
    /// path (`demoMagnify` → onMagnify), ×3 cycles. Crosses every zoom seam — including z=1.5, where
    /// the sticker Canvas fast path hands plain stickers back to SwiftUI views (month→week) — so a
    /// promotion hitch there shows up as a mid-gesture stall. Pinch is anchored mid-window over July.
    private func sceneBenchPinchZoom() async {
        guard let engine else { return }
        try? await pause(1.2)
        engine.demoGoToYear(centerMonth: 6) // July centered — the dense month under the pinch anchor
        try? await pause(0.8)
        benchFrames.removeAll()
        RenderProf.reset()
        benchActive = true
        RenderProf.mark("benchBegin")
        let pt = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        // A full single-level pinch accumulates ≈0.7 of magnification (see demoMagnify); three levels
        // over `steps` frames ≈ a brisk ~1s continuous gesture at 120Hz.
        let steps = 90
        for _ in 0 ..< 3 {
            for zoomIn in [true, false] {
                engine.demoMagnify(delta: 0, atView: pt, began: true, ended: false)
                moveStart = Date.timeIntervalSinceReferenceDate
                for _ in 1 ... steps {
                    let d: CGFloat = (zoomIn ? 1 : -1) * (0.7 * 3 / CGFloat(steps))
                    engine.demoMagnify(delta: d, atView: pt, began: false, ended: false)
                    engine.wake()
                    try? await pause(0.008)
                }
                benchMoves.append((moveStart, Date.timeIntervalSinceReferenceDate))
                engine.demoMagnify(delta: 0, atView: pt, began: false, ended: true)
                try? await pause(0.35) // let the level-snap settle before reversing
            }
        }
        RenderProf.mark("benchEnd")
        benchActive = false
        writeBenchResults()
    }

    /// Times the pure notification-planning pass over the loaded store (the main-thread stall a
    /// post-edit resync costs) → $CC_DEMO_DATADIR/notify-bench.json.
    private func sceneBenchNotifyPlan() async {
        guard let engine else { return }
        try? await pause(1.5) // store load settle
        let ms = engine.benchNotifyPlan(reps: 20)
        let sorted = ms.sorted()
        let out: [String: Any] = [
            "reps": ms.count,
            "plan_ms_min": (sorted.first! * 100).rounded() / 100,
            "plan_ms_p50": (sorted[sorted.count / 2] * 100).rounded() / 100,
            "plan_ms_max": (sorted.last! * 100).rounded() / 100,
        ]
        if let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("notify-bench.json"))
        }
    }

    private func webEpoch0(_ e: [Double]) -> Double { e[0] } // (helper keeps the closure typable)

    /// Frame-time stats over the recorded ticks → $CC_DEMO_DATADIR/bench.json.
    /// `webFrames`: the dashboard PAGE's own rAF timestamps (ms) — reported as web_* fields so the
    /// content process's cadence sits next to the native one (it janks invisibly to benchTick).
    private func writeBenchResults(webFrames: [Double] = [], webLongTasks: [[Double]] = [],
                                   webUnits: [[Any]] = [], webEpoch: [Double] = []) {
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty,
              benchFrames.count > 2 else { return }
        let deltas = zip(benchFrames.dropFirst(), benchFrames).map { $0 - $1 }.filter { $0 > 0 }
        guard !deltas.isEmpty else { return }
        // Moving-phase-only stats (frames inside recorded gesture windows): the number that
        // matches what the EYE sees — a slow frame on a static screen is invisible.
        var movingDeltas: [Double] = []
        var hitchOffsets: [Double] = [] // hitch position within its turn window (0 = turn start), seconds
        if !benchMoves.isEmpty {
            for (t2, t1) in zip(benchFrames.dropFirst(), benchFrames) {
                if let win = benchMoves.first(where: { t2 > $0.0 && t2 <= $0.1 + 0.02 }) {
                    movingDeltas.append(t2 - t1)
                    if t2 - t1 > 1.0 / 30.0 {
                        hitchOffsets.append(((t2 - win.0) * 1000).rounded() / 1000)
                    }
                }
            }
        }
        let sorted = deltas.sorted()
        func pctMs(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000
        }
        func r2(_ x: Double) -> Double {
            (x * 100).rounded() / 100
        }
        let seconds = benchFrames.last! - benchFrames.first!
        // The WORST 1-second rolling window's fps — exactly what the on-screen HUD shows as "lowest
        // framerate," which the avg/p95 summary hides (a cluster of hitches inside one second reads far
        // lower than p95). For each frame, count frames in the trailing 1s and take the min fps over the run.
        func hudMinFps() -> Double {
            guard benchFrames.count > 5 else { return r2(Double(deltas.count) / seconds) }
            var worst = Double.infinity
            var lo = 0
            for hi in 1 ..< benchFrames.count {
                while benchFrames[hi] - benchFrames[lo] > 1.0 { lo += 1 }
                let span = benchFrames[hi] - benchFrames[lo]
                let n = hi - lo
                if span >= 0.5, n >= 3 { worst = min(worst, Double(n) / span) } // need a near-full window
            }
            return worst.isFinite ? r2(worst) : r2(Double(deltas.count) / seconds)
        }
        let base: [String: Any] = [
            "frames": deltas.count + 1,
            "seconds": r2(seconds),
            "avg_fps": r2(Double(deltas.count) / seconds),
            "hud_min_fps": hudMinFps(),
            "frame_ms_p50": r2(pctMs(0.50)),
            "frame_ms_p95": r2(pctMs(0.95)),
            "frame_ms_max": r2(sorted.last! * 1000),
            "hitches_over_33ms": deltas.filter { $0 > 1.0 / 30.0 }.count,
        ]
        var out2 = base
        if !movingDeltas.isEmpty {
            let ms = movingDeltas.sorted()
            out2["moving_avg_fps"] = r2(Double(movingDeltas.count) / movingDeltas.reduce(0, +))
            out2["moving_p95_ms"] = r2(ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))] * 1000)
            out2["moving_max_ms"] = r2(ms.last! * 1000)
            out2["moving_hitches"] = movingDeltas.filter { $0 > 1.0 / 30.0 }.count
            out2["hitch_offsets_s"] = hitchOffsets
        }
        // Webview (content-process) frame cadence over the same run, from the injected rAF
        // recorder. Same stat shapes as the native side, prefixed web_.
        if webFrames.count > 5 {
            let wd = zip(webFrames.dropFirst(), webFrames).map { ($0 - $1) / 1000 }.filter { $0 > 0 }
            if !wd.isEmpty {
                let ws = wd.sorted()
                let span = (webFrames.last! - webFrames.first!) / 1000
                out2["web_frames"] = wd.count + 1
                out2["web_avg_fps"] = r2(Double(wd.count) / span)
                out2["web_p50_ms"] = r2(ws[ws.count / 2] * 1000)
                out2["web_p95_ms"] = r2(ws[min(ws.count - 1, Int(Double(ws.count) * 0.95))] * 1000)
                out2["web_max_ms"] = r2(ws.last! * 1000)
                out2["web_hitches"] = wd.filter { $0 > 1.0 / 30.0 }.count
            }
        }
        if !webLongTasks.isEmpty {
            let durs = webLongTasks.compactMap { $0.count == 2 ? $0[1] : nil }
            out2["web_longtasks"] = durs.count
            out2["web_longtask_ms"] = r2(durs.reduce(0, +))
            out2["web_longtask_max_ms"] = r2(durs.max() ?? 0)
        }
        // Web frames windowed to the MOVING phases: converts the page's performance.now clock to
        // Date-epoch via the recorder's [Date.now, performance.now] pair, then keeps only frame
        // deltas ending inside a recorded gesture window — a long web frame on a static settle
        // (the defer-reveal) is invisible; one mid-slide is the jank the user sees.
        if webFrames.count > 5, webEpoch.count == 2, !benchMoves.isEmpty {
            let toRef = { (t: Double) -> Double in
                (self.webEpoch0(webEpoch) + (t - webEpoch[1])) / 1000 - 978_307_200
            }
            var mv: [Double] = []
            for (t2, t1) in zip(webFrames.dropFirst(), webFrames) {
                let r = toRef(t2)
                if benchMoves.contains(where: { r > $0.0 && r <= $0.1 + 0.02 }), t2 > t1 {
                    mv.append((t2 - t1) / 1000)
                }
            }
            if !mv.isEmpty {
                let ms = mv.sorted()
                out2["web_moving_p95_ms"] = r2(ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))] * 1000)
                out2["web_moving_max_ms"] = r2(ms.last! * 1000)
                out2["web_moving_hitches"] = mv.filter { $0 > 1.0 / 30.0 }.count
            }
            // Every big web frame gap, stamped by its offset from the nearest turn start —
            // separates mid-slide jank (offset < tween) from post-slide fill-in (offset > tween).
            var gaps: [String] = []
            for (t2, t1) in zip(webFrames.dropFirst(), webFrames) where t2 - t1 > 25 {
                let r = toRef(t2)
                let near = benchMoves.map { r - $0.0 }.min(by: { abs($0) < abs($1) }) ?? -99
                gaps.append(String(format: "%.0fms@%+.3fs", t2 - t1, near))
            }
            if !gaps.isEmpty { out2["web_gaps"] = gaps }
        }
        if !webUnits.isEmpty {
            // Named page-render units >2ms (guarded()): "what 12.3" strings, slowest first.
            let named = webUnits.compactMap { u -> (String, Double)? in
                guard u.count == 2, let n = u[0] as? String, let d = u[1] as? Double else { return nil }
                return (n, d)
            }.sorted { $0.1 > $1.1 }
            out2["web_units"] = named.prefix(12).map { "\($0.0) \($0.1)" }
        }
        // Per-layer CPU attribution (CC_PROF=1): each draw layer's [samples, avg-ms, total-ms, peak-ms].
        // NB: main-thread CPU only — glass GPU compositing is invisible here (see RenderProfiler).
        let layers = RenderProf.summary()
        if !layers.isEmpty {
            out2["layers_ms"] = layers
        }
        let out = out2
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("bench.json"))
        }
    }

    /// ── Cursor motion ──────────────────────────────────────────────────────────────────────────
    private func move(to p: CGPoint, over duration: Double, steps: Int = 34) async {
        let from = cursor ?? p
        for i in 1 ... steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 // easeInOut
            cursor = CGPoint(x: from.x + (p.x - from.x) * e, y: from.y + (p.y - from.y) * e)
            try? await pause(duration / Double(steps))
        }
    }

    private func pause(_ s: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    /// Tell the recorder the scene has finished its OFF-CAMERA setup (seeding, navigating to the starting
    /// view) and is holding, ready to be filmed. The script waits for this before it starts recording, so
    /// setup animations (e.g. zooming into the week) never end up in the GIF.
    private func signalReady() {
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty else { return }
        try? "ready\n".write(
            toFile: (dir as NSString).appendingPathComponent("ready.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Block until the recorder drops a `go.txt` in the data dir (or ~4s elapse as a fallback for a manual
    /// run with no recorder). Lets a scene align its first visible frame with the start of the recording.
    private func waitForGo() async {
        defer { goTime = Date() } // recording is now rolling — start the on-camera clock
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty else { return }
        let flag = (dir as NSString).appendingPathComponent("go.txt")
        for _ in 0 ..< 40 {
            if FileManager.default.fileExists(atPath: flag) {
                return
            }
            try? await pause(0.1)
        }
    }

    /// Write the on-camera duration (seconds since `go`) to `done.txt` so the recorder can trim the
    /// over-recorded video to the scene's exact end.
    private func signalDone() {
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty,
              let go = goTime else { return }
        let elapsed = Date().timeIntervalSince(go)
        try? String(format: "%.2f\n", elapsed).write(toFile: (dir as NSString).appendingPathComponent("done.txt"),
                                                     atomically: true, encoding: .utf8)
    }

    /// Write the scene's crop region (a fraction of the view) to $CC_DEMO_DATADIR/crop.txt in VIEW-LOCAL
    /// points (top-left origin, relative to the content area). The recording script records only this
    /// region, so each GIF is tight around the events/timeline instead of the whole window.
    private func writeCrop(x fx: CGFloat, y fy: CGFloat, w fw: CGFloat, h fh: CGFloat) {
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty else { return }
        // Even integers keep the encoder happy; clamp inside the content.
        let x = Int((size.width * fx).rounded()), y = Int((size.height * fy).rounded())
        let w = Int((size.width * fw).rounded()) & ~1, h = Int((size.height * fh).rounded()) & ~1
        let line = "\(x) \(y) \(w) \(h)\n"
        try? line.write(toFile: (dir as NSString).appendingPathComponent("crop.txt"), atomically: true, encoding: .utf8)
    }
}

/// The drawn synthetic cursor (a macOS arrow + an optional press ring). Positioned in the calendar view's
/// local space by the controller.
public struct DemoCursorOverlay: View {
    let demo: DemoController
    public init(demo: DemoController) {
        self.demo = demo
    }

    public var body: some View {
        // Pinch-zoom gesture: two fingertips joined by a dotted line through the pinch centre (the exact
        // point being zoomed into), all in the app's red accent.
        if let (a, b) = demo.pinchDots {
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            ZStack {
                // Dotted line spanning the two fingertips (passes through the centre).
                Path { p in p.move(to: a); p.addLine(to: b) }
                    .stroke(Theme.accent.opacity(0.7),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                // Centre marker: the month/week/day the pinch is zooming into.
                Circle().fill(Theme.accent)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5).frame(width: 9, height: 9))
                    .position(mid)
                // The two fingertips.
                ForEach([a, b].indices, id: \.self) { i in
                    Circle().fill(Theme.accent.opacity(0.9))
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 22, height: 22))
                        .position(i == 0 ? a : b)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        if let p = demo.cursor {
            let img = NSCursor.arrow.image
            let hs = NSCursor.arrow.hotSpot
            ZStack {
                // Press ring — centered EXACTLY on the pointer tip (`p`), in the app's red accent.
                if demo.pressed {
                    Circle().stroke(Theme.accent, lineWidth: 2.5)
                        .frame(width: 30, height: 30)
                        .position(p)
                }
                // The arrow, offset so its hotspot (tip) lands on `p`.
                Image(nsImage: img)
                    .interpolation(.high)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .position(x: p.x + img.size.width / 2 - hs.x, y: p.y + img.size.height / 2 - hs.y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // fill the overlay so .position uses view coords
            .allowsHitTesting(false)
        }
    }
}

/// Live frame-rate readout (CC_FPS_HUD=1): fps + p95/max frame time over the last second, refreshed twice a
/// second from the render loop's own tick (benchTick). Green = holding refresh, yellow = missing frames,
/// red = visible hitches. Shows "idle" while the render loop is paused (no frames — nothing to judge).
struct FPSHUD: View {
    let demo: DemoController
    @State private var text = "fps —"
    @State private var tint = Color.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)
            .allowsHitTesting(false)
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                if let s = demo.hudStats() {
                    text = String(format: "%3.0f fps · p95 %4.1f ms · max %4.1f", s.fps, s.p95ms, s.maxms)
                    tint = s.p95ms > 17 ? .red : (s.p95ms > 9.5 ? .yellow : .green)
                } else {
                    text = "idle"; tint = .secondary
                }
            }
    }
}
