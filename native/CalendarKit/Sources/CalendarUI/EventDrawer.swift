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
    public var editingTimed: TimedEdit?   // inline timed-event-title editor target
    public var showKeyGuide: Bool = false // Cmd+K shortcut-guide overlay is held open
    public var drawerFocus: DrawerField?  // which drawer control the keyboard has focused (nil = drawer body)
    public var drawerTitleEditing: Bool = false   // the title field is in text-editing mode (vs. ring focus)
    // True while a native inline editor (the date/time NSDatePicker) is active. The key monitor treats
    // this like text-input focus: it passes ALL keys — including Tab — to the native field so it cycles
    // its own components, and the drawer-level Tab cycle does NOT advance until Enter/Esc commits.
    public var drawerFieldEditing: Bool = false
    // True while the delete confirmation dialog is up. The key monitor yields the keyboard to it so its
    // native Enter/Escape/arrow handling works (otherwise the monitor would swallow those keys).
    public var drawerConfirmingDelete: Bool = false
    // The Tab cycle for the open item — published by the drawer on load (it depends on the item kind,
    // e.g. bands have no start/end *time*). Both the drawer and the keyboard model read it.
    public var drawerFieldOrder: [DrawerField] = []
    // One-shot action channel: the keyboard model (which lives outside the drawer, in the key monitor)
    // posts a semantic action here; the drawer observes `drawerPulse` and runs it against its own state.
    // `drawerPulse` always increments so repeated identical actions (e.g. Right, Right) still fire.
    public var drawerPulse: Int = 0
    public var drawerActionKind: DrawerActionKind = .none
    public init() {}

    /// Post a keyboard action into the open drawer (see `drawerPulse`).
    public func postDrawer(_ kind: DrawerActionKind) { drawerActionKind = kind; drawerPulse += 1 }
    /// The field after / before `f` in the current Tab cycle (wrapping).
    public func fieldAfter(_ f: DrawerField) -> DrawerField? {
        guard let i = drawerFieldOrder.firstIndex(of: f) else { return drawerFieldOrder.first }
        return drawerFieldOrder[(i + 1) % drawerFieldOrder.count]
    }
    public func fieldBefore(_ f: DrawerField) -> DrawerField? {
        guard let i = drawerFieldOrder.firstIndex(of: f) else { return drawerFieldOrder.last }
        return drawerFieldOrder[(i - 1 + drawerFieldOrder.count) % drawerFieldOrder.count]
    }
}

/// A keyboard-focusable control in the event drawer. The concrete Tab cycle for a given item is
/// published in `CalendarUIState.drawerFieldOrder` (it varies by kind). `.date/.start/.end` are the
/// three "when" parts (for bands, start/end are the start/end *day*; deadlines have date + one time).
public enum DrawerField: Hashable {
    case title, date, start, end, color, config, notes, delete
    case cfgTags, cfgRepeat, cfgPromote   // controls inside Configuration (only in the cycle while it's open)
    case repEvery, repDays, repUntil, repUntilDate   // repeat sub-controls (shown conditionally by kind)
    case promoteLane   // the lane picker that appears when Promote is on (timed / deadline)
}

extension DrawerField {
    /// Human label for the Cmd+K guide heading.
    var label: String {
        switch self {
        case .title:  return "title"
        case .date:   return "date"
        case .start:  return "start time"
        case .end:    return "end time"
        case .color:  return "color"
        case .config: return "configuration"
        case .notes:  return "notes"
        case .delete: return "delete"
        case .cfgTags:      return "tags"
        case .cfgRepeat:    return "repeat"
        case .cfgPromote:   return "promote / lane"
        case .repEvery:     return "every N weeks"
        case .repDays:      return "weekdays"
        case .repUntil:     return "until"
        case .repUntilDate: return "until date"
        case .promoteLane:  return "lane"
        }
    }
    /// Is this one of the controls nested inside Configuration? (Escape returns to the config header.)
    var isConfigChild: Bool {
        switch self {
        case .cfgTags, .cfgRepeat, .cfgPromote, .repEvery, .repDays, .repUntil, .repUntilDate, .promoteLane: return true
        default: return false
        }
    }
}

/// A one-shot keyboard action the drawer executes. `activate`/`left`/`right` act on the focused field;
/// `confirmDelete` is global to the drawer (the Delete key → the trash button's confirmation dialog).
public enum DrawerActionKind { case none, activate, left, right, confirmDelete }

/// Collects each drawer field's frame (as an Anchor) so ONE dashed ring can slide over the focused one
/// — the same visual language as the calendar's block/band/event cursors (see CursorRing).
private struct DrawerRingAnchors: PreferenceKey {
    static let defaultValue: [DrawerField: Anchor<CGRect>] = [:]
    static func reduce(value: inout [DrawerField: Anchor<CGRect>], nextValue: () -> [DrawerField: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
private extension View {
    /// Mark this view as drawer field `field`'s focus target (its bounds feed the sliding ring).
    func drawerRingAnchor(_ field: DrawerField) -> some View {
        anchorPreference(key: DrawerRingAnchors.self, value: .bounds) { [field: $0] }
    }
}

/// Target for the inline track-name editor: which month + track, and where (geometry rect).
public struct TrackEdit: Equatable { public var month: Int; public var track: Int; public var rect: CGRect }
/// Target for the inline band-title editor: which band id, and where (geometry rect).
public struct BandEdit: Equatable { public var id: String; public var rect: CGRect }
/// Target for the inline timed-event-title editor: which (source) event id, and where (geometry rect).
public struct TimedEdit: Equatable { public var id: String; public var rect: CGRect }

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
    var ui: CalendarUIState                 // keyboard focus target (ui.drawerFocus) — kept in 2-way sync
    var refocus: () -> Void = {}            // return first-responder to the calendar canvas on field blur

    @FocusState private var fieldFocus: DrawerField?   // the keyboard-focused drawer control (mirrors ui.drawerFocus)
    @State private var kind: ItemKind2 = .timed
    @State private var title = ""
    @State private var titleOriginal = ""   // title at edit-start — restored if left blank
    @State private var color = "blue"
    @State private var resizeStart: CGFloat?
    @State private var resizeHover = false
    @State private var whenEditing: WhenField?      // which "when" part currently shows its editor
    @FocusState private var whenFocus: WhenField?   // focuses the shown editor
    @State private var repDayCursor = 0             // keyboard cursor across the 7 weekday buttons (repDays)
    @FocusState private var untilFocused: Bool      // the "until" date field is keyboard-editing
    @State private var notesFocusPulse = 0          // bump → focus the notes editor (keyboard)
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
    @State private var tagDraft = ""   // TagInputField self-manages first-responder focus (no @FocusState)
    @State private var hoveredTag: String?           // tag chip under the cursor (hover highlight)
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
            // Title editing rides the native @FocusState: ui.drawerTitleEditing (set by Enter) focuses
            // the field; a native blur (Tab/click away) flips it back off. Ring focus on the other
            // fields is a pure highlight driven by ui.drawerFocus — no native control receives it.
            .onChange(of: ui.drawerTitleEditing) { _, editing in
                if fieldFocus != (editing ? .title : nil) { fieldFocus = editing ? .title : nil }
                if editing { titleOriginal = title }   // remember the pre-edit title
                else {                                 // done → strip; a blank title reverts (no empty titles)
                    let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    title = s.isEmpty ? titleOriginal : s   // setting `title` re-fires commitTitle
                }
            }
            .onChange(of: fieldFocus) { _, v in
                if v == nil, ui.drawerTitleEditing { ui.drawerTitleEditing = false }   // native blur → stop editing
            }
            // Keyboard actions posted by the KeyboardModel (Enter / ←/→ on the focused field).
            .onChange(of: ui.drawerPulse) { _, _ in handleDrawerAction(ui.drawerActionKind) }
            // Tell the key monitor when a native inline editor owns the keyboard (so Tab goes to it,
            // not our drawer cycle) — either a "when" part or the "until" date field.
            .onChange(of: whenEditing) { _, _ in updateFieldEditing() }
            .onChange(of: untilFocused) { _, _ in updateFieldEditing() }
            // The confirmation dialog wants the keyboard while it's up (native Enter/Esc/arrows).
            .onChange(of: showDeleteConfirm) { _, v in ui.drawerConfirmingDelete = v }
            // Configuration open/close re-shapes the Tab cycle (its children join/leave it). If it
            // collapses while a child is focused, pull focus back up to the Configuration header.
            .onChange(of: configOpen) { _, open in
                publishFieldOrder()
                if !open {
                    if ui.drawerFocus?.isConfigChild == true { ui.drawerFocus = .config }
                    addingTag = false; tagDraft = ""   // don't leave the tag input up (it self-focuses on re-expand)
                }
            }
            .onDisappear { ui.drawerFocus = nil; ui.drawerTitleEditing = false; ui.drawerFieldEditing = false; ui.drawerConfirmingDelete = false }
            .id(id)
    }

    private var card: some View {
        VStack(spacing: 0) {
            // Top: title / when / color / configuration (compact — Configuration collapses by default).
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    titleField
                    whenControls   // each part carries its own focus ring (see whenPart)
                    colorSwatches.drawerRingAnchor(.color)
                }
                configBox.drawerRingAnchor(.config)
            }
            .padding(.horizontal, contentPad).padding(.top, contentPad).padding(.bottom, configBottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Tapping empty top-area space ends any inline "when" edit (macOS won't resign a focused
            // DatePicker when a non-text control / blank area is clicked).
            .onTapGesture { endWhenEdit() }

            // Notes markdown editor (WKWebView) fills the remaining space. Horizontal padding of 18
            // matches the top content so the text left/right edges line up (internal CSS padding is 0).
            MarkdownWebEditor(text: activeNote, mode: $notesMode, theme: theme,
                              focusPulse: notesFocusPulse,
                              onExit: { refocus() },          // Escape → back to the notes ring
                              onSavePreview: { refocus() })   // ⌘S → preview → back to the notes ring
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .drawerRingAnchor(.notes)
                .padding(.horizontal, contentPad).padding(.vertical, editorVPad)

            footRow
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        // The single sliding dashed focus ring, positioned from the collected field anchors.
        .overlayPreferenceValue(DrawerRingAnchors.self) { drawerRingOverlay($0) }
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

    // ── Keyboard drive ────────────────────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════════════════
    // FOCUS-RING SHAPES — TUNE HERE. This is the single place that controls the shape of
    // every drawer focus ring. Each field maps to a RingSpec:
    //   • inset  — padding applied to the ring rect. NEGATIVE grows it OUTWARD past the
    //              control (looser); POSITIVE shrinks it INWARD (tighter). Per-edge, so you
    //              can nudge just left/right or top/bottom (e.g. to clear an occluding edge).
    //   • radius — corner radius of the rounded rectangle.
    //   • width  — stroke thickness when focused.
    // Every call site is just `.drawerRingAnchor(.someField)` — no geometry there.
    // ═══════════════════════════════════════════════════════════════════════════════
    private struct RingSpec { var inset: EdgeInsets; var radius: CGFloat; var width: CGFloat = 2 }

    private func ringSpec(for field: DrawerField) -> RingSpec {
        // helpers: `ins` = per-edge (top, leading, bottom, trailing); `all` = uniform.
        func ins(_ t: CGFloat, _ l: CGFloat, _ b: CGFloat, _ r: CGFloat) -> EdgeInsets { EdgeInsets(top: t, leading: l, bottom: b, trailing: r) }
        func all(_ v: CGFloat) -> EdgeInsets { ins(v, v, v, v) }
        switch field {
        // Top group
        case .title:               return RingSpec(inset: ins(-3, -5, -3, -5), radius: 8)
        case .date, .start, .end:  return RingSpec(inset: ins(-2, -4, -2, -4), radius: 8)
        case .color:               return RingSpec(inset: all(-4), radius: 8)
        case .config:              return RingSpec(inset: all(-2), radius: 10)
        case .notes:               return RingSpec(inset: all(0),  radius: 6)
        case .delete:              return RingSpec(inset: all(-4), radius: 7)
        // Configuration children (rings sit on the inner controls)
        case .cfgTags:             return RingSpec(inset: all(-3), radius: 7)
        case .cfgRepeat:           return RingSpec(inset: all(-3), radius: 7)
        case .repEvery:            return RingSpec(inset: all(-3), radius: 7)
        case .repDays:             return RingSpec(inset: all(-3), radius: 7)
        case .repUntil:            return RingSpec(inset: all(-3), radius: 7)
        case .repUntilDate:        return RingSpec(inset: all(-3), radius: 7)
        case .cfgPromote:          return RingSpec(inset: all(-3), radius: 7)
        case .promoteLane:         return RingSpec(inset: all(-3), radius: 7)
        }
    }

    /// The ONE dashed focus ring that slides over the focused field. Positioned from the collected
    /// field anchors; springs to its new frame when `ui.drawerFocus` changes. Dashed + red = the same
    /// language as the calendar cursors.
    @ViewBuilder private func drawerRingOverlay(_ anchors: [DrawerField: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let f = ui.drawerFocus, let anchor = anchors[f] {
                let spec = ringSpec(for: f)
                let b = proxy[anchor]
                let rect = CGRect(x: b.minX + spec.inset.leading, y: b.minY + spec.inset.top,
                                  width: b.width - spec.inset.leading - spec.inset.trailing,
                                  height: b.height - spec.inset.top - spec.inset.bottom)
                RoundedRectangle(cornerRadius: spec.radius, style: .continuous)
                    .strokeBorder(theme.eventBorder("red"), style: StrokeStyle(lineWidth: spec.width, dash: [4, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: ui.drawerFocus)
    }

    /// Map a keyboard-focused "when" field to its inline editor part.
    private func whenFieldFor(_ f: DrawerField) -> WhenField? {
        switch f { case .date: return .date; case .start: return .start; case .end: return .end; default: return nil }
    }

    /// Run a keyboard action against the currently-focused field (posted via ui.postDrawer).
    private func handleDrawerAction(_ action: DrawerActionKind) {
        if action == .confirmDelete { showDeleteConfirm = true; return }   // Delete key → same as the trash button
        switch ui.drawerFocus {
        case .title:
            if action == .activate { ui.drawerTitleEditing = true }   // Enter → start editing the title
        case .date, .start, .end:
            if action == .activate, let wf = whenFieldFor(ui.drawerFocus!) { whenEditing = wf }
        case .color:
            if action == .left { cycleColor(-1) } else if action == .right { cycleColor(1) }
        case .config:
            if action == .activate { withAnimation(.easeInOut(duration: 0.2)) { configOpen.toggle() } }
        case .cfgTags:
            if action == .activate { endWhenEdit(); addingTag = true }   // show the input (it self-focuses on appear)
        case .cfgRepeat:
            if action == .left { cycleRepeat(-1) } else if action == .right { cycleRepeat(1) }
        case .repEvery:
            if action == .left { stepEvery(-1) } else if action == .right { stepEvery(1) }
        case .repDays:
            if action == .left { repDayCursor = (repDayCursor + 6) % 7 }
            else if action == .right { repDayCursor = (repDayCursor + 1) % 7 }
            else if action == .activate { toggleDay(repDayCursor) }
        case .repUntil:
            if action == .left || action == .right { untilOn.wrappedValue.toggle() }
        case .repUntilDate:
            if action == .activate { untilFocused = true }
        case .cfgPromote:
            if action == .left { stepPromote(-1) } else if action == .right { stepPromote(1) }
        case .promoteLane:
            if action == .left { stepPromoteLane(-1) } else if action == .right { stepPromoteLane(1) }
        case .notes:
            if action == .activate { notesMode = .edit; notesFocusPulse += 1 }   // edit mode + focus CodeMirror
        case .delete:
            if action == .activate { showDeleteConfirm = true }
        case .none: break
        }
    }

    private let repeatKinds = ["none", "daily", "weekly", "weekdays", "yearly"]
    /// Step the repeat kind (← / →) through the segmented options.
    private func cycleRepeat(_ delta: Int) {
        let i = repeatKinds.firstIndex(of: rep.kind) ?? 0
        let n = repeatKinds.count
        setKind(repeatKinds[((i + delta) % n + n) % n])
    }
    /// Step the "every N weeks" count within 1…4.
    private func stepEvery(_ delta: Int) {
        let v = max(1, min(4, (rep.n ?? 1) + delta))
        if v != (rep.n ?? 1) { rep.n = v; commitRep() }
    }
    /// A native inline editor (a "when" part or the "until" date) owns the keyboard right now.
    private func updateFieldEditing() { ui.drawerFieldEditing = (whenEditing != nil) || untilFocused }
    /// Bands: step the lane T1…T4. Timed/deadline: toggle promote off/on (← and → both toggle).
    private func stepPromote(_ delta: Int) {
        if kind == .band {
            let t = max(0, min(3, track + delta))
            track = t; engine.updateBand(id) { $0.track = t }
        } else {
            promote = (promote == nil) ? 0 : nil
            engine.setPromoteTrack(id, promote)
            refreshOrder(fallback: .cfgPromote)   // toggling on/off adds/removes the lane picker
        }
    }
    /// Timed/deadline: step the promoted lane T1…T4.
    private func stepPromoteLane(_ delta: Int) {
        let v = max(0, min(3, (promote ?? 0) + delta))
        promote = v; engine.setPromoteTrack(id, promote)
    }

    /// Step the selected colour by `delta` (← / →), committing live.
    private func cycleColor(_ delta: Int) {
        guard let i = EVENT_COLORS.firstIndex(of: color) else { color = EVENT_COLORS.first ?? color; return }
        let n = EVENT_COLORS.count
        color = EVENT_COLORS[((i + delta) % n + n) % n]
        commitColor(color)
    }

    // ── Configuration disclosure (macOS Settings-style grouped box) ────────────────
    /// A collapsed-by-default rounded box: native DisclosureGroup for the collapse, holding the
    /// advanced controls (tags / repeat / promote) split by full-margin dividers.
    private var configBox: some View {
        DisclosureGroup(isExpanded: $configOpen) {
            VStack(alignment: .leading, spacing: 0) {
                configItem("Tags") { tagsControls.drawerRingAnchor(.cfgTags) }
                configDivider
                configItem("Repeat") { repeatControls }   // rings live on each repeat sub-control
                configDivider
                configItem(kind == .band ? "Lane" : "Promote") { laneOrPromoteControls }   // rings live on each control
            }
            .padding(.bottom, 6)
            // Inset the controls a touch so the focus rings' outset (see ringSpec, ~3pt) stays inside
            // the DisclosureGroup's content clip — otherwise the ring's left/right edges get cut off.
            .padding(.horizontal, 4)
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
            .focused($fieldFocus, equals: .title)   // keyboard: Enter on the title ring focuses this
            .onHover { $0 ? NSCursor.iBeam.set() : NSCursor.arrow.set() }
            .onChange(of: title) { _, v in commitTitle(v) }
            // Enter / Escape end editing but keep the title RING focused, so Tab flows on to date.
            .onSubmit { ui.drawerTitleEditing = false; refocus() }
            .onExitCommand { ui.drawerTitleEditing = false; refocus() }
            .drawerRingAnchor(.title)
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
                    // Enter / Escape commit-and-exit the native editor back to the ring, returning
                    // first responder to the calendar so Tab keeps cycling. (The value is already
                    // committed live by the bindings, so both keys just close the editor.)
                    .onExitCommand { endWhenEdit(); refocus() }
                    .onKeyPress(.return) { endWhenEdit(); refocus(); return .handled }
            } else {
                Text(text)
                    .foregroundStyle(theme.text)
                    .contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.iBeam.set() : NSCursor.arrow.set() }
                    .onTapGesture { whenEditing = field }
            }
        }
        .frame(height: whenRowH, alignment: .leading)
        .drawerRingAnchor(whenDrawerField(field))
    }

    /// The DrawerField that corresponds to a "when" part (for the focus ring).
    private func whenDrawerField(_ f: WhenField) -> DrawerField {
        switch f { case .date: return .date; case .start: return .start; case .end: return .end }
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
                // A raw NSTextField (via TagInputField) so we can catch Delete/Backspace on an EMPTY
                // input to remove the previous tag — SwiftUI's TextField swallows that key itself.
                TagInputField(
                    text: $tagDraft,
                    onSubmit: addTag,
                    onCancel: { addingTag = false; tagDraft = ""; refocus() },   // Esc → back to the cfgTags ring
                    onDeleteWhenEmpty: { if let last = tags.last { removeTag(last) } }   // Delete on empty → drop last tag
                )
                    .font(.caption).frame(width: 56)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .overlay(dashedPill)
            } else {
                Button { endWhenEdit(); addingTag = true } label: {
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
            // The kind picker itself is the `.cfgRepeat` stop (its ring lives here, not on the whole section).
            Picker("", selection: repKind) {
                Text("None").tag("none"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly")
                Text("Weekdays").tag("weekdays"); Text("Yearly").tag("yearly")
            }
            .pickerStyle(.segmented).labelsHidden()
            .drawerRingAnchor(.cfgRepeat)

            if rep.kind == "weekly" || rep.kind == "weekdays" {
                HStack(spacing: 6) {
                    Text("every").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: repN) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
                        .labelsHidden().frame(width: 58)
                    Text((rep.n ?? 1) > 1 ? "weeks" : "week").font(.caption).foregroundStyle(.secondary)
                }
                .drawerRingAnchor(.repEvery)
            }
            if rep.kind == "weekdays" {
                HStack(spacing: 4) { ForEach(0..<7, id: \.self) { weekdayButton($0) } }
                    .drawerRingAnchor(.repDays)
            }
            if rep.kind != "none" {
                HStack(spacing: 8) {
                    Text("until").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: untilOn) { Text("None").tag(false); Text("Date").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()   // hug content, flush left
                        .drawerRingAnchor(.repUntil)
                    if rep.until != nil {
                        DatePicker("", selection: untilDate, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field)
                            .focused($untilFocused)
                            .drawerRingAnchor(.repUntilDate)
                            // Enter / Escape commit-and-exit the field back to the ring (value is live).
                            .onExitCommand { untilFocused = false; refocus() }
                            .onKeyPress(.return) { untilFocused = false; refocus(); return .handled }
                    }
                }
            }
        }
    }

    private func weekdayButton(_ i: Int) -> some View {
        let sel = (rep.days ?? [anchorDow]).contains(i)
        let locked = i == anchorDow
        let cursor = ui.drawerFocus == .repDays && repDayCursor == i   // keyboard cursor is on this day
        return Button { toggleDay(i) } label: {
            Text(DOW[i]).font(.caption2)
                .frame(width: 27, height: 24)
                .background(sel ? theme.eventBorder(color).opacity(locked ? 0.5 : 0.9) : theme.text.opacity(0.06),
                           in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(sel ? .white : theme.text)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.eventBorder("red"), lineWidth: cursor ? 2 : 0))
        }
        .buttonStyle(.plain).disabled(locked)
    }

    // ── Promote / Lane ──────────────────────────────────────────────────────────────
    @ViewBuilder private var laneOrPromoteControls: some View {
        if kind == .band {
            Picker("", selection: lane) { ForEach(0..<4, id: \.self) { Text("T\($0 + 1)").tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
                .drawerRingAnchor(.cfgPromote)
        } else {
            HStack(spacing: 8) {
                Picker("", selection: promoteOn) { Text("No").tag(false); Text("Yes").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()   // hug content → flush left (not centered in a fixed frame)
                    .drawerRingAnchor(.cfgPromote)
                if promote != nil {
                    Picker("", selection: promoteLane) { ForEach(0..<4, id: \.self) { Text("T\($0 + 1)").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                        .drawerRingAnchor(.promoteLane)
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
            .drawerRingAnchor(.delete)
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
    private func commitRep() {
        endWhenEdit(); engine.setRepeat(id, rep.kind == "none" ? nil : rep)
        refreshOrder(fallback: .cfgRepeat)   // kind change adds/removes sub-controls in the Tab cycle
    }

    // ── Promote / lane bindings ─────────────────────────────────────────────────────
    private var lane: Binding<Int> { Binding(get: { track }, set: { endWhenEdit(); track = $0; engine.updateBand(id) { $0.track = track } }) }
    private var promoteOn: Binding<Bool> {
        Binding(get: { promote != nil }, set: { on in endWhenEdit(); promote = on ? (promote ?? 0) : nil; engine.setPromoteTrack(id, promote); refreshOrder(fallback: .cfgPromote) })
    }
    private var promoteLane: Binding<Int> { Binding(get: { promote ?? 0 }, set: { endWhenEdit(); promote = $0; engine.setPromoteTrack(id, promote) }) }

    // ── Tags logic ────────────────────────────────────────────────────────────────
    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !tags.contains(t) { tags.append(t); engine.setTags(id, tags) }
        tagDraft = ""   // keep adding — the input stays up and holds focus
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
        // Strip the promoted-band marker so a promoted bar and its timeline occurrence share one note.
        occKey = occurrenceKey(of: (engine.selectedId.flatMap { sourceId(of: $0) == id ? $0 : nil }) ?? id)
        notes = engine.notes(id)
        occNote = engine.occNote(id, occKey)
        noteScope = .series
        notesMode = notes.isEmpty ? .edit : .preview   // land on preview when there's something to show
        publishFieldOrder()
    }

    /// Publish the Tab cycle for the current kind. Configuration's children (tags / repeat / promote)
    /// are spliced in before delete only while the box is open, so Tab descends into them and back out.
    private func publishFieldOrder() {
        var order: [DrawerField]
        switch kind {
        case .timed:    order = [.title, .date, .start, .end, .color, .config]
        case .band:     order = [.title, .start, .end, .color, .config]   // start/end = start/end day
        case .deadline: order = [.title, .date, .start, .color, .config]  // start = the time
        }
        if configOpen {
            order.append(.cfgTags)
            order.append(.cfgRepeat)
            // The repeat sub-controls appear conditionally — mirror repeatControls exactly so Tab
            // visits every input that's actually on screen.
            if rep.kind == "weekly" || rep.kind == "weekdays" { order.append(.repEvery) }
            if rep.kind == "weekdays" { order.append(.repDays) }
            if rep.kind != "none" {
                order.append(.repUntil)
                if rep.until != nil { order.append(.repUntilDate) }
            }
            order.append(.cfgPromote)
            if kind != .band, promote != nil { order.append(.promoteLane) }   // lane picker appears when promoted
        }
        order.append(.notes)    // the markdown editor (always present, below Configuration)
        order.append(.delete)
        ui.drawerFieldOrder = order
    }

    /// Re-publish the Tab cycle after a change that adds/removes fields, retreating focus to `fallback`
    /// if the field it was on just left the cycle.
    private func refreshOrder(fallback: DrawerField) {
        publishFieldOrder()
        if let f = ui.drawerFocus, !ui.drawerFieldOrder.contains(f) { ui.drawerFocus = fallback }
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

// ── Tag input (raw NSTextField) ──────────────────────────────────────────────────
/// A single-line text field for entering a tag. It behaves like a plain SwiftUI TextField but also
/// reports three commands the field editor would otherwise eat silently:
///   • Return                      → onSubmit (add the tag)
///   • Escape                      → onCancel (stop adding)
///   • Delete/Backspace when EMPTY → onDeleteWhenEmpty (remove the previous tag)
/// SwiftUI's TextField gives us no hook for the last one (it consumes backspace-on-empty), so we drop
/// to AppKit and intercept `deleteBackward:` in the delegate. Self-focuses when it enters the window.
private struct TagInputField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onDeleteWhenEmpty: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = FocusOnAppearField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.placeholderString = "tag"
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.stringValue = text
        return tf
    }
    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TagInputField
        init(_ p: TagInputField) { parent = p }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { parent.text = tf.stringValue }
        }
        // The field editor routes special keys here as commands — intercept the three we care about.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):   parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):  parent.onCancel(); return true
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.string.isEmpty { parent.onDeleteWhenEmpty(); return true }   // empty → drop last tag
                return false   // otherwise let it delete a character normally
            default: return false
            }
        }
    }
}

/// An NSTextField that grabs first responder once, when it's first placed in a window (so the tag
/// input is ready to type in the moment it appears).
private final class FocusOnAppearField: NSTextField {
    private var didFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didFocus, let w = window else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; w.makeFirstResponder(self) }
    }
}
