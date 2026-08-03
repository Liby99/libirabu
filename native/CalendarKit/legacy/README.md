# legacy/ — retired webview code (kept, never deleted)

Retired source that is intentionally **relocated instead of deleted** (project rule), so it
stays greppable and recoverable without keeping dead code in the build.

## Phase 4a — dashboard webview stack (retired 2026-08-02)

The dashboard (TODO / NOTE / PROJ panels at day/week/month) is fully native SwiftUI now
(`NativeDashPanel` + `NativePanelHost` + `DashChrome`), so the WKWebView implementation moved
here:

- `DailyDashboardWebView.swift` — the WKWebView host + `DashboardCarousel` CSS conduit +
  `PassThroughWebView` (gesture forwarding) + `DailyDashboardOverlay`. Was compiled in
  `Sources/CalendarUI/` behind the `cc.nativeDashOff` / `CC_NATIVE_DASH_OFF` kill switches
  (also removed in 4a).
- `webeditor/dashboard.{ts,html,css}` — the page source (tokenizer, sectioning, gantt,
  carousel CSS). `webeditor/build.sh` no longer builds it.
- `editor-resources/dashboard.{js,html,css}` — the last built bundle, exactly as shipped.

Engine-side plumbing that existed only to feed this webview (`dashboardDataJSON`, the
`CK.tick` carousel IPC, `keepLive`/`webBlank`, the web-side bench stats `web_*`) was deleted
with the mount — see the phase-4a commit for the full diff.

## Phase 4b — note editor webview (pending)

`Sources/CalendarUI/MarkdownWebEditor.swift` + `webeditor/editor.ts` and the built
`Resources/editor/editor.*` move here once the native drawer editor has soaked.
