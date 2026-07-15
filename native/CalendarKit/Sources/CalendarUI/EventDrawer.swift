// Detail drawer — a floating, rounded native "card" on the trailing edge (Apple sidebar look).
// Content is a compact, unified configuration form ported from the web drawer: title, when
// (date/time per kind), color, tags, repeat, and promote/lane — all as native segmented
// controls / pickers. The markdown notes editor and imported/detach actions are deferred.

import SwiftUI
import CalendarGeometry
import CalendarEngine

@MainActor
@Observable
public final class CalendarUIState {
    public var openEventId: String?
    public var editingTrack: TrackEdit?   // inline track-name editor target
    public var editingBand: BandEdit?     // inline band-title editor target
    public init() {}
}

/// Target for the inline track-name editor: which month + track, and where (geometry rect).
public struct TrackEdit: Equatable { public var month: Int; public var track: Int; public var rect: CGRect }
/// Target for the inline band-title editor: which band id, and where (geometry rect).
public struct BandEdit: Equatable { public var id: String; public var rect: CGRect }

private enum ItemKind2 { case timed, band, deadline }
private enum WhenField: Hashable { case date, start, end }   // which "when" part is being edited inline
private enum NoteScope: Hashable { case series, occurrence }  // recurring: shared note vs this-occurrence note
private let DOW = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]

/// A wrapping flow layout: places subviews left→right, wrapping to a new row when the next one
/// wouldn't fit the proposed width. Used so tag pills reflow onto multiple rows.
private struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { widest = max(widest, x - spacing); x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + lineSpacing; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

struct EventDrawer: View {
    let engine: CalendarEngine
    let id: String
    @Binding var width: CGFloat
    let containerWidth: CGFloat   // window width — the drawer may not grow past it
    let theme: Theme
    let onClose: () -> Void

    @State private var kind: ItemKind2 = .timed
    @State private var title = ""
    @State private var color = "blue"
    @State private var resizeStart: CGFloat?
    @State private var resizeHover = false
    @State private var whenEditing: WhenField?      // which "when" part currently shows its editor
    @FocusState private var whenFocus: WhenField?   // focuses the shown editor
    // Fixed native date-field height (the text parts reserve it so activating a field doesn't reflow).
    // A live measurement churns @State mid-entrance-transition, which makes the "when" row snap to its
    // destination instead of sliding with the drawer — so it's a constant, tunable if a field clips.
    private let whenRowH: CGFloat = 22
    // when (mirrors the item; re-synced from the engine after each edit)
    @State private var itemYear = 2026
    @State private var month = 0
    @State private var day = 1
    @State private var start: CGFloat = 9
    @State private var end: CGFloat = 10
    @State private var startDay = 1
    @State private var endDay = 1
    @State private var track = 0
    @State private var hour: CGFloat = 12
    // config
    @State private var tags: [String] = []
    @State private var rep = Repeat(kind: "none")
    @State private var promote: Int?
    @State private var addingTag = false
    @State private var tagDraft = ""
    @State private var hoveredTag: String?           // tag chip under the cursor (hover highlight)
    @FocusState private var tagFocused: Bool
    @State private var configOpen = false           // the Configuration disclosure (collapsed by default)
    @State private var notes = ""            // series note (all events)
    @State private var occNote = ""          // this-occurrence note (recurring)
    @State private var occKey = ""           // focused occurrence box id (key for occNote)
    @State private var noteScope: NoteScope = .series
    @State private var notesMode: NotesMode = .edit
    @State private var showDeleteConfirm = false
    @State private var settled = false   // true once the slide-in finishes → fade in native controls

    private var recurring: Bool { rep.kind != "none" }
    /// The note the editor is bound to right now: the occurrence note only when recurring + selected.
    private var activeNote: Binding<String> { (recurring && noteScope == .occurrence) ? $occNote : $notes }

    private let minWidth: CGFloat = 410   // wide enough that expanding Configuration doesn't force a resize
    private var maxWidth: CGFloat { min(760, max(minWidth, containerWidth - margin)) }
    private let topInset: CGFloat = 52
    private let margin: CGFloat = 10
    private let cornerRadius: CGFloat = 16
    // ── Tunable layout spacing ────────────────────────────────────────────────────
    private let contentPad: CGFloat = 18        // left/right/top inset for the top group + notes editor
    private let configBottomGap: CGFloat = 0   // gap under the Configuration box (before the editor)
    private let editorVPad: CGFloat = 8         // vertical inset around the notes editor
    private let footHPad: CGFloat = 16          // foot row horizontal inset
    private let footTopPad: CGFloat = 7         // space above the toggle / delete row
    private let footBottomPad: CGFloat = 14     // space below it (raises it off the card's bottom edge)
    private let base = Calendar.current.startOfDay(for: Date())

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        HStack(spacing: 0) { resizeHandle; card }
            .padding(.top, topInset)
            .padding(.trailing, margin)
            .padding(.bottom, margin)
            // Red accent scoped to the drawer's native controls (pickers, date fields, disclosure,
            // toggles) — kept off the toolbar so its glass buttons stay neutral.
            .tint(Color(hex: 0xff3b6b))
            .onAppear {
                load()
                // Native controls (pickers, the notes WebView) can't ride the slide transition, so
                // fade them in once the drawer has arrived rather than letting them snap into place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.18)) { settled = true }
                }
            }
            .onDisappear { engine.clearColorPreview() }   // drop any lingering swatch preview
            .onChange(of: notes) { _, v in engine.setNotes(id, v) }
            .onChange(of: occNote) { _, v in engine.setOccNote(id, occKey, v) }
            .onChange(of: noteScope) { _, s in   // open each note in the sensible view
                let c = s == .occurrence ? occNote : notes
                notesMode = c.isEmpty ? .edit : .preview
            }
            .onChange(of: containerWidth) { _, _ in width = min(width, maxWidth) }
            .id(id)
    }

    private var card: some View {
        VStack(spacing: 0) {
            // Top: title / when / color / configuration (compact — Configuration collapses by default).
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    titleField
                    whenControls
                    colorSwatches
                }
                configBox
            }
            .padding(.horizontal, contentPad).padding(.top, contentPad).padding(.bottom, configBottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Tapping empty top-area space ends any inline "when" edit (macOS won't resign a focused
            // DatePicker when a non-text control / blank area is clicked).
            .onTapGesture { endWhenEdit() }

            // Notes markdown editor (WKWebView) fills the remaining space. Horizontal padding of 18
            // matches the top content so the text left/right edges line up (internal CSS padding is 0).
            MarkdownWebEditor(text: activeNote, mode: $notesMode, theme: theme)
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .padding(.horizontal, contentPad).padding(.vertical, editorVPad)

            footRow
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        // Opaque base so the dim outside-click scrim behind the card can't grey it through —
        // the drawer reads fully bright and pops against the darkened calendar. Light mode uses
        // pure white (the frosted material added a faint grey cast); dark mode keeps the frosted
        // material over the solid background for depth.
        .background(cardShape.fill(theme.dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.white)))
        .background(cardShape.fill(theme.bg))
        .overlay { cardShape.strokeBorder(theme.text.opacity(0.12), lineWidth: 1) }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle()).padding(8)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        // Resign-based fallback: if the shown field loses first responder (Tab/Enter, or clicking
        // the title/tag field) and nothing else re-focuses, drop back to text. Deferred so a
        // field-to-field switch (which briefly nils focus) isn't torn down.
        .onChange(of: whenFocus) { _, f in
            if f == nil { DispatchQueue.main.async { if whenFocus == nil { whenEditing = nil } } }
        }
    }

    private func endWhenEdit() { whenEditing = nil; whenFocus = nil }

    // ── Configuration disclosure (macOS Settings-style grouped box) ────────────────
    /// A collapsed-by-default rounded box: native DisclosureGroup for the collapse, holding the
    /// advanced controls (tags / repeat / promote) split by full-margin dividers.
    private var configBox: some View {
        DisclosureGroup(isExpanded: $configOpen) {
            VStack(alignment: .leading, spacing: 0) {
                configItem("Tags") { tagsControls }
                configDivider
                configItem("Repeat") { repeatControls }
                configDivider
                configItem(kind == .band ? "Lane" : "Promote") { laneOrPromoteControls }
            }
            .padding(.bottom, 6)
        } label: {
            // Full-width, vertically-padded header so clicking anywhere across the title row —
            // including a little above/below it — toggles the disclosure (not just the triangle).
            HStack {
                Text("Configuration").font(.callout.weight(.medium)).foregroundStyle(theme.text)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { configOpen.toggle() } }
        }
        .padding(.horizontal, 12)
        .background(theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.text.opacity(0.08), lineWidth: 1) }
    }

    /// Row separator inside the config box — theme text colour so it stays light on dark, with
    /// breathing room above and below the line.
    private var configDivider: some View {
        Rectangle().fill(theme.text.opacity(0.14)).frame(height: 1).padding(.vertical, 6)
    }

    /// One captioned row inside the box, with top/bottom margin so the dividers breathe.
    private func configItem<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased()).font(.caption2).tracking(0.7).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    private var titleField: some View {
        TextField("Untitled", text: $title)
            .textFieldStyle(.plain)
            .font(.custom("Comic Sans MS", size: 20).weight(.bold))
            .foregroundStyle(theme.text)
            .padding(.trailing, 26)
            .onHover { $0 ? NSCursor.iBeam.set() : NSCursor.arrow.set() }
            .onChange(of: title) { _, v in commitTitle(v) }
    }

    private var colorSwatches: some View {
        HStack(spacing: 8) {
            ForEach(EVENT_COLORS, id: \.self) { key in
                Circle()
                    .fill(theme.eventBorder(key))
                    .frame(width: 17, height: 17)
                    .overlay(Circle().strokeBorder(theme.text, lineWidth: key == color ? 2 : 0))
                    .contentShape(Circle())
                    .onHover { hovering in
                        if hovering { engine.setColorPreview(id, key) } else { engine.clearColorPreview(key) }
                    }
                    .onTapGesture { endWhenEdit(); color = key; commitColor(key) }
            }
        }
    }

    /// One tappable "when" part: plain text (sized to the text) until clicked; then it swaps to a
    /// focused native `.field` DatePicker. `whenEditing` drives visibility — the editor renders only
    /// while active (so the text isn't padded to the field's width) and grabs focus on appear.
    private func whenPart<E: View>(_ field: WhenField, _ text: String, @ViewBuilder _ editor: () -> E) -> some View {
        // Both states occupy the same (measured) field height so activating the editor never
        // shifts the drawer's layout.
        Group {
            if whenEditing == field {
                editor()
                    .labelsHidden().datePickerStyle(.field)
                    .focused($whenFocus, equals: field)
                    .fixedSize()
                    .onAppear { whenFocus = field }
            } else {
                Text(text)
                    .foregroundStyle(theme.text)
                    .contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.iBeam.set() : NSCursor.arrow.set() }
                    .onTapGesture { whenEditing = field }
            }
        }
        .frame(height: whenRowH, alignment: .leading)
    }

    private func dateStr(_ d: Int) -> String { "\(month + 1)/\(d)/\(itemYear)" }
    private var dateText: String { dateStr(day) }
    private func timeText(_ h: CGFloat) -> String {
        let hh = min(23, Int(h)); let mm = Int((h - floor(h)) * 60)
        return String(format: "%d:%02d", hh, mm)
    }

    @ViewBuilder private var whenControls: some View {
        switch kind {
        case .timed:
            // Read-only text until a part is clicked; then just that part becomes a focused native
            // field, reverting to text when focus leaves (click elsewhere).
            HStack(spacing: 5) {
                whenPart(.date, dateText) { DatePicker("", selection: dateBinding, displayedComponents: .date) }
                Text(",").foregroundStyle(.secondary)
                whenPart(.start, timeText(start)) { DatePicker("", selection: timeBinding({ start }, setStart), displayedComponents: .hourAndMinute) }
                Text("–").foregroundStyle(.secondary)
                whenPart(.end, timeText(end)) { DatePicker("", selection: timeBinding({ end }, setEnd), displayedComponents: .hourAndMinute) }
                Spacer(minLength: 0)
            }
            .font(.callout)
        case .band:
            HStack(spacing: 5) {
                whenPart(.start, dateStr(startDay)) { DatePicker("", selection: bandDayBinding(true), in: monthRange, displayedComponents: .date) }
                Text("–").foregroundStyle(.secondary)
                whenPart(.end, dateStr(endDay)) { DatePicker("", selection: bandDayBinding(false), in: monthRange, displayedComponents: .date) }
                Spacer(minLength: 0)
            }
            .font(.callout)
        case .deadline:
            HStack(spacing: 5) {
                whenPart(.date, dateText) { DatePicker("", selection: ddlDateBinding, displayedComponents: .date) }
                Text(",").foregroundStyle(.secondary)
                whenPart(.start, timeText(hour)) { DatePicker("", selection: timeBinding({ hour }, setDdlHour), displayedComponents: .hourAndMinute) }
                Spacer(minLength: 0)
            }
            .font(.callout)
        }
    }

    // ── Tags ──────────────────────────────────────────────────────────────────────
    private var tagsControls: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { t in tagChip(t) }
            if addingTag {
                TextField("tag", text: $tagDraft)
                    .textFieldStyle(.plain).font(.caption).frame(width: 56)
                    .focused($tagFocused)
                    .onSubmit(addTag)
                    .onExitCommand { addingTag = false; tagDraft = "" }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .overlay(dashedPill)
            } else {
                Button { endWhenEdit(); addingTag = true; tagFocused = true } label: {
                    Text("+ Tag").font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .overlay(dashedPill)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Dashed pill outline for the "+ Tag" affordance (and its inline input), matching the web.
    private var dashedPill: some View {
        Capsule().strokeBorder(theme.text.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }

    private func tagChip(_ t: String) -> some View {
        let hovered = hoveredTag == t
        return HStack(spacing: 3) {
            Text("#\(t)").font(.caption)
            Button { removeTag(t) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .opacity(hovered ? 0.9 : 0.4)   // the × steps forward on hover
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(theme.text.opacity(hovered ? 0.16 : 0.08), in: Capsule())
        .foregroundStyle(theme.text)
        .onHover { h in if h { hoveredTag = t } else if hoveredTag == t { hoveredTag = nil } }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    // ── Repeat ────────────────────────────────────────────────────────────────────
    private var repeatControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: repKind) {
                Text("None").tag("none"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly")
                Text("Weekdays").tag("weekdays"); Text("Yearly").tag("yearly")
            }
            .pickerStyle(.segmented).labelsHidden()

            if rep.kind == "weekly" || rep.kind == "weekdays" {
                HStack(spacing: 6) {
                    Text("every").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: repN) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
                        .labelsHidden().frame(width: 58)
                    Text((rep.n ?? 1) > 1 ? "weeks" : "week").font(.caption).foregroundStyle(.secondary)
                }
            }
            if rep.kind == "weekdays" {
                HStack(spacing: 4) { ForEach(0..<7, id: \.self) { weekdayButton($0) } }
            }
            if rep.kind != "none" {
                HStack(spacing: 8) {
                    Text("until").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: untilOn) { Text("None").tag(false); Text("Date").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 118)
                    if rep.until != nil {
                        DatePicker("", selection: untilDate, displayedComponents: .date).labelsHidden()
                    }
                }
            }
        }
    }

    private func weekdayButton(_ i: Int) -> some View {
        let sel = (rep.days ?? [anchorDow]).contains(i)
        let locked = i == anchorDow
        return Button { toggleDay(i) } label: {
            Text(DOW[i]).font(.caption2)
                .frame(width: 27, height: 24)
                .background(sel ? theme.eventBorder(color).opacity(locked ? 0.5 : 0.9) : theme.text.opacity(0.06),
                           in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(sel ? .white : theme.text)
        }
        .buttonStyle(.plain).disabled(locked)
    }

    // ── Promote / Lane ──────────────────────────────────────────────────────────────
    @ViewBuilder private var laneOrPromoteControls: some View {
        if kind == .band {
            Picker("", selection: lane) { ForEach(0..<4, id: \.self) { Text("T\($0 + 1)").tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
        } else {
            HStack(spacing: 8) {
                Picker("", selection: promoteOn) { Text("No").tag(false); Text("Yes").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 108)
                if promote != nil {
                    Picker("", selection: promoteLane) { ForEach(0..<4, id: \.self) { Text("T\($0 + 1)").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
            }
        }
    }

    // Foot: notes edit/preview toggle, a series/occurrence note toggle (recurring only), then delete.
    private var footRow: some View {
        HStack(spacing: 10) {
            Picker("", selection: $notesMode) {
                Image(systemName: "pencil").tag(NotesMode.edit)
                Image(systemName: "eye").tag(NotesMode.preview)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .opacity(settled ? 1 : 0)
            if recurring {
                Picker("", selection: $noteScope) {
                    Text("All Events").tag(NoteScope.series)
                    Text("This Event").tag(NoteScope.occurrence)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .opacity(settled ? 1 : 0)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Image(systemName: "trash").font(.system(size: 14))
            }
            .buttonStyle(.plain).foregroundStyle(theme.eventBorder("red"))
            // Careful delete: recurring events pick a scope (matches the web); others confirm once.
            .confirmationDialog(recurring ? "Delete recurring event?" : "Delete this event?",
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                if recurring {
                    Button("This event only") { engine.deleteOccurrence(id, occKey); onClose() }
                    Button("This & all future") { engine.deleteFuture(id, occKey); onClose() }
                    Button("All events", role: .destructive) { engine.remove(id); onClose() }
                } else {
                    Button("Delete", role: .destructive) { engine.remove(id); onClose() }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
        .padding(.horizontal, footHPad).padding(.top, footTopPad).padding(.bottom, footBottomPad)
    }

    // ── Resize handle ─────────────────────────────────────────────────────────────
    private var resizeHandle: some View {
        Capsule()
            .fill(theme.text.opacity(resizeHover ? 0.55 : 0.3))
            .frame(width: 4, height: 48)
            .padding(.trailing, 4)
            .frame(width: 18, alignment: .trailing)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { h in resizeHover = h; if h { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        let s = resizeStart ?? width
                        if resizeStart == nil { resizeStart = width }
                        width = min(maxWidth, max(minWidth, s - v.translation.width))
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }

    // ── Date/time bindings ──────────────────────────────────────────────────────────
    private var dateBinding: Binding<Date> {
        Binding(get: { makeDate(itemYear, month, day) },
                set: { d in let x = ymd(d); engine.update(id) { $0.month = x.m; $0.day = x.day }; syncFromEngine() })
    }
    private var ddlDateBinding: Binding<Date> {
        Binding(get: { makeDate(itemYear, month, day) },
                set: { d in let x = ymd(d); engine.updateDeadline(id) { $0.year = x.y; $0.month = x.m; $0.day = x.day }; syncFromEngine() })
    }
    private func bandDayBinding(_ isStart: Bool) -> Binding<Date> {
        Binding(
            get: { makeDate(itemYear, month, isStart ? startDay : endDay) },
            set: { d in
                let day = max(1, min(daysInMonth(itemYear, month), ymd(d).day))
                engine.updateBand(id) { if isStart { $0.startDay = min(day, $0.endDay) } else { $0.endDay = max(day, $0.startDay) } }
                syncFromEngine()
            })
    }
    private var monthRange: ClosedRange<Date> {
        makeDate(itemYear, month, 1)...makeDate(itemYear, month, daysInMonth(itemYear, month))
    }
    private func timeBinding(_ get: @escaping () -> CGFloat, _ set: @escaping (CGFloat) -> Void) -> Binding<Date> {
        Binding(
            get: {
                let h = get(); let hh = min(23, Int(h)); let mm = Int((h - floor(h)) * 60)
                return Calendar.current.date(bySettingHour: hh, minute: mm, second: 0, of: base) ?? base
            },
            set: { d in let c = Calendar.current.dateComponents([.hour, .minute], from: d); set(CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60) })
    }
    private func setStart(_ h: CGFloat) { engine.update(id) { $0.startHour = h; if $0.endHour < h + 0.25 { $0.endHour = min(24, h + 0.5) } }; syncFromEngine() }
    private func setEnd(_ h: CGFloat) { engine.update(id) { $0.endHour = max(h, $0.startHour + 0.25) }; syncFromEngine() }
    private func setDdlHour(_ h: CGFloat) { engine.updateDeadline(id) { $0.hour = h }; syncFromEngine() }

    // ── Repeat bindings + logic ───────────────────────────────────────────────────
    private var anchorDate: Date { makeDate(itemYear, month, kind == .band ? startDay : day) }
    private var anchorDow: Int { (Calendar.current.dateComponents([.weekday], from: anchorDate).weekday ?? 1) - 1 }

    private var repKind: Binding<String> { Binding(get: { rep.kind }, set: { setKind($0) }) }
    private var repN: Binding<Int> { Binding(get: { rep.n ?? 1 }, set: { rep.n = $0; commitRep() }) }
    private var untilOn: Binding<Bool> {
        Binding(get: { rep.until != nil },
                set: { on in if on { if rep.until == nil { rep.until = iso(anchorDate) } } else { rep.until = nil }; commitRep() })
    }
    private var untilDate: Binding<Date> {
        Binding(get: { parseIso(rep.until) ?? anchorDate }, set: { rep.until = iso($0); commitRep() })
    }
    private func setKind(_ k: String) {
        switch k {
        case "daily": rep = Repeat(kind: "daily", until: rep.until)
        case "weekly": rep = Repeat(kind: "weekly", n: rep.n ?? 1, until: rep.until)
        case "yearly": rep = Repeat(kind: "yearly", until: rep.until)
        case "weekdays": rep = Repeat(kind: "weekdays", n: rep.n ?? 1, until: rep.until, days: withAnchor(rep.days))
        default: rep = Repeat(kind: "none")
        }
        commitRep()
    }
    private func toggleDay(_ i: Int) {
        if i == anchorDow { return }
        var set = Set(rep.days ?? [anchorDow])
        if set.contains(i) { set.remove(i) } else { set.insert(i) }
        set.insert(anchorDow)
        rep.days = set.sorted(); commitRep()
    }
    private func withAnchor(_ days: [Int]?) -> [Int] { (Set(days ?? []).union([anchorDow])).sorted() }
    private func commitRep() { endWhenEdit(); engine.setRepeat(id, rep.kind == "none" ? nil : rep) }

    // ── Promote / lane bindings ─────────────────────────────────────────────────────
    private var lane: Binding<Int> { Binding(get: { track }, set: { endWhenEdit(); track = $0; engine.updateBand(id) { $0.track = track } }) }
    private var promoteOn: Binding<Bool> {
        Binding(get: { promote != nil }, set: { on in endWhenEdit(); promote = on ? (promote ?? 0) : nil; engine.setPromoteTrack(id, promote) })
    }
    private var promoteLane: Binding<Int> { Binding(get: { promote ?? 0 }, set: { endWhenEdit(); promote = $0; engine.setPromoteTrack(id, promote) }) }

    // ── Tags logic ────────────────────────────────────────────────────────────────
    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !tags.contains(t) { tags.append(t); engine.setTags(id, tags) }
        tagDraft = ""; tagFocused = true   // keep adding
    }
    private func removeTag(_ t: String) { endWhenEdit(); tags.removeAll { $0 == t }; engine.setTags(id, tags) }

    // ── Date helpers ────────────────────────────────────────────────────────────────
    private func makeDate(_ year: Int, _ month0: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = year; c.month = month0 + 1; c.day = d; c.hour = 12
        return Calendar.current.date(from: c) ?? base
    }
    private func ymd(_ d: Date) -> (y: Int, m: Int, day: Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return (c.year ?? itemYear, (c.month ?? 1) - 1, c.day ?? 1)
    }
    private func iso(_ d: Date) -> String { let x = ymd(d); return String(format: "%04d-%02d-%02d", x.y, x.m + 1, x.day) }
    private func parseIso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return makeDate(y, m - 1, d)
    }

    // ── Load / commit / sync ─────────────────────────────────────────────────────
    private func load() {
        width = min(max(minWidth, width), maxWidth)
        if let e = engine.event(id) { kind = .timed; title = e.title; color = e.color; itemYear = engine.year; month = e.month; day = e.day; start = e.startHour; end = e.endHour }
        else if let b = engine.band(id) { kind = .band; title = b.title; color = b.color; itemYear = b.year; month = b.month; startDay = b.startDay; endDay = b.endDay; track = b.track }
        else if let d = engine.deadline(id) { kind = .deadline; title = d.title; color = d.color; itemYear = d.year; month = d.month; day = d.day; hour = d.hour }
        else { onClose(); return }
        tags = engine.richTags(id)
        rep = engine.repeatConfig(id) ?? Repeat(kind: "none")
        promote = engine.promoteTrack(id)
        // Focused occurrence box id (the clicked ghost if it belongs to this series, else the base).
        occKey = (engine.selectedId.flatMap { sourceId(of: $0) == id ? $0 : nil }) ?? id
        notes = engine.notes(id)
        occNote = engine.occNote(id, occKey)
        noteScope = .series
        notesMode = notes.isEmpty ? .edit : .preview   // land on preview when there's something to show
    }
    private func syncFromEngine() {
        if let e = engine.event(id) { month = e.month; day = e.day; start = e.startHour; end = e.endHour }
        else if let b = engine.band(id) { itemYear = b.year; month = b.month; startDay = b.startDay; endDay = b.endDay; track = b.track }
        else if let d = engine.deadline(id) { itemYear = d.year; month = d.month; day = d.day; hour = d.hour }
    }
    private func commitTitle(_ v: String) {
        switch kind {
        case .timed: engine.update(id) { $0.title = v }
        case .band: engine.updateBand(id) { $0.title = v }
        case .deadline: engine.updateDeadline(id) { $0.title = v }
        }
    }
    private func commitColor(_ v: String) {
        switch kind {
        case .timed: engine.update(id) { $0.color = v }
        case .band: engine.updateBand(id) { $0.color = v }
        case .deadline: engine.updateDeadline(id) { $0.color = v }
        }
    }
}
