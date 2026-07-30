# Retiring the WKWebViews: a feasibility study

*2026-07-30. Research doc — no code changes. Question: can the Mac app drop WebKit entirely and
replace the dashboard + notes editor with native SwiftUI/AppKit, and is it worth it?*

**Verdict up front: yes, feasible, and strongly aligned with where the app is already going —
but it is a staged campaign (roughly 4 phases, the TODO list first, the live markdown editor
last), not a rewrite-in-one-PR. The TODO/deadline/gantt panels are natural SwiftUI and inherit
the engine's 120Hz render loop for free. The two genuinely hard parity problems are (1) the
CodeMirror editing experience and (2) KaTeX math rendering. Everything else is porting work.**

---

## 1. What WebKit does for the app today

Exactly **two** WKWebViews exist (everything else — Help, Tutorial, Assistant — is already native):

### A. `DailyDashboardWebView` — the dashboard panel (dashboard.ts, ~1,700 lines TS + 350 CSS)
| Feature | Notes |
|---|---|
| TODO list | day-relative sectioning (Today/Overdue/Followup/High-Soon/Due-Soon/Completed), nesting with fold/unfold animations, checkbox toggles with character-progressive strike-through, per-scope layering prefs (⚙), top-10 completed cap |
| Deadline list | range dropdown (week/month/30d/3m/6m), click-to-navigate |
| PROJ gantt | per-project timeline charts: bars, deadline/event markers, now-line, axis ticks, top-8 relevance cut with animated accordion expand |
| NOTE tab | static markdown previews per day/week/month + the **live CodeMirror editor overlay** at rest |
| Carousels | day pager, week/month turns, zoom-scope cross-fades — driven per-frame by `CK.tick` from Swift |
| Keyboard nav | Tab-stop bridge (row cursor, activate, fold, note focus) |
| Misc | in-page scrim (drawer), right-click layering menu, gesture forwarding, hit-gating |

### B. `MarkdownWebEditor` — the drawer notes editor (noteEditor.ts, 440 lines)
CodeMirror 6: markdown syntax highlighting, history, selection, placeholder, entity
autocompletion (#tag/@person/project: from `entityIndexJSON`), todo-line helpers, line-jump
selection; plus `renderMarkdown` preview = remark-parse → GFM → math → **rehype-KaTeX** →
custom `remarkTodoTokens` (due:/p:/#tag/@person chips) → HTML, and `managedNote` split
rendering for imported items.

### Shared source of truth (the real coupling)
`src/lib/assistant/tools/todos.ts` (501 lines) — the todo tokenizer/indexer — is imported by
BOTH the web app and the bundled dashboard. Sectioning semantics, token grammar (`due:`,
`p:!!!`, `#tag`, `@person`, `followup:`, `start:`, `done:` stamps, nesting by indent,
occurrence soft-links) live there once. Going native means a **Swift port that can drift**.
Mitigation below (§4).

## 2. Why this is worth doing (the case FOR)

1. **The entire class of webview pathologies dies.** This week's campaign fought, one by one:
   the 60fps rendering cap (lifted via *private* WKPreferences SPI), page suspension on
   occlusion/hide, first-paint stalls on reveal (30–70ms), JSC GC pauses mid-slide, per-frame
   `evaluateJavaScript` IPC, `CK.tick` echo suppression, webview mount cost at zoom seams
   (~55ms, worked around with the persistent-webview opt). Native views render inside the same
   `TimelineView` frame as the calendar — none of these problems can exist.
2. **The private API goes away.** `PreferPageRenderingUpdatesNear60FPSEnabled` +
   `_setEnabled:forFeature:` is an App Store review risk we accepted for 120Hz. Native needs
   nothing.
3. **iOS convergence.** The iPhone app already renders markdown natively (`PhoneMarkdown`) and
   has *no* dashboard because the webview stack was never wired for it ("biggest remaining
   value" in the perf backlog). A native dashboard is written once in CalendarUI/CalendarRender
   style and runs on both platforms; the webview one will never reach the phone.
4. **The Swift seeds already exist.** `TodoNotifyScan` parses todo lines/due/priority for
   notifications; `PhoneMarkdown` renders blocks + inline via `AttributedString(markdown:)`;
   the engine already owns all data (`dashboardDataJSON` would be replaced by direct engine
   reads — the whole JSON serialize→IPC→parse→re-index pipeline disappears, along with the
   caches we built to tame it).
5. **Simpler builds.** No node_modules/esbuild step, no 2.1MB bundled JS, no KaTeX font
   assets; `-` the whole webeditor/ build.sh pipeline.
6. **Memory/energy.** One fewer WebContent + GPU-process working set (~100–200MB), no JS heap.

## 3. What is genuinely hard (the case AGAINST / risk register)

| Risk | Severity | Notes |
|---|---|---|
| **CodeMirror parity** | HIGH | The live editor is the tail boss: syntax-highlighted markdown editing, entity autocomplete, todo interactions, line-jump + selection, undo integration with the app's undo layering. An NSTextView-based editor (Bear/Ulysses-style highlighter over `NSTextContentStorage`) is well-trodden but is real work (~1–2 weeks alone) and "feels different" until tuned. |
| **KaTeX math** | HIGH if math is used, LOW otherwise | No first-party Swift math renderer. Options: SwiftMath (community port of iosMath, MIT — renders LaTeX via CoreText, quality good for common math; not full KaTeX coverage), or rasterizing via a hidden legacy path, or dropping math in native preview. **Decision needed: how much do the user's real notes use `$…$`?** A grep of the store can answer empirically. |
| **Tokenizer drift (web ⇄ Swift)** | MEDIUM | The web app still reads the same notes. Mitigate with a shared fixture corpus: golden test vectors (note → parsed todos JSON) generated from todos.ts, replayed against the Swift port in `swift test` (same trick as the regex→manual-parser differential tests). |
| **remark/GFM rendering parity** | MEDIUM | Tables, autolinks, task lists, the custom todo-token chips. `AttributedString(markdown:)` covers inline + basic blocks; tables/quotes/fences need a block-level renderer (PhoneMarkdown pattern, extended). Apple's `swift-markdown` (cmark-gfm) is a clean SPM dep if the zero-dependency rule allows one exception; otherwise a ~600-line first-party block parser is realistic (PhoneMarkdown is already ~160). |
| **Rebuild churn** | MEDIUM | Fold/strike/carousel animations, keyboard nav, layering menus all re-implemented and re-verified. The tutorial GIFs touching the dashboard need re-recording. |
| **Two dashboards during migration** | LOW | Feature-flag per panel (see phasing) keeps the webview as fallback until each native panel is verified. |

## 4. Architecture of the native replacement

New home: **`CalendarRender/Notes`** (pure model + markdown/todo parsing, platform-free) +
**`CalendarUI/Dashboard`** (SwiftUI views, Mac) — with the model layer reusable by the iPhone
target directly.

1. **`TodoIndex` (Swift port of todos.ts)** — extend `TodoNotifyScan` into the full grammar:
   tokens, nesting, soft-links (source, line), sectioning, done-stamps, followups. Pure value
   types over `CalendarItems` — *no JSON round-trip*: the index reads the store directly and
   caches per `(editGen, noteGen)` exactly like `dashJSONCache` does today. Golden-vector
   differential tests against todos.ts output keep web parity honest.
2. **`MarkdownBlocks` (renderer model)** — PhoneMarkdown's block parser promoted to
   CalendarRender and extended: tables, fences w/ syntax tint, todo-token chips (due/priority/
   tag/person spans — the `remarkTodoTokens` equivalent), managed-note sections, optional math
   via SwiftMath behind a protocol so the dependency stays quarantined.
3. **`DashboardPanelView` (SwiftUI)** — TODO sections (`LazyVStack` rows — native lazy
   rendering *is* the "on-demand window" for free), deadline list, completed cap, fold
   animations (`withAnimation` + `matchedGeometryEffect` replaces the hand-rolled Web
   Animations), checkbox strike (a `TextRenderer`/AttributedString strikethrough animation).
   Carousel: the panel view takes the SAME `dashScopePanels` geometry the webview ticks
   consume today — mounted inside the existing TimelineView, offsets applied as `.offset`/
   `.opacity` per frame. The CarouselDriver/CK.tick bridge is deleted, not ported.
4. **`ProjGanttView`** — a Canvas chart (the codebase's home idiom; SceneRenderer patterns
   apply directly): bars, markers, now-line, animated top-8 accordion.
5. **`MarkdownEditorView` (last)** — NSTextView + `NSTextLayoutManager` with a regex/lezer-less
   line-based highlighter (markdown is line-friendly; the app's notes are short), entity
   autocomplete via the existing `entityIndexJSON` machinery, todo-line commands reusing
   `TodoIndex`. The app's native undo/focus systems integrate directly (today's focus-gating
   dance with WKWebView disappears).

## 5. Phasing (each phase shippable, webview as fallback flag)

| Phase | Scope | Est. effort | Kill-switch |
|---|---|---|---|
| 0 | `TodoIndex` Swift port + golden tests; store scan for `$math$` usage | 2–4 days | n/a (pure lib) |
| 1 | Native TODO + deadline panels (day/week/month scopes) behind `cc.nativeDash` | ~1 week | flag flips back to webview |
| 2 | PROJ gantt + NOTE static previews (MarkdownBlocks) | ~1 week | per-tab flag |
| 3 | Live markdown editor (dashboard notepads + drawer), retire `MarkdownWebEditor` | 1–2 weeks | per-surface flag |
| 4 | Delete webeditor/, WKWebView hosts, CarouselDriver, 60fps SPI, occlusion SPI, dashJSON pipeline | 1–2 days | — |

Sequencing rationale: phase 1 removes the panel that caused every perf incident this week and
is the least parity-risky; the editor goes last because CodeMirror is the best thing WebKit
currently buys us. iPhone gets the dashboard "for free" after phase 2 (its own layout pass, but
the same views/models).

## 6. Open decisions for the user

1. **Math**: ~~is KaTeX-in-notes load-bearing?~~ **Answered empirically 2026-07-30**: the real
   store has **0/276 notes with math and 0 with tables** (1 code fence, 53 md links). KaTeX and
   GFM tables are NOT load-bearing — the PhoneMarkdown grammar (headings, todos, lists, quotes,
   fences, links) covers actual usage. Math can be "renders as code-styled span" in native, or
   deferred entirely. This removes the top rendering-parity risk and the SwiftMath dependency
   question.
2. **Dependency policy**: ~~open~~ **Decided 2026-07-30: Swift dependencies are acceptable in
   general.** Default remains first-party (extended PhoneMarkdown parser — actual usage needs
   no tables/math), with `swift-markdown` available guilt-free if parity gaps surface.
3. **Web app fate**: **Decided 2026-07-30: the web app is LEGACY.** The Swift `TodoIndex` port
   becomes the source of truth going forward; golden vectors generated ONCE from todos.ts seed
   the initial test corpus (correctness bootstrap, not a permanent parity contract).
