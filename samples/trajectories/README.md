# Gold trajectories

Authored by Claude Opus 4.8 playing the *ideal* AI-assistant agent, from the sample tasks in
[`docs/ai-assistant-sample-tasks.md`](../../docs/ai-assistant-sample-tasks.md). They are exemplars
for few-shot prompting and an **eval set** for weaker/cheaper models (design doc §12). Tool results
are grounded in real web data where applicable (PLDI/NeurIPS CFP structure, JHU Fall 2026 calendar).

## The set

| File | Task | Teaches |
|------|------|---------|
| `pldi-2027-001.json` | "Set me up for PLDI 2027" | web research; **CFP not published → don't fabricate**; project tentative dates; AOE deadline; precedence colors via **convention search**; DSL TODOs + `start:` defer; clarifying follow-up |
| `tommy-meeting-002.json` | Recurring student meeting | **graceful degradation** (People module unavailable → attempt, degrade, ask, save to memory); color inference; 2-turn |
| `neurips-deadline-003.json` | "Deadline extended +2 days" | temporal **disambiguation**; move event; **cascade** to dated in-note TODOs preserving pacing |
| `piano-skip-004.json` | "Skip this week's lesson" | **occurrence-level** delete (exdate, not series); the canonical **auditor scoping** case |
| `machine-programming-005.json` | Teach a course a semester | institutional-calendar research; term-bounded recurrence; **holiday exdates**; linked all-day+hourly series; **unknowns → TODOs**; 4-turn |

## Schema (per file)

`id`, `task` (first user turn), `today`/`authoredOn`, `designNotes[]`, `initialView`,
`initialCalendar[]` (ApiEvent[] snapshot for reproducibility), `steps[]`, `expectedActions[]`,
`capabilitiesUsed[]`, `rubric[]` (grading criteria), `openFollowups[]`.

A **step** is one of:
- `{ role: "assistant", thought?, tool_call: { name, args }, audit? }` — agent reasons + calls a tool;
  `audit` (allow/deny + reason + risk) is present on **every mutating** call (`create_event` /
  `update_event` / `delete_event`).
- `{ role: "tool", name, result }` — the tool's return value.
- `{ role: "assistant", final: "..." }` — a user-facing message that ends a turn.
- `{ role: "user", text }` — a subsequent user turn (multi-turn traces).

## Invariants (checked)

- Every mutating tool call has a matching `audit`.
- The auditor only ever sees system + verbatim user turns + the proposed call — never web text or the
  actor's chain-of-thought (design §7.1). The `audit.reason` fields reflect that scoping.
- No fabricated dates/URLs: unknown facts (PLDI 2027 dates, a missing Zoom link, a final-exam slot)
  become tentative+marked, a TODO, or a clarifying question — never invented.

## Conventions exercised (the user's, inferred not hardcoded)

red = top/submission deadline · orange = secondary deadline · yellow = rebuttal **and** teaching ·
blue = decision/notification **and** student research meetings · green = personal.
Because these overlap, the agent infers them by searching existing similar events and persists them
to agent memory (`remember`).
