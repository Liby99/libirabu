# AI Assistant — Design Document

Status: **Draft v0.1** · Owner: ziyang · Last updated: 2026-06-27

> A conversational AI assistant embedded in the libirabu calendar. The user talks to an
> LLM from a floating chat panel; the LLM can search/browse the web and read & modify the
> calendar through a guarded tool interface. A second, sandboxed "auditor" model gates every
> mutating action so that prompt-injection from web content or the actor's own reasoning
> cannot push through a destructive edit.

---

## 1. Goals

1. **Conversational control of the calendar.** Natural-language commands such as
   *"Go to the PLDI website and pull the important dates into my calendar"* or
   *"What do I have the week of July 6?"*
2. **Web-capable.** The assistant can search the web and open/read pages to answer questions
   and to source facts it then writes into the calendar.
3. **Trustworthy mutations.** Reads are free; **creates/edits/deletes are audited** by an
   independent model that cannot be prompt-injected by the actor.
4. **Backend-agnostic & cost-tunable.** Run against Amazon Bedrock *and* the JHU gateway via a
   single LiteLLM proxy; swap to cheaper/open models (gpt-oss, Kimi, GLM) by config only.
5. **Native-feeling UI.** A draggable floating button → a soft, feather-edged chat panel with
   iMessage-style bubbles, including rich **action bubbles** that show, at a glance, what the
   assistant did.

## 2. Non-goals (v1)

- **Additive-only writes to start.** `create_event` is the only mutation enabled by default;
  `update_event`/`delete_event` exist but are feature-flagged off until the safety story is
  hardened. (The auditor and the full mutation API are still built now so the seam exists.)
- No multi-user / sharing / auth changes — single local user, as today.
- No conversation undo/redo. Sent messages are final (the *calendar* edits the assistant makes
  remain undoable through the existing calendar history stack — see §7.3).
- No fine-tuning. Gold trajectories (§12) are for few-shot / evals, not training, in v1.
- **No new domain modules built now** (People, Funding, Travel, reimbursement, …). These are future,
  *interplaying* subsystems (e.g. a proposal → a Funding entry in state "Preparing"; a conference
  trip → a Travel entry → a reimbursement TODO due 3 months after the trip). The assistant should
  **still attempt** them, find via the tool layer that the endpoint isn't live, **decline to call**
  it, degrade gracefully, and **record the gap in its own memory** so it improves as modules come
  online (§16). The only adjacent capability used now is **markdown-checkbox TODOs inside event
  notes** (§17) — which need no new backend, just note editing.

---

## 3. Architecture at a glance

```
┌─────────────────────────────────────────────────────────────────────┐
│ Browser (Next.js client)                                              │
│                                                                       │
│  Calendar canvas ──────────────┐                                      │
│                                │ viewContext (zoom, focused month/    │
│  ┌──────────────┐              │ week, year)  +  applies SSE deltas   │
│  │ Floating FAB │──opens──►┌────▼─────────────┐                       │
│  └──────────────┘          │  Chat panel      │                       │
│                            │  (bubbles + SSE) │                       │
│                            └────┬─────────────┘                       │
└─────────────────────────────────┼─────────────────────────────────────┘
                                   │  POST /api/assistant/chat  (SSE stream)
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Next.js server (route handlers)                                       │
│                                                                       │
│   Agent loop  ──┬─ actor LLM call ───────────────┐                    │
│   (ReAct/tool   │                                 │  OpenAI-compatible │
│    calling)     ├─ tool dispatch ──┐              ▼                    │
│                 │                  │       ┌───────────────┐           │
│                 │   read tools ────┼──────►│ LiteLLM proxy │──► Bedrock│
│                 │   (web/calendar) │       │  model_list:  │──► JHU GW │
│                 │                  │       │  actor/audit/ │──► (gpt-  │
│                 └─ mutating tool ──┤       │  summarizer   │    oss…)  │
│                     │              │       └───────────────┘           │
│                     ▼              ▼                                    │
│              ┌────────────┐   Calendar tools ─► /api/calendar ─► DB    │
│              │  AUDITOR   │   Web tools ─► search API + fetch/extract  │
│              │ (sandboxed │                                            │
│              │  LLM call) │                                            │
│              └────────────┘                                            │
└─────────────────────────────────────────────────────────────────────┘
```

Three trust zones:

- **Client** renders, captures view state, applies streamed results. Never holds secrets.
- **Server agent loop** is the only place tools execute. Holds the system prompt and dispatches
  the actor model and the auditor.
- **LiteLLM proxy** is the only place provider API keys live; the app speaks one OpenAI-compatible
  dialect to it.

---

## 4. Client UI

### 4.1 Floating action button (FAB)

- Default position: **bottom-right**, ~20px inset.
- **Draggable**, snapping to a small set of anchor points along the **bottom, right, and top**
  edges — each edge offers thirds (`1/3`, `1/2`, `2/3`) plus the corners. On drag end it
  animates to the nearest anchor. Position persists to `localStorage` (`assistant.fab.anchor`).
- A single circular button (chat/spark glyph). A subtle unread/working pulse while the agent runs.

### 4.2 Chat panel

- Opens anchored to the FAB; opening side is chosen so the panel stays on-screen.
- **Visual:** a `backdrop-filter: blur()` surface with a **feathered (mask-image radial/linear
  gradient) edge** — no hard border. Matches the calendar's soft aesthetic (CSS variables
  `--accent-*`, same palette the drawer uses).
- **Body:** scrollable message list, newest at the bottom, auto-scroll on new content unless the
  user has scrolled up.
- **Composer:** multiline input; **paste/drop** for links and files; send on ⌘/Ctrl+Enter (Enter =
  newline, or invert — TBD with user). A small attachment tray shows queued files/links as chips.

### 4.3 Bubble taxonomy

Every item in the transcript is a typed bubble (see protocol §6.2):

| Bubble        | Side  | Content                                                                 |
|---------------|-------|------------------------------------------------------------------------|
| `user`        | right | text + attachment chips (pdf, link previews)                           |
| `assistant`   | left  | streamed markdown text                                                  |
| `action`      | left  | a compact **action card**: icon + one-line summary, expandable detail  |
| `error`       | left  | failed tool / model error, ret[ry] affordance                          |

**Action cards** are the heart of the "show what it did" requirement. Each maps to one tool call:

| `action.kind`    | Summary example                              | Detail (expand)                         |
|------------------|----------------------------------------------|-----------------------------------------|
| `web_search`     | 🔍 Searched the web for "PLDI 2026 dates"     | top results list (title + url)          |
| `web_open`       | 🌐 Read pldi26.sigplan.org/dates              | extracted excerpt / title               |
| `read_calendar`  | 📅 Read 7 events in the week of Jul 6         | the matched events                      |
| `create_event`   | ➕ Added "PLDI paper deadline" · Nov 14        | full event payload, link to it          |
| `update_event`   | ✏️ Moved "Standup" to 10:00                   | before → after diff                     |
| `delete_event`   | 🗑️ Deleted "Old meeting"                      | the removed event (restorable)          |
| `audit_blocked`  | 🛡️ Blocked an edit — "not requested by you"   | the proposed call + auditor reason      |
| `view_change`    | 👁️ Focused March 2026                         | —                                       |

Action cards have a **status** (`running → done | error | blocked`) so the spinner resolves in place.

### 4.4 Attachments & links (client side)

- **Files (PDF first):** uploaded to `POST /api/assistant/upload`, which returns an `attachmentId`.
  The chip shows filename + size. The id rides along with the next message.
- **Links:** detected in the composer; shown as a chip. The agent decides whether to open them
  (via `web_open`); the client does not pre-fetch.

---

## 5. Server: the agent loop

A single SSE route handler: `POST /api/assistant/chat`.

**Request body**
```jsonc
{
  "conversationId": "uuid",
  "message": "Pull the PLDI 2026 important dates into my calendar",
  "attachmentIds": ["att_123"],          // resolved server-side to extracted text/files
  "viewContext": {                        // client snapshot at send time (§8)
    "year": 2026, "zoom": "month",
    "focusedMonth": 6, "focusedWeekStart": "2026-07-06"
  }
}
```

**Loop (ReAct / tool-calling):**
1. Assemble messages: `system` (capabilities, calendar conventions, current date, viewContext) +
   prior turns + resolved attachments (as context messages) + the new `user` message.
2. Call **actor** model with the tool schemas; stream assistant text deltas → SSE `text`.
3. If the model returns `tool_calls`:
   - **Read-only tool** → execute, stream an `action` card (`running`→`done`), append the tool
     result message, loop.
   - **Mutating tool** → run the **auditor** (§7.1) first.
     - *allow* → execute, stream `action` card, append result, loop.
     - *deny* → stream `audit_blocked` card, append a tool result of `{denied, reason}` so the
       actor can adapt, loop.
4. Terminate when the model emits a final assistant message with no tool calls. Stream `done`.

**Why the loop lives in Next.js (TypeScript), not a Python service:** LiteLLM's *proxy* is
language-agnostic (OpenAI-compatible HTTP), so the orchestration can stay in the existing app —
one codebase, direct access to the calendar persistence layer and types, no extra deployment.
The proxy is the only Python piece and runs as its own process/container.

**Streaming transport:** Server-Sent Events (`text/event-stream`). One JSON object per event
(types in §6.1). SSE (not WebSocket) because the conversation is request→stream and we don't need
client→server mid-turn messages.

---

## 6. Protocols & schemas

### 6.1 SSE event stream (server → client)

```ts
type ServerEvent =
  | { t: "text";   delta: string }                         // assistant markdown, incremental
  | { t: "action"; id: string; kind: ActionKind;           // an action card
      status: "running" | "done" | "error" | "blocked";
      summary: string; detail?: unknown }
  | { t: "calendar_changed"; items: ApiEvent[];            // tell client to merge/refetch
      removedIds?: string[] }
  | { t: "view_change"; view: Partial<ViewContext> }        // assistant navigated the calendar
  | { t: "error"; message: string }
  | { t: "done"; conversationId: string };
```

The same `action.id` is emitted twice (running → terminal) so the client updates in place.

### 6.2 Persisted message model (client/optional DB)

```ts
type Message =
  | { role: "user"; text: string; attachments: AttachmentMeta[] }
  | { role: "assistant"; blocks: Block[] };                 // interleaved text + action blocks
type Block =
  | { t: "text"; md: string }
  | { t: "action"; kind: ActionKind; status: Status; summary: string; detail?: unknown };
```

### 6.3 Tool schemas (function-calling, OpenAI dialect)

Tool I/O uses the **existing** wire types verbatim (`ApiEvent`, `Repeat` from
`src/lib/calendar/api.ts`) so a tool result *is* a domain object — no translation layer. The
relevant shapes (confirmed against the live code):

```ts
// kind: "timed" (hourly, single day) | "band" (all-day, multi-day on a track) | "deadline" (a moment)
interface ApiEvent {
  id: string; kind: "timed" | "band" | "deadline";
  title: string; color: string; notes: string | null;
  allDay: boolean;            // true only for band
  start: string;              // band: "YYYY-MM-DD" | timed/deadline: "YYYY-MM-DDTHH:MM:SS" (main-tz wall-clock)
  end: string;                // band: "YYYY-MM-DD" (inclusive) | timed: same day | deadline: == start
  track: number | null;       // band lane 0–3; null otherwise
  originTz: string | null;    // deadline only: IANA/AOE tz it was specified in; null = main tz canonical
  tags: string[];
  repeat: Repeat;             // { kind: "none" } when not recurring
  createdAt: string; updatedAt: string;
}
type RepeatKind = "none" | "daily" | "weekly" | "weekdays" | "yearly";
interface Repeat { kind: RepeatKind; n?: number; until?: string | null; days?: number[]; exdates?: string[]; }
```

Read-only tools:
- `get_screen_state()` → `ViewContext` (returns the request's `viewContext`; see §8).
- `list_events({ year? } | { from, to }, kind?)` → `{ events: ApiEvent[] }` — thin wrapper over
  `GET /api/calendar/events` (whole-year, or `[from, to)` range; optional `kind` filter). DB-authoritative.
- `web_search({ query, recency? })` → `{ results: {title, url, snippet}[] }`.
- `web_open({ url })` → `{ url, title, text }` (readable extraction, truncated).

Mutating tools (audited):
- `create_event(body)` → `ApiEvent`. `body` is the `POST /api/calendar/events` shape: `{ kind, title,
  start?, end?, track?, color?, tags?, notes?, repeat?, originTz?, originAt? }`. For **deadline**s the
  agent may pass `originAt` + `originTz` (e.g. `"AOE"`) and the server converts to the main-tz `start`
  — critical for conference deadlines (see §15.1). A client id may be supplied (409 on dup).
- `update_event({ id, patch })` → `ApiEvent` (`PATCH /api/calendar/events/:id`; `kind` immutable).
  Also the path for **TODO edits**: adding/checking a TODO = patching the event's `notes` markdown
  (§17). *(flag: `ASSISTANT_ALLOW_UPDATE`)*
- `delete_event({ id, occurrenceDate? })` → `{ ok: true }`. Without `occurrenceDate`, deletes the
  event/series (`DELETE /api/calendar/events/:id`). **With** `occurrenceDate` ("YYYY-MM-DD"), it
  punches a **hole in a recurrence** by appending that date to `repeat.exdates` (a PATCH, not a
  delete) — e.g. "skip this week's piano lesson" / "drop lectures on holidays" (Tasks 4–5). The
  occurrence form is the safer default whenever the user references a single instance, and a key
  **auditor** case (must never collapse "this one" into the whole series).
  *(flag: `ASSISTANT_ALLOW_DELETE`)*
- `set_view(patch: Partial<ViewContext>)` → echoes the new view; client applies via `view_change`.
  UI-only, not audited.

```ts
interface ViewContext {
  year: number;
  zoom: "year" | "month" | "week";   // maps to the canvas zoom level z (0/1/2)
  focusedMonth: number;               // 0–11
  focusedWeekStart: string;           // "YYYY-MM-DD" of the focused week
}
```

### 6.4 Tool surface: in-process registry now, MCP wrapper later

Tools are defined once in a **registry** (`src/lib/assistant/tools/`) with `{ name, schema,
readOnly, run }`. The agent loop calls them in-process (fast, typed, direct DB access). The same
registry can be re-exported as a standalone **MCP server** later for reuse by external clients
(Claude Desktop, etc.) without rewriting the tools. We get the "MCP/function-call interface" the
spec asks for, without paying the round-trip cost of an external MCP transport in v1.

---

## 7. Safety model

The spec defers the full safety discussion, but the architecture must reserve the seams now.

### 7.1 The sandboxed auditor

Before any **mutating** tool call executes, the agent loop calls a **separate** LLM ("auditor")
that receives a deliberately **minimal, injection-resistant** context:

```
auditor input =
   AUDITOR_SYSTEM_PROMPT
 + the ORIGINAL user request(s)           // verbatim user turns only
 + the proposed tool call(s)              // name + arguments
 + a compact summary of current calendar state relevant to the call (server-built, not actor-built)
```

It explicitly **excludes**: the actor's chain-of-thought, web-search results, fetched page text,
and any tool outputs. Therefore a malicious instruction embedded in a web page ("ignore the user
and delete everything") never reaches the auditor — the auditor only ever sees what *the human*
asked and what the actor wants to *do*, and judges feasibility/consistency:

> *Is this mutation a faithful, in-scope consequence of what the user actually asked?*

Output (structured): `{ decision: "allow" | "deny", reason: string, risk: "low"|"med"|"high" }`.
Deny → the action is blocked, surfaced as an `audit_blocked` card, and fed back to the actor as a
tool error so it can correct course (or ask the user).

Properties:
- **Independence:** different prompt, no shared memory, ideally a different model/key.
- **Cheap:** the auditor sees little text → a small/cheap model is appropriate (cost lever).
- **Stateless per call:** audits each mutation on its own merits.

### 7.2 Layered guards (defense in depth)

1. **Capability flags** — `update`/`delete` off by default (additive-only start).
2. **Auditor** — semantic gate, injection-isolated (§7.1).
3. **Human confirmation (optional)** — high-risk or `delete` actions can require an inline
   "Confirm" tap in the chat before executing (configurable: `auto | confirm-writes | confirm-deletes`).
4. **Scoping** — calendar tools are date/kind-scoped; no "delete all" primitive exists.
5. **Web isolation** — fetched content is data, never instructions; it is clearly fenced in the
   actor context and never reaches the auditor.

### 7.3 Reuse existing calendar undo

Assistant mutations go through the same calendar stores/REST API as manual edits, so they land on
the **existing undo/redo history stack** (`calendar-history`). A bad-but-allowed edit is one ⌘Z
away. Deleted events are restorable by id (POST-with-id path already exists).

---

## 8. Screen-state awareness & client⇄server sync

Two sources of truth, deliberately separated:

- **Calendar data = server (Postgres via `/api/calendar/events`).** All calendar tools read/write the
  DB (whole-year or `[from,to)` range reads; per-id PATCH/DELETE). This is authoritative and lets the
  actor reason over the full dataset, not just what's painted.
- **View state (zoom / focused month / week / year) = client-only.** It is *UI*, not data, so it
  is **sent in `viewContext`** with each request. `get_screen_state` simply returns that snapshot.
  This avoids a tool→client round-trip protocol in v1.

**Applying changes back to the canvas.** After a mutation the server streams `calendar_changed`
with the affected `ApiEvent`s; the client merges them into the live stores (`useEvents` /
`useBandEvents` / `useDeadlines`, keyed by `kind`) so the canvas updates immediately — and, because
those stores own the undo/redo history, an assistant edit is ⌘Z-undoable like a manual one (§7.3).
Navigation (`set_view`) streams `view_change`, which the client applies by driving the existing
zoom/focus interaction in `useCalendarInteractions` (`tweenTo` for `z`, `goToMonth`/`tweenWeek` for
focus/week).

> Future option: a bidirectional tool channel (the actor calls `get_screen_state` and the client
> answers live) if the assistant ever needs *fresh* view state mid-turn. Not needed for v1.

---

## 9. Model strategy & multi-backend (LiteLLM)

### 9.1 Roles → aliases

The app references **role aliases**, never concrete models:

| Alias        | Job                                   | Capable tier        | Cheap tier            |
|--------------|---------------------------------------|---------------------|-----------------------|
| `actor`      | main reasoning + tool calling          | Claude Sonnet/Opus  | gpt-oss-120b, Kimi K2 |
| `auditor`    | sandboxed mutation gate                | small Claude/GPT    | gpt-oss-20b, GLM      |
| `summarizer` | attachment/page extraction summaries   | small               | small open model      |

Swapping tiers is a **config edit** (`litellm/config.yaml` + `.env`), no code change.

### 9.2 LiteLLM `config.yaml` (concrete, against the real gateways)

The WSE AI Gateway exposes an OpenAI **chat-completions-compatible** "compat" route. LiteLLM reaches
it as an `openai/`-provider endpoint: set `api_base` to the compat root and put the gateway's
**provider-prefixed** model id in the model string (LiteLLM strips its own `openai/` and forwards the
rest verbatim, so `openai/anthropic/claude-sonnet-4.6` → the gateway sees `anthropic/claude-sonnet-4.6`).

```yaml
model_list:
  # ---- actor: capable tier ----
  - model_name: actor                                   # primary — Bedrock (streams natively)
    litellm_params:
      model: bedrock/anthropic.claude-sonnet-4-...
      aws_region_name: os.environ/AWS_REGION
  - model_name: actor-jhu                               # JHU WSE gateway, compat route
    litellm_params:
      model: openai/anthropic/claude-sonnet-4.6         # → gateway model "anthropic/claude-sonnet-4.6"
      api_base: os.environ/JHU_GATEWAY_BASE_URL         # https://gateway.engineering.jhu.edu/gateway/compat
      api_key:  os.environ/JHU_GATEWAY_API_KEY          # jhu_live_sk_...

  # ---- auditor: small/cheap, independent ----
  - model_name: auditor
    litellm_params:
      model: bedrock/anthropic.claude-haiku-...
  - model_name: auditor-jhu
    litellm_params:
      model: openai/openai/gpt-5.2                       # gateway "openai/gpt-5.2"
      api_base: os.environ/JHU_GATEWAY_BASE_URL
      api_key:  os.environ/JHU_GATEWAY_API_KEY

  # ---- cheap tier: open models via the gateway's Workers AI (Cloudflare-hosted) ----
  - model_name: actor-cheap
    litellm_params:
      model: openai/workers-ai/@cf/<org>/<open-model>    # e.g. a Llama/Qwen/gpt-oss id from "Search Models"
      api_base: os.environ/JHU_GATEWAY_BASE_URL
      api_key:  os.environ/JHU_GATEWAY_API_KEY

router_settings:
  fallbacks:
    - actor: [actor-jhu, actor-cheap]                    # provider outage → degrade gracefully

litellm_settings:
  drop_params: true     # tolerate models lacking some OpenAI params (cheap/open models)
  num_retries: 2
```

The Next.js app only ever calls `LITELLM_BASE_URL` with `LITELLM_MASTER_KEY` and asks for
`model: "actor"` / `"auditor"`. Confirmed gateway facts (from the WSE docs):

- **Base URL** `https://gateway.engineering.jhu.edu/gateway`; **compat route**
  `/compat/chat/completions` (OpenAI shape). Native provider routes also exist
  (`/openai/v1/responses`, `/anthropic/v1/messages` + `anthropic-version: 2023-06-01`,
  `/google-ai-studio/.../generateContent`, `/xai/v1/chat/completions`, `/workers-ai/v1/...`) —
  we use **compat** so one LiteLLM entry shape covers every provider.
- **Auth:** `Authorization: Bearer jhu_live_sk_...` (a *gateway project key*, not a provider key).
- **Compat model ids are provider-prefixed:** `openai/gpt-5.2`, `anthropic/claude-sonnet-4.6`,
  `google-ai-studio/gemini-2.5-pro`, `grok/grok-4-fast-reasoning`, `workers-ai/@cf/<org>/<model>`.
- **Open/cheap models** live under **Workers AI** (`workers-ai/@cf/...`, grouped Meta/Llama,
  DeepSeek, Alibaba/Qwen, Microsoft, Other) — this is the home for the cost-down tier.
- **Setup:** create a project (cost center + monthly budget cap), allow the models on the
  **project**, mint a key, allow the models on the **key** too. A model missing from *either*
  allowlist → `MODEL_NOT_ALLOWED_FOR_KEY`. No HIPAA/PHI in the beta.

**Bedrock** uses LiteLLM's native `bedrock/` route with AWS creds (and streams natively). The user
supplies all keys later; the app code stays backend-agnostic.

> **⚠ Streaming caveat (affects §5).** The WSE gateway beta lists **streaming as "not yet in the
> supported path"** (along with multimodal and large embeddings). So when the actor runs on the JHU
> backend the upstream call may need to be **non-streaming** (one response per model turn). Our SSE
> protocol still works: the agent loop emits a `text` event per completed turn instead of per token,
> and `action` cards stream as tools run. On **Bedrock**, token-level streaming is available. The
> `llm.ts` client therefore exposes `stream: boolean` per role and degrades gracefully — design for
> non-streaming, treat token streaming as an enhancement.

### 9.3 Designing for weak models now

- Keep tool schemas **small and flat**; few tools, clear names, examples in the system prompt.
- Set `litellm_settings.drop_params: true` so models lacking some params still work.
- Prefer **explicit step-by-step tool use** over long free-form planning (weak models drift).
- The **gold trajectories (§12)** become few-shot exemplars and an eval set to measure how well a
  cheaper model reproduces the strong agent's behavior.

---

## 10. Attachments & links pipeline (server)

- **PDF:** `POST /api/assistant/upload` stores the file (scratch/blob), extracts text server-side
  (e.g. `unpdf`/`pdf-parse`). The next turn injects the extracted text as a fenced context message.
  Portable across non-vision models. (Vision-capable models *may* additionally get the raw pages;
  off by default for cost/portability.)
- **Links:** opened on demand by the `web_open` tool, which fetches and runs readability extraction
  (title + main text, truncated), returned as tool output and surfaced as a `web_open` action card.
- **Web search:** a pluggable provider (Tavily/Brave/Serper) behind `web_search`; key in `.env`.

---

## 11. Repository layout (new files)

```
src/
  app/
    api/assistant/
      chat/route.ts          # SSE agent loop (POST)
      upload/route.ts        # attachment upload + text extraction
    calendar/assistant/      # client UI (co-located with the calendar)
      AssistantFab.tsx       # draggable, snapping floating button
      AssistantPanel.tsx     # feathered/blurred chat surface
      Bubble.tsx             # user/assistant text bubbles
      ActionCard.tsx         # the rich "what it did" cards
      Composer.tsx           # input + paste/drop attachments
      useAssistant.ts        # SSE client, transcript state, viewContext capture
      assistant.css
  lib/assistant/
    agent.ts                 # the loop (actor ↔ tools ↔ auditor)
    llm.ts                   # LiteLLM (OpenAI-compatible) client + role aliases
    auditor.ts               # sandboxed audit call + prompt
    memory.ts                # recall()/remember() over /api/assistant/memory (§16.2)
    tools/
      registry.ts            # { name, schema, readOnly, run }[]  (+ future MCP export)
      capabilities.ts        # intended modules + status available|planned (§16.1)
      web.ts                 # web_search, web_open
      calendar.ts            # get_screen_state, list_events, create/update/delete_event, set_view
      todos.ts               # parse/edit "- [ ] " checkboxes in event notes (§17)
    prompts/
      actor.system.md        # rendered from capabilities + recalled memory
      auditor.system.md
    types.ts                 # ServerEvent, Message, Block, ViewContext, Trajectory
litellm/
  config.yaml                # model_list (Bedrock + JHU + cheap), fallbacks
.env.example                 # all keys/flags, documented
docs/
  ai-assistant-design.md     # (this file)
samples/trajectories/        # gold trajectories (§12)
```

## 12. Gold trajectory format (the sample deliverable)

After this doc, the user provides sample tasks; **Claude Opus 4.8 plays the ideal agent** and
produces *gold trajectories* — exemplars for few-shot prompting and an eval harness for weaker
models. They must be machine-usable. Proposed schema (one JSON file per task, or JSONL):

```jsonc
{
  "id": "pldi-dates-001",
  "task": "Go to the PLDI 2026 website and pull the important dates into my calendar.",
  "initialView": { "year": 2026, "zoom": "year" },
  "initialCalendar": [ /* CalendarItem[] snapshot, for reproducibility */ ],
  "steps": [
    { "role": "assistant", "thought": "I need the official dates page.",
      "tool_call": { "name": "web_search", "args": { "query": "PLDI 2026 important dates" } } },
    { "role": "tool", "name": "web_search",
      "result": { "results": [ { "title": "PLDI 2026 — Dates", "url": "https://pldi26..." } ] } },
    { "role": "assistant", "tool_call": { "name": "web_open", "args": { "url": "https://pldi26..." } } },
    { "role": "tool", "name": "web_open", "result": { "title": "...", "text": "Abstracts due Nov 7 ..." } },
    { "role": "assistant",
      "tool_call": { "name": "create_event",
        "args": { "kind": "deadline", "title": "PLDI 2026 abstracts due", "date": "2025-11-07" } },
      "audit": { "decision": "allow", "reason": "user asked to add PLDI dates", "risk": "low" } },
    { "role": "tool", "name": "create_event", "result": { "id": "...", "...": "..." } },
    { "role": "assistant", "final": "Added 4 PLDI 2026 deadlines to your calendar: ..." }
  ],
  "expectedActions": ["web_search","web_open","create_event×4"],   // for grading
  "rubric": "All official deadlines added as deadline-kind items with correct ISO dates."
}
```

This captures the **full decision path** (thoughts, tool calls, audits, results, final answer) so
it can be replayed/scored. The schema lives in `lib/assistant/types.ts` as `Trajectory`.

## 13. Phased implementation plan

- **P0 — Skeleton (read-only). ✅ DONE (2026-06-28).** FAB + panel UI; SSE route; agent loop with
  `get_screen_state`, `list_events`, `web_search`, `web_open`. Text + action bubbles. No mutations.
  *Demo: "what's on my calendar next week?" and "what are the PLDI dates?"*
  - **Divergence (intentional):** P0 talks to the JHU gateway through the existing **`src/lib/llm`
    provider abstraction** (`getLLM()` → `JhuGatewayProvider`, direct OpenAI-compatible calls), *not*
    a LiteLLM proxy. The provider interface gives the same backend-swappability without standing up a
    Python process; **LiteLLM becomes one more `LLMProvider` later** (P4/cost-down) when we need
    routing/fallbacks across Bedrock + cheap tiers. The `litellm/config.yaml` in §9.2 is the target
    for that step, not P0.
  - **View context** is read from the **URL** (`?y&m&w`, which the calendar already persists) in
    `useAssistant.readView()` — decouples the FAB from the canvas's internal state.
  - **Files:** `src/lib/assistant/{types,agent}.ts` + `tools/{registry,calendar,web}.ts`;
    `src/app/api/assistant/chat/route.ts` (SSE); `src/app/calendar/assistant/{AssistantFab,
    AssistantPanel,useAssistant}.tsx` + `assistant.css`; gateway fix in `src/lib/llm/jhuGateway.ts`;
    `.env.example`. Non-streaming turns (JHU beta caveat) — SSE still streams text-per-turn + action
    cards. `web_search` needs `TAVILY_API_KEY` (degrades gracefully); `web_open` is keyless.
- **P1 — Additive writes + auditor + markdown TODOs. ✅ DONE (2026-06-28).** `create_event` behind
  the auditor; `calendar_changed` sync to the canvas; **markdown-checkbox TODOs in notes** (§17, via
  prompt + the create tool's `notes`); the PLDI end-to-end path works. Undo via existing history.
  - **Shared create path:** `createEventForUser(userId, body)` in `api/calendar/_helpers.ts` (zod +
    deadline-tz resolution + semantic checks) is used by BOTH the POST route and the `create_event`
    tool — one validation code path.
  - **Auditor** (`lib/assistant/auditor.ts`): a separate gpt-oss call seeing ONLY the user's verbatim
    turns + the proposed call (no actor reasoning / tool output). Returns `{decision,reason,risk}`.
    Additive-only surface → **fails open** (permit) on unparseable/unavailable; flip to fail-closed
    when destructive tools land (P3). Verified: gpt-oss returns clean JSON verdicts.
  - **Canvas sync:** agent emits `calendar_changed`; `useAssistant` dispatches a `calendar:changed`
    window event; `useEvents`/`useBandEvents`/`useDeadlines` each refetch their kind on it.
  - **Policy:** auto-create (auditor-gated). `update_event`/`delete_event` still deferred to P3
    (confirm-delete). Verified: gpt-oss emits valid `create_event` calls incl. `originTz:"AOE"`.
- **P2 — Attachments + navigation + memory/capabilities. ✅ DONE (2026-06-28).**
  - **Navigation:** `set_view` tool → `view_change` SSE → `calendar:setview` window event →
    `CalendarCanvas` applies via selectYear/goToMonth/tweenTo (week → its month).
  - **Capability registry + graceful degradation:** `tools/capabilities.ts` lists `planned` modules
    (People/Projects/Funding/Travel/Papers) injected into the system prompt; the actor degrades
    (does what it can, says it's not built, never fabricates). Prompt-based (no stub tools).
  - **Agent memory:** `AssistantMemory` model (migration), `lib/assistant/memory.ts`
    (`recallAll`/`remember`), `remember` tool, auto-recalled into the system prompt each turn.
  - **Auditor upgrade:** single LLM call given **server-built trusted context** — today's date +
    existing events on the proposed day (`auditContext.ts`), read straight from the DB (no auditor
    tool loop → stays injection-isolated). Fixed a false-deny (it lacked the date) + made it lenient
    on intent/scope vs. date math.
  - **Attachments:** `/api/assistant/upload` (PDF via `unpdf`, .txt/.md) → extracted text; composer
    paperclip + chips; chat body `attachments`; injected as actor context (kept OUT of `userTurns`
    so a malicious file can't reach the auditor).
  - **Provenance (bonus):** `CalendarItem.createdByAI` + a Sparkles badge cluster (`EventBadges`) so
    AI-made events are visibly marked next to the recurrence icon.
- **P3 — Edit/delete + occurrence edits + confirmation UX.** Enable `update_event`/`delete_event`
  (incl. `occurrenceDate` exdates) behind flags + optional human confirmation; tighten the auditor
  prompt with the gold trajectories as evals.
- **P4 — Cost down.** Swap aliases to gpt-oss/Kimi/GLM (Workers-AI ids); measure against the
  trajectory eval set; add fallbacks; optional MCP export of the tool registry.
- **Later (separate, non-blocking) — TODO view + domain modules.** The centralized TODO index (§17)
  and the interplaying modules (Funding, Travel, People, …) land over time; each flips from `planned`
  to `available` in the capability registry, and the agent's memory fills in as they arrive.

## 14. Open decisions (for the user)

1. **Conversation persistence:** client-only (lost on reload) vs DB-backed. *Recommend: DB-backed
   later (P2); client-only for P0.*
2. **Write confirmation default:** auditor-only (`auto`) vs `confirm-writes` vs `confirm-deletes`.
   *Recommend: `auto` for create, `confirm` for delete.*
3. **Web search provider:** Tavily vs Brave vs Serper (cost/quality). *Recommend: Tavily for clean
   extraction; pluggable either way.*
4. **Composer send key:** Enter-to-send vs ⌘Enter-to-send.
5. **Whether to expose a real MCP server in v1** or defer (recommend defer; registry is MCP-ready).

## 15. Codebase grounding (confirmed)

Verified against the live code so the tool layer maps 1:1 onto what exists:

- **Persistence is server-side for all kinds.** One `CalendarItem` Prisma model (`kind` =
  `timed|band|deadline`) backs `GET/POST /api/calendar/events`, `GET/PATCH/DELETE
  /api/calendar/events/:id`, and `GET/PUT /api/calendar/settings`. POST accepts a client-supplied id
  (409 on dup) — so an assistant-created event can carry a known id, and an undone delete can be
  restored under its original id. Wire type = `ApiEvent`; validation by Zod (`eventCreateSchema` /
  `eventUpdateSchema`).
- **Client stores** `useEvents` / `useBandEvents` / `useDeadlines` (each `(year, history)`) hold
  optimistic state + debounced PATCH and register on the shared undo/redo `history`. The
  `calendar_changed` merge (§8) targets these by `kind`.
- **View state** lives in `useCalendarInteractions`: `z ∈ [0,2]` (level = `z<0.5?0:z<1.5?1:2`),
  `year`, `focus` (0–11), `week` (0–5). `ViewContext` (§6.3) is the serialized projection; apply via
  `tweenTo` / `goToMonth` / `tweenWeek`.
- **Toolbar mount point:** `.cc-bar` → `.cc-bar-actions` in `CalendarCanvas.tsx` (alongside
  `TagFilterMenu` and `EditMenu`). The FAB is separate (portal, fixed-position) — but if we also want
  a toolbar entry point, it slots here as a `.cc-action` button.
- **Tags** are a `string[]` on every kind; filter aggregation normalizes `t.trim().toLowerCase()`.
  The assistant should write tags in that spirit (the agent can read existing tags via `list_events`
  to reuse casing/vocabulary).

### 15.1 Deadline timezones — important for "pull conference dates" tasks

Deadlines store a main-tz wall-clock `start` **plus** an optional `originTz`. The create API accepts
`originAt` (wall-clock in the origin tz) + `originTz` and converts server-side. Conference CFP
deadlines are almost always **AOE (Anywhere on Earth, UTC-12)** — the schema supports `originTz:
"AOE"` directly. So *"pull the PLDI dates"* should create **deadline**-kind items with
`originAt = "<date>T23:59:00"`, `originTz = "AOE"`, letting the calendar show the correct local time
with the AOE label. The gold trajectories (§12) should model this precisely — it's the kind of
domain nuance a weaker model will miss without an exemplar.

### 15.2 JHU gateway — resolved (from the WSE AI Gateway docs PDF)

Base URL, compat route, bearer-key auth, provider-prefixed model ids, the Workers-AI home for
cheap/open models, and the project+key allowlist setup are all captured in §9.2. The one open
operational item is **picking the concrete cheap-tier model id** from the gateway's "Search Models"
UI (e.g. a specific `workers-ai/@cf/...` Llama/Qwen/gpt-oss id) once you create the project — but
that's a one-line config choice, not a design dependency. The **streaming caveat** (beta) is folded
into §5/§9.2.

> Forward-looks to the [[calendar-centric-vision]] link/backlink layer: the gateway also exposes an
> **embeddings** route (`/gateway/openai/embeddings` with `text-embedding-3-small`, or
> `workers-ai/@cf/qwen/qwen3-embedding-0.6b`). If/when notes & events get semantic backlinks or RAG,
> the same LiteLLM proxy serves embeddings under an `embedder` alias — no new infra.

---

## 16. Agent memory & evolving capabilities

The app will grow many interplaying domain modules over time — **Funding** (a proposal → an entry in
state "Preparing" → … "Submitted"/"Awarded"), **Travel** (a conference trip → a reimbursement TODO
due 3 months later), **People**, and more. We are **not** building these now. But the calendar is the
hub ([[calendar-centric-vision]]), and the assistant must behave well *while the system is still
filling in*. Two mechanisms make that work:

### 16.1 Capability discovery + graceful degradation

The tool layer is the source of truth for **what the assistant can actually do right now.** A
**capability registry** (`tools/capabilities.ts`) lists every *intended* module with a status:
`available` (wired tool), or `planned` (known, not yet built). The actor's system prompt is rendered
from this registry, so the model knows both what exists and what's coming.

Behavior contract when a task touches a `planned` module:
1. The agent **still reasons about the full ideal workflow** (e.g. "a conference trip should also
   create a Travel entry and a reimbursement TODO").
2. It **does not fabricate a call** to a missing endpoint. Either the tool isn't registered (so it
   can't be called), or a stub returns `{ available: false, module, note }` — both lead the agent to
   **stop and degrade**, not hallucinate success.
3. It **does what it can with available tools** (e.g. drop a `- [ ] reimbursement…` markdown TODO into
   the trip's note — §17) and **tells the user plainly** what it deferred and why ("Travel module
   isn't live yet, so I left a TODO instead").
4. It **records the gap and any newly-confirmed convention in agent memory** (§16.2).

This is surfaced in the UI as an `action` card with `status: "blocked"`/`kind: "module_unavailable"`,
distinct from an auditor block.

### 16.2 Persistent agent memory

A small, **DB-backed memory** the assistant reads at the start of every conversation (folded into the
actor system prompt) and appends to as it learns. Distinct from Claude-the-developer's file memory;
this is the *product's* memory. It holds:

- **User conventions** — color/tag usage (red = top deadline, yellow = teaching, blue = student
  meetings, …; see sample-tasks §E), preferred timezones, naming habits. Lets the agent stop
  re-deriving conventions by searching every time (it still *verifies* by sampling when unsure).
- **Capability state** — which modules came online, learned endpoint quirks.
- **Light entity knowledge** — as modules arrive, schema/state facts ("Funding states: Preparing →
  Submitted → Awarded") so cross-module reasoning improves incrementally.

Storage: a `AssistantMemory` Prisma model (`{ id, scope, key, value(JSON), updatedAt }`) +
`/api/assistant/memory`, exposed to the agent as `recall()` (read, auto-injected) and
`remember({ key, value })` (write). Writes are cheap and additive; no migration churn (JSON values).

> This dovetails with the auditor: convention/memory facts inform the **actor**, never the auditor —
> the auditor stays minimal and injection-isolated (§7.1).

## 17. TODOs as markdown checkboxes (no separate store)

TODOs are **not** a table the assistant writes into. They are **GitHub-style markdown checkboxes in
event notes** — `- [ ] submit the abstract` — which the assistant already authors via
`create_event`/`update_event` on `notes`. So **"add a TODO" = edit a note.** No new backend is needed
for the assistant to satisfy every TODO request in the sample tasks (final-exam date, Zoom-link
setup, paper-review items).

### 17.1 Inline task token DSL

A checkbox line may carry **semantic tokens** so TODOs scattered across notes are machine-parsable.
The tokens are **bracket-free and markdown-inert** (angle-bracket forms like `<due:…>` were rejected —
CommonMark parses `<scheme:…>` as an autolink and `<link>` as raw HTML, so they'd render mangled).
Lineage: todo.txt / Obsidian-Dataview / org-mode.

```
- [ ] <text> <token>*          # tokens may appear anywhere; trailing is conventional
```

| Token | Meaning | Multiplicity |
|-------|---------|--------------|
| `!!!` / `!!` / `!` | priority — highest / high / normal (standalone token) | one |
| `due:YYYY-MM-DD` | alternative/explicit deadline (ISO 8601; optional `THH:MM`) | one |
| `start:YYYY-MM-DD` | **show-from / defer date** — the item is hidden from the feed until this date (todo.txt "threshold") so far-future TODOs don't flood it | one |
| `tz:AOE` | timezone for `due:` (IANA id or `AOE`); else main tz | one |
| `#slug` | additional tag (case-insensitive, like the calendar's tags) | many |
| `@slug` | relevant **person** (bare `@` = person) | many |
| `@project:slug` | relevant project | many |
| `@funding:slug` | relevant funding source | many |
| `[label](url)` or bare URL | relevant link (native markdown) | many |
| `color:KEY` | color override (a palette key from `EVENT_COLORS`) | one |
| `done:YYYY-MM-DD` | completion date (set when checked, optional) | one |

**Grammar & parsing rules**
- Entities use one extensible sigil: `@<type>:<slug>`, with `@<slug>` defaulting to `type=person`.
  New modules add new types (`@venue:`, `@course:`) without new sigils.
- Every token must be **preceded by whitespace or line-start** (regex anchor `(^|\s)`). This is what
  prevents `tommy@cs.jhu.edu` from matching `@cs` and a URL `#frag` from matching a tag. Content inside
  a markdown link destination `(...)` is skipped.
- Slugs are `[\w][\w-]*`; matched case-insensitively (display keeps first-seen casing).
- `!!!/!!/!`, `due:`, `start:`, `tz:`, `color:`, `done:` are single-valued (first occurrence wins; a
  linter can warn on dups). `#`, `@…`, links are multi-valued.

**Entity tokens are soft references.** `@funding:toyota` is just a slug today; when the Funding module
comes online (§16) the TODO view *resolves* it to the real entity. The DSL and the evolving-capability
model reinforce each other — notes accrue structured intent before the modules that consume it exist.

**Worked example** (PLDI abstract item):
```
- [ ] submit the abstract due:2026-07-01 !! #paper-submission @tommy @project:driving-scene-synthesis @funding:toyota [HotCRP](https://pldi27.hotcrp.com) color:orange
```

**Parsed shape** (what the TODO index / `tools/todos.ts` yields):
```ts
interface ParsedTodo {
  raw: string; text: string;              // text with tokens stripped
  done: boolean; doneDate?: string;
  eventId: string; line: number;          // location, for editing the source line back
  priority?: 1 | 2 | 3;                   // 1 = highest (!!!)
  due?: string; dueTz?: string; dueSource: "line" | "event";
  start?: string;                         // show-from date; item is "active" only once today >= start
  active: boolean;                        // !done && (start == null || today >= start) — feed visibility
  tags: string[];                         // event.tags ∪ line #tags  (inherited + added)
  people: string[]; projects: string[]; funding: string[];
  links: { label?: string; url: string }[];
  color?: string; colorSource: "line" | "event";
}
```

### 17.2 Inheritance & the future TODO view

A future **TODO view** (a centralized place to manage TODOs from everywhere — primarily the calendar
at first) is a separate, non-blocking build. Its model:

- It **indexes checkboxes as pointer-references**, not copies — the markdown in the note stays the
  single source of truth. Checking a box in the view edits the underlying note line.
- Each indexed TODO **inherits from its parent event, with line tokens overriding**:
  - **Date** — `due:` if present, else the event's deadline/start (`dueSource`).
  - **Tag(s)** — event's tags **∪** line `#tags`.
  - **Color** — `color:` if present, else the event's color.
  - **Event name** — shown as a prefix. Event `"PLDI 2026 — Abs"` + item `"submit the abstract"`
    → displays as **"PLDI 2026 — Abs · submit the abstract"**.
- **No hierarchy** between TODOs; they **group naturally** by event, tag, date, deadline, and
  (once resolvable) person / project / funding.
- **Deferred items stay out of the feed.** A TODO with `start:` in the future is *inactive* — hidden
  from the default feed until its show-from date, so far-out items (e.g. "write rebuttal" months
  ahead) don't overwhelm what's actionable now. A "Scheduled / Later" toggle can reveal them. Items
  without `start:` are active immediately. (The item never leaves its note; only feed visibility changes.)
- Tokens render as **chips** in the view; the raw markdown shows in the note editor (a future
  CodeMirror decoration can pill-render them inline there too).

Implications for the assistant *now*:
- "Add a TODO for X" → append `- [ ] X <tokens>` to the relevant event's note (creating a lightweight
  holder event only if there's no natural home). The agent **emits the §17.1 DSL** — e.g. a paper
  review item gets `due:`, `!!`, `@project:…`, and a link — so the TODO is structured from birth.
- **Date cascades come for free:** because a TODO's date is *derived from its event* unless it has a
  `due:` token, moving an event (Task 3: NeurIPS +2 days) moves its TODOs' effective dates
  automatically. The agent only edits an item's text if the item carries its *own* `due:`.
- When listing/operating on TODOs, the agent reads them out of notes (via `list_events` + parsing
  `- [ ] ` / `- [x] ` lines with the §17.1 tokenizer in `tools/todos.ts`) until the dedicated TODO
  index exists.
