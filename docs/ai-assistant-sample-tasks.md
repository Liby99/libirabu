# AI Assistant — Sample Tasks (gold-trajectory seeds)

Status: **Living doc** · Owner: ziyang · Last updated: 2026-06-27
Companion to [`ai-assistant-design.md`](./ai-assistant-design.md). These are user-authored example
tasks with the *ideal* agent behavior. They serve three jobs:

1. **Gold trajectories** — Claude Opus 4.8 plays the ideal agent and records full traces (thoughts →
   tool calls → audits → results → final) per design §12, for few-shot prompting + evals of cheaper models.
2. **Capability spec** — what tools/subsystems must exist (see §"Capabilities surfaced").
3. **Behavior spec** — what *good* looks like: proactive clarifying questions, convention inference,
   surgical recurrence edits.

> More examples will be added over time. Each task uses the same template:
> **User** (verbatim) · **Ideal trajectory** · **Follow-ups** · **Variations** · **Generalizes to** ·
> **Capabilities exercised**.

---

## Task 1 — Conference submission setup (PLDI 2027)

**User:** "I plan to submit to PLDI 2027. Please set me up on my calendar."

**Ideal trajectory:**
1. `web_search` → `web_open` the **PLDI 2027 Call for Papers**; extract the **abstract deadline**,
   **full-paper submission deadline**, **rebuttal period**, and **decision/notification** date.
2. Create the dates on the calendar:
   - Most are **all-day (band) events**.
   - The **full-paper deadline** is a **precise `deadline`** with an exact timezone — e.g.
     `12:00am AOE on July 8` → `originTz: "AOE"`, `originAt: "2027-07-08T00:00:00"` (server converts
     to main-tz `start`). *This is the AOE nuance from design §15.1.*
3. **Tags** on every item: `paper-submission`, `research`.
4. **Colors by precedence/importance** (full-paper is the most important):
   | Item | Importance | Color |
   |------|-----------|-------|
   | Full-paper submission deadline | highest | **red** |
   | Abstract deadline | high | **orange** |
   | Rebuttal period | medium | **yellow** |
   | Decision / notification | info | **blue** |
   - **If unsure how to map a color**, the agent **searches existing similar events** (e.g.
     `list_events` filtered by tag `research`/`paper-submission`) and matches their color convention
     rather than guessing.
5. **Notes (markdown)** on the events: add the important **links** — the submission site (HotCRP/
   submission URL), the CFP page, etc.

**Good follow-up (agent → user):** *"What do you plan to submit? Is it tied to a specific project?"*
(Captures the paper title / project so notes and tags can be enriched.)

**Generalizes to:** any **call-for-papers / call-for-proposals** ("set me up for NSF CAREER", "ICFP
2027", grant deadlines) — same shape: scrape dates → typed events → precedence colors → tags → link
notes.

**Capabilities exercised:** `web_search`, `web_open`, `create_event` (band + AOE deadline),
timezone handling, tags, **color-convention inference via search**, markdown-link notes,
proactive clarifying question.

---

## Task 2 — Schedule a recurring student meeting (Tommy)

**User:** "My student Tommy is trying to schedule a meeting on the topic of 'Driving Scenario
Synthesis' on Monday 1pm. Help me do that."

**Ideal trajectory:**
1. Create a **recurring hourly (`timed`) event**, Mondays 1:00–2:00pm, `repeat: { kind: "weekly",
   days: [1] }`.
2. Tag `research`.
3. Color **blue** — *user convention: blue = research meetings with students.*
4. Search the **People** directory for "Tommy" → resolve his **full name** and **email**.
5. Put it in the **notes**: *"Tommy is going to be there. Email: <tommy@…>."*

**Variation — Tommy is not in People:**
- Agent reports it can't find Tommy. User replies with Tommy's info.
- Agent then **(a)** updates the meeting notes with that info, **and (b)** **adds Tommy to People**
  (write to the People directory) so he's resolvable next time.

**Good follow-ups (agent → user):** *"Is anyone else joining the meeting?"* · *"Is there a document
link I should add to the notes?"*

**Generalizes to:** any meeting that references **people** by first name — resolve identity, enrich
notes, and self-heal the directory when someone's missing.

**Capabilities exercised:** `create_event` (recurring timed), tags, **user color convention**,
notes enrichment, proactive clarifying questions, **People (deferred → graceful degradation, §C)**.

---

## Task 3 — Shift a deadline + cascade to TODOs (NeurIPS review extended)

**User:** "The deadline for NeurIPS review is extended by two days."

**Ideal trajectory:**
1. Find the **NeurIPS review deadline** event (disambiguate by *nearest to now* — reviews happen
   around the time the question is asked).
2. `update_event` → move it **+2 days**.
3. **Cascade to TODOs:** if markdown notes contain **TODO items** tied to this deadline, open the
   **TODO module** and update their due dates by +2 days too. Here the TODOs are likely **~5 papers
   to review**, each with a **name + link** and a per-paper due date.

**Generalizes to:** any "X moved by N days/to DATE" where dependent TODOs/sub-deadlines must move in
lockstep.

**Capabilities exercised:** event lookup + temporal disambiguation, `update_event`,
**markdown-TODO edits in notes** with automatic date cascade via the parent event (§D).

---

## Task 4 — Cancel one occurrence of a recurrence (piano lesson)

**User:** "I'm not going to make it to this week's piano lesson."

**Ideal trajectory:**
1. Find the **piano lesson** recurring event.
2. Remove **only this week's occurrence** — punch a **hole in the recurrence** (an **exception /
   `exdate`** for this week's date), **not** the whole series.

> Maps cleanly onto the existing schema: `Repeat.exdates: string[]`. The tool surface needs an
> **occurrence-level** delete: `delete_event({ id, occurrenceDate })` adds an exdate rather than
> deleting the series.

**Generalizes to:** "skip", "cancel just this one", "move only this week's <recurring thing>".

**Capabilities exercised:** recurring-event lookup, **occurrence-level edit (exdate)**, careful
scoping (single instance vs series) — a prime **auditor** case (must not delete the whole series).

---

## Task 5 — Set up a taught course for a semester (Machine Programming, Fall 2026)

**User:** "I'm going to teach the course Machine Programming for the Fall 2026 on Tuesday and
Thursday. Can you help me set up the calendar for that?"

**Ideal trajectory:**
1. `web_search` → `web_open` the **JHU Fall 2026 academic calendar / schedule**; find the
   **semester start & end**, and the **first day of class** (the first Tuesday).
2. Create an **all-day (band) event** on the **first day of class** with **recurrence Tue + Thu**
   (`repeat: { kind: "weekly", days: [2, 4], until: <semester end> }`).
3. Color **yellow** — *user convention: teaching activities are yellow.*
4. Tags: `teaching`, `lecture`, `machine-programming`.
5. Find **holidays/breaks** within the semester and **remove the affected lectures** (exception
   `exdate`s for those dates — same mechanism as Task 4, applied per holiday).

**Follow-up chain (this is the rich one):**
- **Agent asks:** *"What are the exact class times on Tue/Thu?"*
  - **User:** "3:00–4:15pm."
    - **Agent:** also create **recurring hourly (`timed`) events**, Tue/Thu 3:00–4:15pm, with the
      **same formatting** (yellow, same tags, same holiday exdates) as the all-day series.
- **Agent asks:** *"What's the course website, and do you have a Zoom link for the class?"*
  - **User:** "I don't know the Zoom link; I'll set it up later."
    - **Agent:** add a **TODO under `teaching`**: *"Create recurrent Zoom meeting and share the
      Zoom link."*
- **Agent asks:** *"When is the final exam?"*
  - **User:** "I don't know that either."
    - **Agent:** add a **TODO**: *"Confirm final exam date."*

**Generalizes to:** any recurring, semester/term-bounded commitment driven by an institutional
calendar (a recurring seminar series, lab meeting, office hours) — scrape term bounds → recurring
events → holiday exdates → spawn TODOs for unknowns.

**Capabilities exercised:** `web_search`/`web_open` (institutional calendar), `create_event` (band +
timed, recurring, term-bounded), **holiday exdates**, tags, color convention, **consistent
formatting across linked event sets**, **markdown-TODO checkboxes in notes** (§D), and the strongest
example of **turning unknowns into TODOs** via clarifying questions.

---

## Capabilities surfaced (implications for the design)

These tasks confirm the planned tools **and surface two new subsystems** not yet in
`ai-assistant-design.md`. Folding these in is the next design step.

### A. Confirmed against the current design
- `web_search` / `web_open` — every "go find the dates/schedule" task.
- `create_event` for all three kinds, **recurring** and **term-bounded**.
- `update_event` — Task 3 (shift), with **date math**.
- **AOE / precise-timezone deadlines** — Task 1 (design §15.1 already covers this).
- Tags + markdown-link notes.

### B. Recurrence: occurrence-level edits (small extension)
Tasks 4 & 5 need **exception edits**, not series edits. The schema already has `Repeat.exdates`.
Add an occurrence-aware delete/move:
- `delete_event({ id, occurrenceDate })` → append `occurrenceDate` to `exdates` (a "hole").
- (Future) `move_occurrence({ id, occurrenceDate, to })` → exdate + a one-off event.
This is a **high-value auditor case**: "cancel this week's lesson" must never collapse to "delete the
series."

### C. **People** (and other domain modules) — DEFERRED, learned via agent memory
People is **not built now**, and neither are the other interplaying modules these tasks gesture at:
**Funding** (proposal → entry in state "Preparing"), **Travel** (trip → reimbursement TODO due ~3
months later), etc. Per design **§16**, the assistant should:
- **still attempt** the ideal workflow (e.g. resolve "Tommy" against People),
- find the module's tool **unavailable** (not registered, or a stub returns `available: false`),
- **degrade gracefully** — do what it can with available tools, and **tell the user** what it
  deferred (Task 2 variation: ask the user for Tommy's info, put it in the note; *adding him to a
  People directory waits until that module exists*),
- **record the gap + any confirmed convention in agent memory** so it improves as modules come online.

So Task 2's "search People / add Tommy to People" is the *aspirational* trajectory; the *currently
runnable* trajectory creates the meeting, asks for Tommy's details, and writes them into the note.

### D. **TODOs = markdown checkboxes in event notes** (no separate store) — Tasks 3 & 5
Per design **§17**, a TODO is a GitHub-style checkbox **inside an event's note** — authored via
`update_event`/`create_event` on `notes`. Each line may carry the **inline task token DSL** (design
**§17.1**): `!!!/!!/!` priority, `due:YYYY-MM-DD` (+`tz:`), `#tag`, `@person`, `@project:slug`,
`@funding:slug`, `[label](url)`, `color:`. Tokens are bracket-free/markdown-inert; entities are
**soft references** that resolve once their module exists. **No TODO backend is needed** for any
sample task. So:
- Task 5 "add a TODO under teaching: create recurrent Zoom meeting" → append to the **lecture
  event's note**: `- [ ] create recurrent Zoom meeting and share the Zoom link #teaching`.
- Task 5 "add a TODO: confirm final exam date" → `- [ ] confirm final exam date #teaching` (gets a
  `due:` once the date is known).
- Task 3 "5 papers to review, each name + link + due date" → checkboxes in the NeurIPS event's note,
  e.g. `- [ ] review "Paper Title" [pdf](https://…) due:2026-08-12 !! @project:driving-scene-synthesis`.

A future **centralized TODO view** indexes these checkboxes as **pointer-references** (not copies),
enriches each with **date (from the event's deadline/start)**, **tag(s) (from the event)**, and an
**event-name prefix** (`"PLDI 2026 — Abs · submit the abstract"`), with **no hierarchy** — grouped
naturally by event/tag/date. That view is a separate, non-blocking build.

- **Date cascade is automatic** (Task 3): because a TODO's date derives from its parent event, moving
  the NeurIPS deadline event +2 days moves its TODO dates too. The agent only edits an item's *text*
  if that item carries its **own inline date**.

### E. User **color & tag conventions** (cross-cutting behavior)
Colors are **personal conventions**, context-dependent and sometimes overlapping:
| Convention (observed) | Source |
|---|---|
| **red** = most important deadline (full-paper) | Task 1 |
| **orange** = secondary deadline (abstract) | Task 1 |
| **yellow** = lower-tier deadline (rebuttal) **and** teaching activities | Tasks 1, 5 |
| **blue** = decision/notification **and** research meetings with students | Tasks 1, 2 |

Because conventions overlap and aren't globally fixed, the agent must **infer from context** — the
explicit rule in Task 1 is: *when unsure of a color, search existing similar events and match their
color.* Recommendation: a lightweight **"learn conventions" preamble** where the agent may
`list_events` by tag to sample the user's existing color/tag usage before assigning. (Future: persist
learned conventions in prefs.)

### F. **Proactive clarifying questions** (behavior, not a tool)
Every task has *good follow-up questions* the ideal agent asks (what are you submitting? who else is
joining? exact times? course site/Zoom? final exam?). These are part of the gold standard: a good
agent **asks before assuming** and **turns "I don't know" into a TODO** rather than dropping it.

---

## Trajectory authoring checklist (when turning each task into a gold trace)

- Record **thoughts** (brief), each **tool_call** with args, each **tool result**, and for every
  mutation the **auditor verdict** (allow/deny + reason) per design §12.
- Pin an `initialCalendar` (+ `initialPeople`/`initialTodos` once those exist) and `initialView` for
  reproducibility.
- Include the **clarifying-question turns** and the **variations** (e.g. Task 2's missing-Tommy
  branch) as separate trajectories or branches.
- State the **rubric** (what a correct outcome must contain) for grading weaker models.
