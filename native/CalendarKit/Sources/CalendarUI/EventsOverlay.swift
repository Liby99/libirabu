// Timed + band events as real SwiftUI views layered over the Canvas — each sticker
// is Liquid Glass (.glassEffect), so overlapping events are genuinely translucent
// and blur what's behind them (the native analogue of the web's translucent fill +
// backdrop-filter). Visual only; gestures are handled by the AppKit input bridge.

import AppKit
import CalendarGeometry
import SwiftUI

struct EventsOverlay: View {
    let input: SceneInput
    let events: [TimedEvent]
    let bands: [BandEvent]
    var bandBadges: [String: EventBadges] = [:] // provenance/kind markers per band box id
    var eventBadges: [String: EventBadges] = [:] // …and per timed-event box id
    let selected: String? // the PRIMARY selected BOX id (a ghost carries occKey); series-matched below
    var selectedIds: Set<String> = [] // the FULL multi-selection (each member gets a focus ring)
    let hovered: String? // the hovered BOX id (exact box gets hover feedback)
    let drawerOpen: Bool // the detail drawer is open → the focused box gets the thick border
    let editingId: String?
    var editingRect: CGRect? // the inline title editor's rect → hide the title on THAT segment only
    var draggingId: String? // event being moved/resized → floats full-width above the day,
    // and is excluded from the others' overlap packing (no reflow)
    var perfMode: Bool = false // flat tinted fills instead of Liquid Glass (global toggle)
    var monthLive = false // month gesture/turn in progress → pre-mount the neighbor months' stickers
    var editGen: UInt64 = 0 // data-edit generation (keys the cached per-month packing)
    var onlyBox: String? // when set, PACK everything as usual but DRAW only this box (the
    // sharp "lifted" copy above the drawer's blur scrim — see CalendarView)
    var hideBox: String? // …and the inverse: the blurred main render SKIPS this box (it's drawn
    // sharp by the lifted copy), so there's no blurry halo behind it
    let theme: Theme

    static let spilloverDim: CGFloat = 0.45 // opacity of neighbor-month (spillover-day) events

    /// A box belongs to the clicked event's series (same source: recurrence occurrence / promoted
    /// bar / original), so it shares the accompanied style.
    /// The activation level for a box (see EventActivation). Only the EXACT selected box is focused
    /// (single click) or selected (drawer open) — each box is independent, so siblings/source are NOT
    /// accompanied. An unrelated box under the pointer is hover; everything else is plain.
    private func activation(_ id: String) -> EventActivation {
        // Multi-select: every member gets a focus ring. A lone selection with the drawer open gets the
        // thick "selected" border. (The lifted-copy overlay passes only `selected` — the id check keeps it.)
        if selectedIds.contains(id) {
            return (selectedIds.count == 1 && drawerOpen) ? .selected : .focusMain
        }
        if id == selected {
            return drawerOpen ? .selected : .focusMain
        }
        if id == hovered {
            return .hover
        }
        return .plain
    }

    /// True when this box is the one the inline title editor sits over. `editingRect` is a specific
    /// segment's rect (same coord space as the box rects); nil means match by id alone (e.g. a band).
    private static func editingThisBox(_ boxRect: CGRect, _ editingRect: CGRect?) -> Bool {
        guard let e = editingRect else { return true }
        return abs(boxRect.minX - e.minX) < 2 && abs(boxRect.minY - e.minY) < 2
    }

    var body: some View {
        let anim = input.monthAnim
        let to = anim.map { input.focus + $0.dir }
        // Outgoing (current) month — slides + fades out during a page-turn (anim==nil → resting, mul 1).
        let tlOut = timelineInfo(input, anim: anim)
        let outMul = anim.map { outgoingDetailReveal($0.p) } ?? 1
        let clipRight = dashboardLeftAnimated(input) // day-view dashboard mask (slides in from the right)
        let bandClip = CGRect(x: Layout.labelW, y: 0, width: max(0, clipRight - Layout.labelW), height: input.vp.h)

        ZStack(alignment: .topLeading) {
            stickers(bandItems()).clipShape(RectClip(rect: bandClip))
            if tlOut.reveal > 0.05 && tlOut.hourH > 0 {
                stickers(timedItems(tlOut, focus: input.focus, fadeMul: outMul))
                    .clipShape(RectClip(rect: tlClip(tlOut, clipRight)))
            }
            // Neighbor months' stickers, mounted the whole time month view is AT REST (plus any
            // in-flight turn): creating a dense month's sticker views is a measured ~50ms hitch,
            // and doing it lazily put that hitch INSIDE the page-turn animation (bench-month-swipe:
            // p95 16.7ms, 6-8 hitches; with pre-mounted neighbors p95 8.3ms). Mounted at arrival,
            // the churn lands on the settled frame — where a slow frame is invisible — and every
            // swipe finds both neighbors ready. The z-window keeps the mount off the animated
            // zoom-in (it lands once the zoom settles); non-matching neighbors sit at progress 0
            // (one page off-screen) with fade 0.
            if abs(input.z - 1) < 0.01 || anim != nil || monthLive {
                ForEach([input.focus - 1, input.focus + 1].filter { $0 >= 0 && $0 <= 11 }, id: \.self) { m in
                    let dir = m > input.focus ? 1 : -1
                    let matching = anim?.dir == dir
                    let p: CGFloat = matching ? (anim?.p ?? 0) : 0
                    let tlIn = timelineInfo(input, focus: m, anim: PageAnim(dir: dir, p: p))
                    if tlIn.reveal > 0.05 && tlIn.hourH > 0 {
                        stickers(timedItems(tlIn, focus: m, fadeMul: matching ? incomingDetailReveal(p) : 0,
                                            keyTag: "~n\(m)"))
                            .clipShape(RectClip(rect: tlClip(tlIn, clipRight)))
                    }
                }
            }
            // Year-view weekday marker ("Thu") floating above the hovered day — a small
            // Liquid Glass capsule, centered on the day column.
            if let wm = weekdayMarker() {
                Text(wm.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
                    .position(wm.center)
            }
            // Current-time label(s): dark-red glass + a red caret pointing at the now-line. The line
            // itself stays in the Canvas; only this label is SwiftUI (for real glass blur).
            // Suppressed in the lifted copy (onlyBox) — it should show ONLY the selected event.
            // Clip to the content region (right edge = the dashboard's animated left edge): the SwiftUI
            // glass pill would otherwise composite ABOVE the dashboard WebView — unlike the Canvas
            // now-line, which is clipped there — so in week view a right-side day's label leaked over
            // the panel while the line sat under it. Clipping here keeps the two layered the same.
            if onlyBox == nil {
                ZStack(alignment: .topLeading) {
                    ForEach(nowLabelSpecs(input)) { spec in
                        nowLabelView(spec)
                    }
                }
                .clipShape(RectClip(rect: CGRect(
                    x: -Layout.labelW,
                    y: 0,
                    width: clipRight + Layout.labelW,
                    height: input.vp.h
                )))
            }
            // Mouse-cursor time tag: SwiftUI (not Canvas) so it isn't clipped at the gutter and its
            // side animates smoothly on a flip (e.g. the week↔day transition) instead of jumping.
            if let tag = cursorTagSpec(input) {
                cursorTagView(tag)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func cursorTagView(_ spec: CursorTagSpec) -> some View {
        let c = theme.cursor
        let shape = RoundedRectangle(cornerRadius: 5)
        Text(spec.text)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(c)
            .frame(width: spec.rect.width, height: spec.rect.height)
            .background(shape.fill(theme.bg.opacity(0.82)))
            .overlay(shape.strokeBorder(c, lineWidth: 1))
            // Caret on the line-facing edge; on a side flip the old one retracts and the new one grows.
            .overlay { flipCaret(pointsRight: true, shown: spec.pointsRight, color: c, h: 8) }
            .overlay { flipCaret(pointsRight: false, shown: !spec.pointsRight, color: c, h: 8) }
            .opacity(spec.opacity)
            .position(x: spec.rect.midX, y: spec.rect.midY)
            .animation(.easeInOut(duration: 0.2), value: spec.pointsRight) // slide + caret-swap on flip
            .allowsHitTesting(false)
    }

    /// A caret on one edge that grows in / retracts out as `shown` toggles — so a left↔right flip
    /// reads as one caret sliding out while the other slides in, instead of instantly swapping sides.
    private func flipCaret(pointsRight: Bool, shown: Bool, color: Color, h: CGFloat) -> some View {
        Caret(pointsRight: pointsRight).fill(color)
            .frame(width: 5, height: h)
            .scaleEffect(x: shown ? 1 : 0, anchor: pointsRight ? .leading : .trailing) // grow/retract at the edge
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointsRight ? .trailing : .leading)
            .offset(x: pointsRight ? 5 : -5)
            .opacity(shown ? 1 : 0)
    }

    @ViewBuilder private func nowLabelView(_ spec: NowLabelSpec) -> some View {
        let red = theme.nowLine
        let shape = RoundedRectangle(cornerRadius: 10) // match the deadline pill's radius
        // Dark mode: dark base + strong red glass, white label. Light mode: a bright frosted
        // base with only a faint red tint, and a dark label — the time stays red in both.
        let labelColor: Color = theme.dark ? .white.opacity(0.7) : theme.text.opacity(0.7)
        let baseFill: Color = (theme.dark ? Color.black : Color.white).opacity(theme.dark ? 0.55 : 0.62)
        let glassTint = red.opacity(theme.dark ? 0.5 : 0.14)
        VStack(alignment: spec.pointsRight ? .trailing : .leading, spacing: -1) {
            Text("CURRENT TIME").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(labelColor)
            Text(spec.text).font(.system(size: 13, weight: .bold)).foregroundStyle(red) // time in the accent color
            if let alt = spec.altText { // alt-tz wall clock, e.g. "13:45 (PST)"
                Text(alt).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(labelColor).padding(.top, 1.5)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3) // match the deadline pill's padding
        .frame(width: spec.rect.width, height: spec.rect.height, alignment: spec.pointsRight ? .trailing : .leading)
        .background(shape.fill(baseFill)) // solid base so the frost reads clean
        .glassEffect(.regular.tint(glassTint), in: shape)
        .overlay(shape.strokeBorder(red, lineWidth: 1)) // fully wrapped border
        // Caret on the line-facing edge; on a side flip (e.g. week↔day) the old one retracts and the
        // new one grows, so the label slides across smoothly instead of jumping.
        .overlay { flipCaret(pointsRight: true, shown: spec.pointsRight, color: red, h: 9) }
        .overlay { flipCaret(pointsRight: false, shown: !spec.pointsRight, color: red, h: 9) }
        .opacity(spec.opacity)
        .position(x: spec.rect.midX, y: spec.rect.midY + 1) // nudge the whole label + caret down 1px
        .animation(.easeInOut(duration: 0.2), value: spec.pointsRight) // slide + caret-swap on flip
        .allowsHitTesting(false)
    }

    /// Clip a timeline layer to its own (possibly sliding) day-detail region.
    private func tlClip(_ tl: TimelineInfo, _ clipRight: CGFloat) -> CGRect {
        CGRect(x: Layout.labelW, y: tl.tlTop, width: max(0, clipRight - Layout.labelW),
               height: max(0, tl.tlBottom - tl.tlTop))
    }

    /// The floating weekday chip for year-view day hover. Mirrors buildHover's `dayOn`:
    /// year zoom, a hovered month on screen, and a valid day-of-month.
    private func weekdayMarker() -> (center: CGPoint, text: String)? {
        guard input.z < 0.5, let m = input.hover.month, let dom = input.hover.dom else { return nil }
        guard dom >= 1 && dom <= daysInMonth(input.year, m) else { return nil }
        let f = frameFor(m, input)
        guard f.bandY <= input.vp.h + 20, f.bandY + 4 * f.trackH >= -20 else { return nil } // on screen
        let cx = f.x0 + (CGFloat(dom) - 0.5) * f.dayW // center of the day column
        let cy = f.bandY - 15 // floated above the band top
        return (CGPoint(x: cx, y: cy), WD3[dayOfWeek(input.year, m, dom)])
    }

    private struct Item2: Identifiable {
        let id: String; let rect: CGRect; let fade: Double; let z: Double; let view: AnyView
    }

    /// Does an item belong to the selected/hidden event `box`? Bands use the plain event id; a TIMED event
    /// uses a per-segment key ("id#MMDD", plus a "~in" transition twin), so a plain `== box` misses it —
    /// which left timed events neither skipped from the blur (`hideBox`) nor drawn in the lifted-above-scrim
    /// copy (`onlyBox`), so they no longer floated above the drawer scrim. Match the segment prefix too (this
    /// also lifts BOTH halves of a cross-midnight event, and every segment of a recurring band, together).
    private func matches(_ itemId: String, _ box: String) -> Bool {
        itemId == box || itemId == box + "~in" || itemId.hasPrefix(box + "#")
    }

    private func drawn(_ items: [Item2]) -> [Item2] {
        if let box = onlyBox {
            return items.filter { matches($0.id, box) }
        }
        if let box = hideBox {
            return items.filter { !matches($0.id, box) }
        }
        return items
    }

    private func stickers(_ items: [Item2]) -> some View {
        ZStack(alignment: .topLeading) {
            // Stable identity (event id) so a z-order re-sort keeps the view alive and its
            // hover/select transitions can animate rather than snapping. Draw order is the
            // explicit per-item z (band: 10+startDay baseline, raised on hover/select).
            ForEach(drawn(items)) { it in
                it.view
                    .frame(width: it.rect.width, height: it.rect.height)
                    .position(x: it.rect.midX, y: it.rect.midY)
                    .opacity(it.fade)
                    .zIndex(it.z)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A rect is worth rendering only if it (nearly) intersects the viewport. Culls the ~11
    /// months that sit off-screen in month view, and anything scrolled out of view elsewhere —
    /// each survivor is a real Liquid Glass sticker, so skipping them is the big per-frame win.
    private func onScreen(_ rect: CGRect) -> Bool {
        let M: CGFloat = 40
        return rect.maxY > -M && rect.minY < input.vp.h + M && rect.maxX > -M && rect.minX < input.vp.w + M
    }

    private func bandItems() -> [Item2] {
        var placed: [(ev: BandEvent, rect: CGRect, fade: Double, clipStart: Bool, clipEnd: Bool)] = []
        let weekish = input.z >= 1.5
        for b in bands {
            // Month/year layout positions a band by its month alone (frameFor(b.month)), so a
            // neighbor-year band would land in the CURRENT year's same-month row. Only the week/day
            // (weekish) path is year-safe (bandEventRect gates via relDomOf), so skip cross-year
            // bands outside it — they show only as week-view boundary spillover.
            if !weekish && b.year != input.year {
                continue
            }
            guard let r = bandEventRect(b, input, anim: input.monthAnim) else { continue }
            // Opacity comes from the FOCUS frame in week/day view (the adjacent month's own frame is
            // off-screen there); a neighbor-month band shown in the spillover columns is dimmed.
            let f = frameFor(weekish ? input.focus : b.month, input, anim: input.monthAnim)
            let spill: Double = weekish ? Double(spillFactor(b.month, input, dim: Self.spilloverDim)) : 1
            let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            guard f.opacity > 0.004, onScreen(rect) else { continue } // skip invisible / off-screen months
            placed.append((b, rect, Double(f.opacity) * spill, r.clipStart, r.clipEnd))
        }
        // Fully-overlapping (same month/track/startDay/endDay): collapse to ONE (highest id),
        // hide the rest, and flag the kept one with a warning sign.
        var hidden = Set<String>(), warn = Set<String>()
        var full: [String: [Int]] = [:]
        for (i, p) in placed.enumerated() {
            full[
                "\(p.ev.month)-\(p.ev.track)-\(p.ev.startDay)-\(p.ev.endDay)",
                default: []
            ].append(i)
        }
        for (_, idxs) in full where idxs.count > 1 {
            let keep = idxs.max { placed[$0].ev.id < placed[$1].ev.id }!
            warn.insert(placed[keep].ev.id)
            for i in idxs where i != keep {
                hidden.insert(placed[i].ev.id)
            }
        }
        // Per lane (visible bars): gap = px to the nearest LATER-starting bar (title clips
        // before it; unbounded if none). Same-start stacks: shorter on top (z), longer
        // simply behind — its title runs full and is covered by the shorter bar.
        var gapBy: [String: CGFloat] = [:]
        var zBy: [String: Double] = [:]
        var clipBox = Set<String>() // non-longest same-start bars clip to their own box
        var byLane: [String: [Int]] = [:]
        // Week view shows both months on the same 4 lanes, so group by track alone — a spillover
        // (neighbor-month) bar must "see" the focus bars on its lane so its title clips before them.
        for (i, p) in placed.enumerated() where !hidden.contains(p.ev.id) {
            byLane[weekish ? "\(p.ev.track)" : "\(p.ev.month)-\(p.ev.track)", default: []].append(i)
        }
        for (_, idxs) in byLane {
            for i in idxs {
                // Compare by rendered X (startDay isn't comparable across months in the shared lane).
                let later = idxs.filter { placed[$0].rect.minX > placed[i].rect.minX + 1 }
                if let nearest = later.min(by: { placed[$0].rect.minX < placed[$1].rect.minX }) {
                    gapBy[placed[i].ev.id] = placed[nearest].rect.minX - placed[i].rect.minX
                }
            }
            var byDay: [Int: [Int]] = [:]
            for i in idxs {
                byDay[placed[i].ev.startDay, default: []].append(i)
            }
            for (start, stackIdxs) in byDay where stackIdxs.count >= 2 {
                func len(_ i: Int) -> Int {
                    placed[i].ev.endDay - placed[i].ev.startDay
                }
                let stack = stackIdxs.sorted { len($0) > len($1) } // longest first (bottom)
                for si in stack.indices {
                    zBy[placed[stack[si]].ev.id] = Double(10 + start + si * 2) // shorter → higher → on top
                    if si > 0 {
                        clipBox.insert(placed[stack[si]].ev.id)
                    } // all but the longest
                }
            }
        }
        return placed.compactMap { p in
            let id = p.ev.id
            if hidden.contains(id) {
                return nil
            }
            let a = activation(id)
            let z: Double = a.isActive ? a.z : (zBy[id] ?? Double(10 + p.ev.startDay))
            return Item2(id: id, rect: p.rect, fade: p.fade, z: z, view: AnyView(
                BandSticker(ev: p.ev, activation: a, editing: id == editingId,
                            gap: gapBy[id], clipBox: clipBox.contains(id),
                            clipStart: p.clipStart, clipEnd: p.clipEnd,
                            warn: warn.contains(id), box: p.rect.size,
                            badges: bandBadges[id] ?? [],
                            plain: perfMode,
                            theme: theme)
            ))
        }
    }

    /// Timed stickers for one month `focus`, placed against its timeline `tl`. `fadeMul` scales
    /// the whole layer (a page-turn fades the outgoing set out / incoming set in); `keyTag` keeps
    /// the incoming set's ForEach ids distinct from the outgoing set's during the cross-fade.
    private func timedItems(_ tl: TimelineInfo, focus: Int, fadeMul: CGFloat = 1, keyTag: String = "") -> [Item2] {
        // `subLabels` carries the anchor-zone time (e.g. "12:00 – 14:00 (PST)") for events whose anchor
        // differs from the view zone. Cached: anchorRangeLabel does real timezone math, and it ran for
        // EVERY event on EVERY frame (×3 with neighbor months mounted) — hot in the swipe profile.
        var subLabels: [String: String] = [:]
        for e in events {
            let key = SubLabelKey(id: e.id, start: e.startHour, end: e.endHour,
                                  anchorTz: e.anchorTz ?? "", mainTz: input.mainTz)
            let lbl: String?
            if let hit = subLabelCache[key] {
                lbl = hit
            } else {
                lbl = anchorRangeLabel(e, mainTz: input.mainTz)
                if subLabelCache.count > 2048 {
                    subLabelCache.removeAll(keepingCapacity: true)
                }
                subLabelCache[key] = lbl
            }
            if let lbl {
                subLabels[e.id] = lbl
            }
        }
        // Segment grouping + per-day overlap packing, cached per (year, focus, editGen, dragging):
        // none of it depends on the per-frame timeline geometry (see timedLayoutCache).
        let layoutKey = TimedLayoutKey(year: input.year, focus: focus, editGen: editGen, dragging: draggingId)
        let days: [TimedDayLayout]
        if let hit = timedLayoutCache[layoutKey] {
            days = hit
        } else {
            // `relDomOf` gates adjacency (returns nil for non-neighbor months), so iterating all years
            // lets Dec↔Jan spillover events cross the year boundary while far-off months are excluded.
            // A cross-midnight event splits into per-day segments; each lands in its own day column.
            var byDay: [Int: [TimedSegment]] = [:]
            for e in events {
                for s in timedSegments(e) {
                    if let rd = relDomOf(input.year, focus, s.event.year, s.event.month, s.event.day) {
                        byDay[rd, default: []].append(s)
                    }
                }
            }
            // Pack the OTHER events as if the dragged one weren't in this day, so they don't shrink/
            // reflow mid-edit; the dragged event then gets no layout slot → eventRect renders it
            // full-width, and it draws on top (selected → frontmost z). Committed on drop.
            days = byDay.map { rd, segs in
                let evs = segs.map(\.event)
                return TimedDayLayout(rd: rd, segs: segs,
                                      layout: layoutDay(draggingId != nil ? evs.filter { $0.id != draggingId } : evs))
            }
            if timedLayoutCache.count > 64 {
                timedLayoutCache.removeAll(keepingCapacity: true)
            }
            timedLayoutCache[layoutKey] = days
        }
        var gf = input; gf.focus = focus
        let dim = daysInMonth(input.year, focus)
        var placed: [(seg: TimedSegment, rect: CGRect, fade: Double)] = []
        for day in days {
            let rd = day.rd
            // Spillover day (belongs to the previous/next month) → drawn dimmed but fully interactive;
            // a month-edge flip cross-fades the dim/bright swap. (rd<1 → prev month, rd>dim → next.)
            let evMonth = rd < 1 ? focus - 1 : (rd > dim ? focus + 1 : focus)
            let spill = (input.z >= 1.5) ? spillFactor((evMonth + 12) % 12, gf, dim: Self.spilloverDim) : 1
            let fade = dailyFade(rd, gf) * tl.reveal * fadeMul * spill
            if fade <= 0.02 {
                continue
            }
            for s in day.segs {
                guard let r = eventRect(s.event, input.year, focus, tl, input.vp, day.layout[s.event.id]) else { continue }
                let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                if rect.maxY < tl.tlTop || rect.minY > tl.tlBottom {
                    continue
                } // outside the timeline band
                if rect.maxX < -40 || rect.minX > input.vp.w + 40 {
                    continue
                } // scrolled off horizontally (week/day)
                placed.append((s, rect, Double(fade)))
            }
        }
        placed.sort(by: orderTimed)
        return placed.enumerated().map { i, p in
            let id = p.seg.event.id
            let a = activation(id)
            let z: Double = a.isActive ? a.z : Double(i)
            // The Item2 id must be unique per SEGMENT (a split event draws twice), but activation/badges
            // stay keyed by the shared event id → selecting highlights every segment at once.
            let segKey = "\(id)#\(p.seg.event.month * 100 + p.seg.event.day)"
            return Item2(id: segKey + keyTag, rect: p.rect, fade: p.fade, z: z, view: AnyView(
                EventSticker(ev: p.seg.event, height: p.rect.height, showText: input.z >= 1.5,
                             clipTop: p.seg.clipTop, clipBottom: p.seg.clipBottom,
                             timeText: fmtHourRange(p.seg.fullStart, p.seg.fullEnd),
                             subTimeText: subLabels[id],
                             plain: perfMode, activation: a, badges: eventBadges[id] ?? [],
                             // Hide the title ONLY on the segment the editor is over (rect match) — the other
                             // segments of a cross-midnight event keep showing the title (which updates live as
                             // you type), instead of going blank.
                             editing: editingId != nil && sourceId(of: id) == editingId && Self.editingThisBox(
                                 p.rect,
                                 editingRect
                             ),
                             theme: theme)
            ))
        }
    }

    /// Draw order: later-starting events in front; the selected box always frontmost.
    private func orderTimed(
        _ a: (seg: TimedSegment, rect: CGRect, fade: Double),
        _ b: (seg: TimedSegment, rect: CGRect, fade: Double)
    ) -> Bool {
        let sa = a.seg.event.id == selected, sb = b.seg.event.id == selected
        if sa != sb {
            return sb
        } // the selected box sorts last (front)
        if a.seg.event.startHour != b.seg.event.startHour {
            return a.seg.event.startHour < b.seg.event.startHour
        }
        return a.seg.event.endHour > b.seg.event.endHour
    }
}

private extension View {
    /// Event surface. `flat` = cheap tinted fill (Performance Mode at rest). `keepFillBase` keeps
    /// that flat fill UNDER the glass (Performance Mode is on), so a flat→glass hover cross-fades:
    /// the fill stays put and the glass materializes over the colored fill instead of tearing the
    /// fill out and flashing the dark backdrop while the glass forms. Non-perf: glass only.
    func eventSurface<S: Shape>(_ glass: Glass, plainFill: Color, in shape: S, flat: Bool,
                                keepFillBase: Bool) -> some View {
        self.background {
            ZStack {
                if flat || keepFillBase {
                    shape.fill(plainFill)
                } // stable base in Performance Mode
                if !flat {
                    Color.clear.glassEffect(glass, in: shape)
                } // glass on top; fades in over the fill
            }
        }
    }
}

/// A timed event — same visual language as a band (BandStyle): frosted glass tinted with
/// the event color, a rounded accent bar, dotted-when-selected / solid-when-drawer border.
/// Content is the height-driven title + time (clipped, unlike bands' overflow).
private struct EventSticker: View {
    let ev: TimedEvent
    let height: CGFloat
    var showText: Bool = true // month view hides title/time (tiny slivers) — glass + bar only
    var clipTop: Bool = false // cross-midnight: continues from the previous day → square top, bar to top edge
    var clipBottom: Bool = false // cross-midnight: continues into the next day → square bottom, bar to bottom edge
    var timeText: String? // the WHOLE event's range (every segment shows the true span, e.g. "23:00 – 06:00")
    var subTimeText: String? // anchor-zone time when it differs from the view (e.g. "12:00 – 14:00 (PST)")
    var plain: Bool = false // skip glass (animating, or tiny month sliver)
    let activation: EventActivation
    var badges: EventBadges = [] // provenance/kind marker glyphs (same as bands)
    var editing: Bool = false // the inline title editor is open over this box → hide its own title
    let theme: Theme

    var body: some View {
        let lay = eventTextLayout(height, hasSubline: subTimeText != nil)
        // A revealed hidden imported event reads as "off": a neutral gray fill + gray border/badges, with
        // ONLY the left (dotted) bar keeping the event's color as its identity.
        let hidden = badges.contains(.hidden)
        let barColor = theme.eventBorder(ev.color) // left bar — always colorful
        let border = hidden ? theme.textMuted : barColor // border + badge glyphs
        let color = hidden ? theme.text : theme.eventColor(ev.color) // glass / fill tint
        let r = BandStyle.cornerRadius
        let active = activation.isActive
        let tint = activation.tint * theme.eventTintScale
        let glass: Glass = (active || BandStyle.idleFrosted) ? .regular.tint(color.opacity(tint))
            : .clear.tint(color.opacity(tint))
        let barWidth = activation.accentWide ? BandStyle.accentWidthSelected : BandStyle.accentWidth
        // The left accent bar is a fixed-width vertical bar on every timed event, tall or short.
        // Normally inset top/bottom (accentInset) like a band; but on a short event the inset would
        // eat the bar, so shrink it toward 0 — a very short event's bar spans the full height.
        let barVInset = min(BandStyle.accentInset, max(0, (height - BandStyle.accentInset * 2) / 2))
        // Cross-midnight: square the corners on the edge the event continues over, and run the accent bar
        // flush to that edge (no inset) — the same "…continued" cue a band uses across a month boundary.
        let boxShape = UnevenRoundedRectangle(
            topLeadingRadius: clipTop ? 0 : r,
            bottomLeadingRadius: clipBottom ? 0 : r,
            bottomTrailingRadius: clipBottom ? 0 : r,
            topTrailingRadius: clipTop ? 0 : r
        )
        let barTopInset = clipTop ? 0 : barVInset
        let barBotInset = clipBottom ? 0 : barVInset
        VStack(alignment: .leading, spacing: showText ? -1 : 0) {
            // Month view (no title): markers sit in-flow at the top, same as bands. Week/day view
            // shows the title starting at the top — its markers are a top-right overlay (below), so
            // they don't push the title down.
            if !showText, !badges.isEmpty {
                badgeRow(badges, border)
            }
            if showText {
                Text(ev.title)
                    .font(.custom("Comic Sans MS", size: lay.tiny ? 10 : 13))
                    .foregroundStyle(theme.text)
                    .lineLimit(lay.titleLines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(editing ? 0 : 1) // hidden while the inline editor is open (keeps layout stable)
                if !(lay.short || lay.tiny) {
                    Text(timeText ?? fmtHourRange(ev.startHour, ev.endHour))
                        .font(.system(size: 8.5))
                        .foregroundStyle(theme.text.opacity(0.72))
                        .padding(.top, 2) // a touch more breathing room below the title
                    if let subTimeText, lay.subLine { // anchor-zone time — only when the block is tall enough
                        Text(subTimeText)
                            .font(.system(size: 8))
                            .foregroundStyle(theme.text.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, BandStyle.accentInset + barWidth + BandStyle.barTextGap)
        .padding(.trailing, BandStyle.titleTrailing)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .eventSurface(glass, plainFill: color.opacity(tint), in: boxShape, flat: plain && !active, keepFillBase: plain)
        .overlay(alignment: .topTrailing) { // week/day view: markers pinned to the top-right corner
            if showText, !badges.isEmpty {
                badgeRow(badges, border).padding(.top, 3).padding(.trailing, 4)
            }
        }
        .overlay(alignment: .leading) { // left accent bar — DOTTED + the ONLY colorful part when hidden
            Group {
                // The bar's caps are rounded on the event's REAL ends but flat (square) where it continues
                // over a midnight boundary (clipTop/clipBottom) — matching the box corners. A normal event
                // rounds both ends (equivalent to a capsule for a bar this thin).
                if hidden {
                    DottedBar(width: barWidth, color: barColor)
                } else {
                    let cap = barWidth / 2
                    UnevenRoundedRectangle(
                        topLeadingRadius: clipTop ? 0 : cap,
                        bottomLeadingRadius: clipBottom ? 0 : cap,
                        bottomTrailingRadius: clipBottom ? 0 : cap,
                        topTrailingRadius: clipTop ? 0 : cap
                    )
                    .fill(barColor).frame(width: barWidth)
                }
            }
            .padding(.top, barTopInset).padding(.bottom, barBotInset).padding(.leading, BandStyle.accentInset)
        }
        .overlay {
            if clipTop || clipBottom {
                // A cross-midnight segment: draw the selection/focus border on every side EXCEPT the
                // midnight continuation edge(s), so the internal boundary between two segments of one
                // event stays borderless (only the real outer sides get the thick border).
                segmentBorder(activation, color: border, radius: r, clipTop: clipTop, clipBottom: clipBottom)
            } else {
                activationBorder(activation, color: border, in: boxShape)
            }
        }
        .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }
}

/// Selection/focus border for a cross-midnight segment: same widths/dash as `activationBorder`, but on an
/// OPEN path that omits the midnight continuation edge(s).
@ViewBuilder
private func segmentBorder(_ activation: EventActivation, color: Color, radius: CGFloat, clipTop: Bool,
                           clipBottom: Bool) -> some View {
    let stroke: (w: CGFloat, dash: [CGFloat])? = switch activation {
    case .selected: (BandStyle.selectedBorderWidth, [])
    case .focusMain: (BandStyle.focusBorderWidth, [])
    case .accompanied: (BandStyle.accompaniedBorderWidth, BandStyle.accompaniedDash)
    case .hover, .plain: nil
    }
    if let s = stroke {
        OpenBorderShape(radius: radius, clipTop: clipTop, clipBottom: clipBottom, inset: s.w / 2)
            .stroke(color, style: StrokeStyle(lineWidth: s.w, lineCap: .butt, lineJoin: .round, dash: s.dash))
    }
}

/// The outline of a rounded rect with the clipped (continuation) edge(s) removed — an OPEN path tracing
/// only the sides that aren't a midnight boundary. Closed sides are inset by half the stroke so the stroke
/// sits inside the box (like strokeBorder); the vertical sides run to the full open edge.
private struct OpenBorderShape: Shape {
    var radius: CGFloat
    var clipTop: Bool
    var clipBottom: Bool
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX + inset, x1 = rect.maxX - inset
        let rad = max(0, min(radius, min(rect.width, rect.height) / 2 - inset))
        var p = Path()
        if clipTop && clipBottom { // middle day of a 3+ day span → the two sides only
            p.move(to: CGPoint(x: x0, y: rect.minY)); p.addLine(to: CGPoint(x: x0, y: rect.maxY))
            p.move(to: CGPoint(x: x1, y: rect.minY)); p.addLine(to: CGPoint(x: x1, y: rect.maxY))
        } else if clipBottom { // open bottom → up the left, rounded top, down the right
            let yTop = rect.minY + inset
            p.move(to: CGPoint(x: x0, y: rect.maxY))
            p.addLine(to: CGPoint(x: x0, y: yTop + rad))
            p.addQuadCurve(to: CGPoint(x: x0 + rad, y: yTop), control: CGPoint(x: x0, y: yTop))
            p.addLine(to: CGPoint(x: x1 - rad, y: yTop))
            p.addQuadCurve(to: CGPoint(x: x1, y: yTop + rad), control: CGPoint(x: x1, y: yTop))
            p.addLine(to: CGPoint(x: x1, y: rect.maxY))
        } else { // clipTop → open top: down the left, rounded bottom, up the right
            let yBot = rect.maxY - inset
            p.move(to: CGPoint(x: x0, y: rect.minY))
            p.addLine(to: CGPoint(x: x0, y: yBot - rad))
            p.addQuadCurve(to: CGPoint(x: x0 + rad, y: yBot), control: CGPoint(x: x0, y: yBot))
            p.addLine(to: CGPoint(x: x1 - rad, y: yBot))
            p.addQuadCurve(to: CGPoint(x: x1, y: yBot - rad), control: CGPoint(x: x1, y: yBot))
            p.addLine(to: CGPoint(x: x1, y: rect.minY))
        }
        return p
    }
}

// ── Deadline labels: SwiftUI glass pills above the Canvas moment-line ─────────────────
// The horizontal moment line + end dots are drawn in the Canvas (SceneRenderer.drawMid); this
// renders the LABEL as a glass pill with the SAME five activation levels as events (tint by level;
// border: none for plain/hover, solid focus-main, dashed accompanied, thick selected). The line
// itself never dashes — selection styling lives entirely on the pill.
struct DeadlinesOverlay: View {
    let input: SceneInput
    let deadlines: [Deadline]
    var sides: [String: Bool] = [:] // offline side assignment (id → onLeft); base for each label
    let selected: String?
    var selectedIds: Set<String> = [] // the FULL multi-selection (each member gets a focus ring)
    let hovered: String?
    let drawerOpen: Bool
    var only: String? // lifted copy → render ONLY this deadline's tag (sharp, above the scrim)
    var hide: String? // blurred main scene → SKIP this tag (it's drawn sharp in the lift)
    let theme: Theme

    private func activation(_ id: String) -> EventActivation {
        // Every box is independent — only the EXACT selected box is highlighted (no series-wide
        // "accompanied" highlight), so selecting a promoted band / one occurrence doesn't light up its
        // siblings or its source event. Multi-select gives every member a focus ring.
        if selectedIds.contains(id) {
            return (selectedIds.count == 1 && drawerOpen) ? .selected : .focusMain
        }
        if id == selected {
            return drawerOpen ? .selected : .focusMain
        }
        if id == hovered {
            return .hover
        }
        return .plain
    }

    /// Per-label content + geometry (both possible sides). The base side comes from `sides`; the
    /// rendered pill matches the hit-test because both use the same base + flip rule.
    private struct Spec: Identifiable {
        let id: String; let info: DeadlineLabelInfo; let color: String; let fade: Double
    }

    private func specs(focus: Int, anim: PageAnim?, fadeMul: CGFloat) -> [Spec] {
        let tl = timelineInfo(input, focus: focus, anim: anim)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return [] }
        var gf = input; gf.focus = focus
        var out: [Spec] = []
        for d in deadlines {
            if let only, d.id != only {
                continue
            }
            if let hide, d.id == hide {
                continue
            }
            guard let pos = deadlinePos(d, input, focus: focus, anim: anim) else { continue }
            let rd = relDomOf(input.year, focus, d.year, d.month, d.day) ?? -999
            let spill = (input.z >= 1.5) ? spillFactor(d.month, gf, dim: EventsOverlay.spilloverDim) : 1
            let fade = dailyFade(rd, gf) * tl.reveal * fadeMul * spill
            if fade <= 0.02 {
                continue
            }
            out.append(Spec(
                id: d.id,
                info: deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, input),
                color: d.color,
                fade: Double(fade)
            ))
        }
        return out
    }

    var body: some View {
        let anim = input.monthAnim
        let clipRight = dashboardLeftAnimated(input) // day-view dashboard mask (slides in from the right)
        let outMul = anim.map { outgoingDetailReveal($0.p) } ?? 1
        ZStack(alignment: .topLeading) {
            pillLayer(focus: input.focus, anim: anim, fadeMul: outMul, clipRight: clipRight)
            if let anim {
                let to = input.focus + anim.dir
                if to >= 0, to <= 11 {
                    pillLayer(
                        focus: to,
                        anim: anim,
                        fadeMul: incomingDetailReveal(anim.p),
                        clipRight: clipRight
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func pillLayer(focus: Int, anim: PageAnim?, fadeMul: CGFloat,
                                        clipRight: CGFloat) -> some View {
        let tl = timelineInfo(input, focus: focus, anim: anim)
        let H = DeadlineLabel.height
        let all = specs(focus: focus, anim: anim, fadeMul: fadeMul)
        // The raised label (hovered / selected); neighbours only yield when its cursor LINE would cross
        // them. Pure label-label overlap is fine — the raised label just occludes the other.
        let topSpec = all.max { activation($0.id).z < activation($1.id).z }
        let topLine: CGRect? = topSpec.flatMap { t in
            activation(t.id).z > 0 ? CGRect(
                x: t.info.lineX - 4,
                y: t.info.lineY - 5,
                width: t.info.colW + 8,
                height: 10
            ) : nil
        }
        let topId = topSpec?.id
        ZStack(alignment: .topLeading) {
            ForEach(all) { s in
                let a = activation(s.id)
                let base = sides[s.id] ?? s.info.defaultOnLeft // offline assignment (fallback: default)
                // Flip to the other side only when the raised deadline's LINE would cross this label —
                // but never in day view, where labels always stay on the left of the single day column.
                let flip = input.z <= 2 && topId != nil && topId != s.id && topLine
                    .map { s.info.rect(onLeft: base).intersects($0) } == true
                let onLeft = flip ? !base : base
                let rect = s.info.rect(onLeft: onLeft)
                DeadlinePill(title: s.info.title, timeLine: s.info.timeLine, color: theme.eventBorder(s.color),
                             activation: a, onLeft: onLeft, width: rect.width, height: rect.height, theme: theme)
                    .opacity(s.fade)
                    .position(x: rect.midX, y: rect.midY)
                    .zIndex(a.z) // hovered/selected label rises above overlapping neighbors
                    .animation(.easeInOut(duration: 0.2), value: onLeft) // slide + caret-swap on flip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Clip vertically to the timeline (so a deadline scrolled out of view hides its label);
        // horizontal is generous so a side-placed pill/caret isn't cut.
        .clipShape(RectClip(rect: CGRect(
            x: -Layout.labelW,
            y: tl.tlTop - H,
            width: input.vp.w + 2 * Layout.labelW,
            height: (tl.tlBottom - tl.tlTop) + 2 * H
        )))
    }
}

/// One deadline label: a two-line glass pill (title over time+timezone) sized like a band event,
/// tinted + bordered by its activation level, with a caret pointing into the moment line.
private struct DeadlinePill: View {
    let title: String
    let timeLine: String
    let color: Color
    let activation: EventActivation
    let onLeft: Bool // pill sits left of the column → caret/border on its RIGHT edge (points in)
    let width: CGFloat
    let height: CGFloat
    let theme: Theme
    var body: some View {
        let r: CGFloat = 10
        let shape = RoundedRectangle(cornerRadius: r)
        VStack(alignment: .leading, spacing: -1) {
            Text(title).font(.custom("Comic Sans MS", size: 12)).foregroundStyle(theme.text).lineLimit(1)
            Text(timeLine).font(.system(size: 10, weight: .semibold)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .frame(width: width, height: height, alignment: .leading)
        // Opaque base UNDER the frosted glass (like the event stickers) so the label reads as a solid
        // frosted pill in front of the timeline, not a translucent tint you can see through.
        .background {
            ZStack {
                shape.fill(theme.bg) // occludes the timeline behind → the frost reads solid
                Color.clear.glassEffect(.regular.tint(color.opacity(activation.tint * theme.eventTintScale)), in: shape)
            }
        }
        // Edge accent (border + caret) on the line-facing side; the other side stays collapsed. On a
        // flip the old caret retracts into the pill edge while the new one grows from the opposite side.
        .overlay { sideEdge(pointsRight: true, shown: onLeft, r: r) }
        .overlay { sideEdge(pointsRight: false, shown: !onLeft, r: r) }
        .overlay { activationBorder(activation, color: color, in: RoundedRectangle(cornerRadius: r)) }
        .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }

    private func sideEdge(pointsRight: Bool, shown: Bool, r: CGFloat) -> some View {
        ZStack {
            SideBorder(pointsRight: pointsRight, radius: r).strokeBorder(color, lineWidth: 1)
            Caret(pointsRight: pointsRight).fill(color)
                .frame(width: 6, height: 11)
                .scaleEffect(x: shown ? 1 : 0, anchor: pointsRight ? .leading : .trailing) // grow/retract at the edge
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointsRight ? .trailing : .leading)
                .offset(x: pointsRight ? 6 : -6)
        }
        .opacity(shown ? 1 : 0)
    }
}

/// One rounded side of a pill — the vertical edge plus its two corner arcs — for a colored border
/// that hugs the caret's side (covering the corners, unlike a straight bar).
private struct SideBorder: InsettableShape {
    let pointsRight: Bool
    let radius: CGFloat
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> SideBorder {
        var s = self; s.inset += amount; return s
    }

    func path(in rectIn: CGRect) -> Path {
        var p = Path()
        let rect = rectIn.insetBy(dx: inset, dy: inset)
        let r = radius - inset // keep the arcs riding the (inset) rounded corner
        // Just 45° of each corner (the half nearest the vertical edge), so the border only nudges
        // into the corners rather than wrapping them fully.
        if pointsRight {
            p.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                radius: r,
                startAngle: .degrees(-45),
                endAngle: .degrees(0),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(45),
                clockwise: false
            )
        } else {
            p.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(135),
                endAngle: .degrees(180),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(225),
                clockwise: false
            )
        }
        return p
    }
}

/// A small triangular caret pointing toward a line (deadline moment line / now-line).
private struct Caret: Shape {
    let pointsRight: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsRight {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// A horizontal row of the event's provenance/kind marker glyphs (shared by the in-flow month
/// layout and the week/day top-right overlay).
/// A vertical DOTTED accent bar (round dots down a line), used in place of the solid accent bar to mark
/// a revealed hidden imported event. Dot diameter = `width`; spacing ≈ 2.2× so the dots read as dotted.
private struct DottedBar: View {
    let width: CGFloat
    let color: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: width / 2, y: width / 2))
                p.addLine(to: CGPoint(x: width / 2, y: max(width, geo.size.height - width / 2)))
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.01, width * 2.2]))
        }
        .frame(width: width)
    }
}

private func badgeRow(_ badges: EventBadges, _ color: Color) -> some View {
    HStack(spacing: 2) {
        ForEach(badgeSymbols(badges), id: \.self) { sym in
            Image(systemName: sym).font(.system(size: 6.5, weight: .bold))
        }
    }
    .foregroundStyle(color)
}

/// SF Symbol glyphs for an event's provenance/kind markers, in a stable left→right order.
private func badgeSymbols(_ b: EventBadges) -> [String] {
    var s: [String] = []
    if b.contains(.recurrent) {
        s.append("repeat")
    }
    if b.contains(.promoted) {
        s.append("pin.fill")
    }
    if b.contains(.ai) {
        s.append("sparkles")
    }
    if b.contains(.imported) {
        s.append("square.and.arrow.down")
    }
    return s
}

/// The per-activation border overlay shared by both stickers: normal solid (focus), dashed
/// (accompanied sibling), thick solid (selected/drawer); nothing for hover/plain.
@ViewBuilder
private func activationBorder<S: InsettableShape>(_ activation: EventActivation, color: Color,
                                                  in shape: S) -> some View {
    switch activation {
    case .selected:
        shape.strokeBorder(color, lineWidth: BandStyle.selectedBorderWidth)
    case .focusMain:
        shape.strokeBorder(color, lineWidth: BandStyle.focusBorderWidth)
    case .accompanied:
        shape.strokeBorder(
            color,
            style: StrokeStyle(lineWidth: BandStyle.accompaniedBorderWidth, dash: BandStyle.accompaniedDash)
        )
    case .hover, .plain:
        EmptyView()
    }
}

/// An all-day band: a frosted liquid-glass rounded rect tinted with the event color.
/// Hover fades the fill slightly; single-select adds a thin dotted border; an open
/// drawer (double-click) makes it a solid, thicker border.
private struct BandSticker: View {
    let ev: BandEvent
    let activation: EventActivation
    let editing: Bool
    let gap: CGFloat? // px to the nearest later-starting bar (title clips before it)
    let clipBox: Bool // clip title to this box's right edge (shorter same-start bar on top)
    let clipStart: Bool // band started before the viewport's left edge → square left, no accent bar
    let clipEnd: Bool // band ends after the viewport's right edge → square right corners
    let warn: Bool // fully-overlapping-events warning (this is the kept band)
    let box: CGSize // band box size (for scrim geometry)
    var badges: EventBadges = [] // provenance/kind marker glyphs at the bottom of the bar
    var plain: Bool = false // skip glass while animating (page-turn/pinch) — cheaper per frame
    let theme: Theme

    var body: some View {
        let border = theme.eventBorder(ev.color)
        let color = theme.eventColor(ev.color)
        let r = BandStyle.cornerRadius
        let active = activation.isActive
        let tint = activation.tint * theme.eventTintScale
        let glass: Glass = (active || BandStyle.idleFrosted) ? .regular.tint(color.opacity(tint))
            : .clear.tint(color.opacity(tint))
        let barWidth = activation.accentWide ? BandStyle.accentWidthSelected : BandStyle.accentWidth
        // Clipped edges (band runs off-screen): square off that side's corners so it reads as continuing
        // past the viewport. A left clip also drops the accent bar and pulls the title in a touch, since
        // the bar's width no longer occupies the lead.
        let leftR: CGFloat = clipStart ? 0 : r
        let rightR: CGFloat = clipEnd ? 0 : r
        let bandShape = UnevenRoundedRectangle(topLeadingRadius: leftR, bottomLeadingRadius: leftR,
                                               bottomTrailingRadius: rightR, topTrailingRadius: rightR,
                                               style: .circular)
        let lead = clipStart ? BandStyle.accentInset + BandStyle.barTextGap
            : BandStyle.accentInset + barWidth + BandStyle.barTextGap

        // Only the FOCUSED box (exact click / drawer, or a lone hover) un-truncates to full overflow —
        // NOT the accompanied siblings of a selected series, which stay clipped like normal bars so
        // just the one main title spills. Otherwise: a shorter same-start bar (on top) clips to its
        // own box; everyone else clips before the next later bar (unbounded when none).
        let expanded = activation.expandsTitle
        let clip: CGFloat? = expanded ? nil
            : (clipBox ? max(0, box.width - lead - BandStyle.titleTrailing) : gap.map { max(12, $0 - 10) })
        // Spill scrim (focused box only): the part of the full title past the box's right edge, when
        // it overruns something behind it — a longer same-start bar (clipBox) or a later bar.
        // A dark plate occludes that bar's text so the spilled title stays readable.
        let titleEnd = lead + Self.titleWidth(ev.title)
        let spill = max(0, titleEnd + 9 - box.width)
        let maskW: CGFloat = (expanded && spill > 0 && (clipBox || (gap != nil && gap! < titleEnd))) ? spill : 0

        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .eventSurface(
                glass,
                plainFill: color.opacity(tint),
                in: bandShape,
                flat: plain && !active,
                keepFillBase: plain
            )
            // Spill scrim: a frosted plate of THIS event's color that sits UNDER the box, shares its
            // two left corners (same radius), and extends right to cover the full un-truncated title.
            // Under the box it's hidden by the glass; past the box it occludes the bar behind the
            // spill. A single rounded rect → no triangular gap at the box's rounded right corner.
            .background(alignment: .leading) {
                if maskW > 0 {
                    let shape = bandShape
                    Rectangle().fill(theme.bg.opacity(0.55)) // base occlusion under the frost
                        .frame(width: box.width + maskW, height: box.height)
                        .glassEffect(.regular.tint(color.opacity(BandStyle.tintIdle * theme.eventTintScale)), in: shape)
                        .clipShape(shape)
                }
            }
            .overlay(alignment: .leading) { // accent bar — omitted when the band starts off-screen left
                if !clipStart {
                    Capsule().fill(border).frame(width: barWidth)
                        .padding(.vertical, BandStyle.accentInset).padding(.leading, BandStyle.accentInset)
                }
            }
            .overlay(alignment: .leading) { // markers (top) + title, as one vertically-centered block
                if !editing {
                    VStack(alignment: .leading, spacing: -3) { // negative → pull the title up tight under the icons
                        if !badges.isEmpty {
                            HStack(spacing: 2) {
                                ForEach(badgeSymbols(badges), id: \.self) { sym in
                                    Image(systemName: sym).font(.system(size: 6.5, weight: .bold))
                                }
                            }
                            .foregroundStyle(border)
                        }
                        titleView(clip: clip)
                    }
                    .padding(.leading, lead)
                    .allowsHitTesting(false)
                }
            }
            .overlay { activationBorder(activation, color: border, in: bandShape) } // level-specific border
            .overlay(alignment: .topLeading) { // fully-overlapping warning
                if warn {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                        .padding(.leading, 2).padding(.top, 1)
                        .help("Fully overlapping events")
                }
            }
            .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }

    @ViewBuilder private func titleView(clip: CGFloat?) -> some View {
        let t = Text(ev.title)
            .font(.custom("Comic Sans MS", size: BandStyle.titleSize))
            .foregroundStyle(theme.text)
            .lineLimit(1)
        if let clip {
            t.truncationMode(.tail).frame(width: clip, alignment: .leading)
        } else {
            t.fixedSize()
        }
    }

    static func titleWidth(_ s: String) -> CGFloat {
        let f = NSFont(name: "Comic Sans MS", size: BandStyle.titleSize) ?? NSFont
            .systemFont(ofSize: BandStyle.titleSize)
        return (s as NSString).size(withAttributes: [.font: f]).width
    }
}

/// Clips content to an absolute rectangle in the parent's coordinate space.
struct RectClip: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path {
        Path(rect)
    }
}

/// Frame-to-frame cache of the anchor-timezone sublabels (see timedItems). The key carries
/// everything the label depends on; a nil value ("no label") is cached too.
@MainActor private var subLabelCache: [SubLabelKey: String?] = [:]
private struct SubLabelKey: Hashable {
    let id: String
    let start: CGFloat
    let end: CGFloat
    let anchorTz: String
    let mainTz: String
}

/// Frame-to-frame cache of a month's segment grouping + per-day overlap packing — the parts of
/// timedItems that DON'T depend on the per-frame timeline geometry. With the neighbor months
/// mounted, timedItems runs 3× per frame and full re-packing was the hottest app symbol in the
/// swipe profile; positions (eventRect) stay per-frame, so nothing visual changes.
@MainActor private var timedLayoutCache: [TimedLayoutKey: [TimedDayLayout]] = [:]
struct TimedLayoutKey: Hashable {
    let year: Int
    let focus: Int
    let editGen: UInt64
    let dragging: String?
}

struct TimedDayLayout {
    let rd: Int
    let segs: [TimedSegment]
    let layout: [String: EventLayout]
}
