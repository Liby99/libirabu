# Tutorial carousel GIFs

Drop animated GIFs here with these exact names (see `TutorialView.swift` → `TutorialView.slides`).
Each slide falls back to a placeholder if its GIF is missing, so the carousel works without them.

| filename            | caption |
|---------------------|---------|
| `drag-create.gif`   | Drag on the calendar to create events. |
| `pinch-zoom.gif`    | Pinch to zoom into monthly, weekly, or daily view. |
| `ai-assistant.gif`  | Click the AI button to let AI help you manage your calendar. |
| `markdown-notes.gif`| Edit markdown notes in events or the daily notepad to add TODO items. |

Recommended: 16:9, ~1200×675, optimized (a few MB max). They're copied into the app bundle at build time
and loaded via `Bundle.module.url(forResource:withExtension:"gif", subdirectory:"tutorial")`.
