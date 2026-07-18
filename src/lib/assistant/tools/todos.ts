// TODO tokenizer — the single source of truth for the inline task-token DSL (design §17.1).
//
// TODOs are GitHub-style markdown checkboxes living inside an event's `notes` (or per-occurrence
// notes) — `- [ ] submit the abstract due:2026-07-01 p:!!`. They are NOT a separate table: the
// markdown line is the canonical store; everything here is *derived* from it. This module turns a
// note into structured `ParsedTodo`s (for the future TODO index / soft-link DB) and exports the
// token patterns so the markdown-preview plugin can render the same tokens as badges WITHOUT
// re-implementing the grammar (one brain, two consumers).
//
// Grammar (locked):
//   Every token is EITHER a sigil-ref (`#tag`, `@person`, `@type:slug`, a markdown/bare link) OR an
//   allowlisted `key:value` (`due:`, `start:`, `tz:`, `color:`, `done:`, and priority `p:!`…`p:!!!!!`).
//   No bare-punctuation tokens. Every token is anchored to whitespace-or-line-start so an email
//   (`tommy@cs.jhu.edu`) never matches `@cs` and prose never sprouts badges. Link contents are
//   masked out first, so `#frag`/`@host` inside a URL are never tokens.
//
// This file is intentionally dependency-free (no `@/` imports, no Prisma) — the event argument is a
// structural type, so callers pass an `ApiEvent` directly and the tokenizer stays pure & testable.

// ── Token patterns (exported for the preview plugin to reuse) ──────────────────────────────────
// Each pattern is anchored with a leading `(^|\s)` boundary and a trailing `(?=\s|$)` boundary so a
// token must stand alone. They are authored WITHOUT the global flag; callers add it as needed.

/** A markdown link: `[label](url)`. Label may be empty. */
export const MD_LINK_RE = /\[([^\]]*)\]\((https?:\/\/[^)\s]+|[^)\s]+)\)/;
/** A bare autolink-style URL. */
export const BARE_URL_RE = /(^|\s)(https?:\/\/[^\s]+)(?=\s|$)/;
/** Priority: `p:` followed by 1+ bangs; the count is the level (clamped 1–5), higher = more urgent. */
export const PRIORITY_RE = /(^|\s)p:(!{1,})(?=\s|$)/;
// A date value: an explicit `YYYY-MM-DD[THH:MM]`, a keyword, or an offset from today (`3d`, `-2w`).
// Resolved against the parse-time "today" by `resolveDateToken`.
const DATE_VALUE = String.raw`today|tomorrow|yesterday|-?\d+[dwmy]|\d{4}-\d{2}-\d{2}`;
// A time-only value → today at that time: `5pm`, `5:30pm`, `9am`, or 24h `17:00`.
const TIME_VALUE = String.raw`\d{1,2}(?::\d{2})?(?:am|pm)|\d{1,2}:\d{2}`;
/** `due:` + a date value (optional `THH:MM`) or a bare time (resolves to today at that time). */
export const DUE_RE = new RegExp(`(^|\\s)due:(${DATE_VALUE}(?:[T ]\\d{2}:\\d{2})?|${TIME_VALUE})(?=\\s|$)`);
/** `start:` + a date value — the show-from / defer date. */
export const START_RE = new RegExp(`(^|\\s)start:(${DATE_VALUE})(?=\\s|$)`);
/** `tz:AOE` or an IANA id (`tz:America/New_York`). Applies to `due:`. */
export const TZ_RE = /(^|\s)tz:(AOE|[A-Za-z][\w/+-]*)(?=\s|$)/;
/** `color:KEY` — a palette key from EVENT_COLORS. */
export const COLOR_RE = /(^|\s)color:([\w-]+)(?=\s|$)/;
/** `done:YYYY-MM-DD` — completion timestamp, with an optional `THH:MM[:SS]` (auto-stamped on tick). */
export const DONE_RE = /(^|\s)done:(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?)(?=\s|$)/;
/**
 * `followup:30d` (a duration off the event's END date) or `followup:2026-7-31` (a literal date,
 * loosely formatted). Resolves to a follow-up date that acts as a due date but is surfaced as
 * "Remember to Followup" — and counts as overdue once it passes. Duration units: d/w/m/y.
 */
export const FOLLOWUP_RE = /(^|\s)followup:(\d+[dwmy]|\d{4}-\d{1,2}-\d{1,2})(?=\s|$)/;
/** `#slug` — additional tag. Slug is `[\w][\w-]*`. */
export const TAG_RE = /(^|\s)#([A-Za-z0-9_][\w-]*)(?=\s|$)/;
/** `@slug` (bare = person) or `@type:slug` (project/funding/… — extensible without new sigils). */
export const ENTITY_RE = /(^|\s)@(?:([A-Za-z][\w-]*):)?([A-Za-z0-9_][\w-]*)(?=\s|$)/;

/** A GFM task-list line: indent+marker, the `[ ]`/`[x]` state, and the rest of the line. */
export const TASK_LINE_RE = /^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\](.*)$/;

export const MAX_PRIORITY = 5;

// ── Types ──────────────────────────────────────────────────────────────────────────────────────

export interface TodoLink {
  label?: string;
  url: string;
}

/** What `tokenizeLine` extracts from a single line's text (no event context, no inheritance). */
export interface LineTokens {
  text: string; // the line text with all tokens stripped, whitespace-collapsed, trimmed
  priority?: number; // 1–5 (bang count), higher = more urgent
  due?: string;
  tz?: string; // timezone for `due:`
  start?: string;
  color?: string;
  done?: string; // completion date token (distinct from the checkbox state)
  followup?: string; // raw followup token value: a duration ("30d") or a loose date ("2026-7-31")
  tags: string[];
  entities: Record<string, string[]>; // @type:slug refs keyed by type ("person" for bare @)
  links: TodoLink[];
}

/** The minimal shape `parseTodos` needs from an event — `ApiEvent` is structurally compatible. */
export interface TodoEventContext {
  id: string;
  kind: string; // "timed" | "band" | "deadline"
  title: string; // shown as the "Event · todo text" prefix in the TODO view (§17.2)
  color: string;
  tags: string[];
  start: string; // wall-clock "YYYY-MM-DD[THH:MM:SS]"; its date part is inherited as the default due
  end: string; // wall-clock end; its date is the base a `followup:<duration>` counts from
  originTz?: string | null; // deadline origin tz, inherited as the default due tz
  notes: string | null;
  occurrenceNotes?: Record<string, string>; // per-occurrence note overrides, keyed by occurrence date
}

/** A fully-resolved TODO: a soft-link to one source line, with event inheritance applied. */
export interface ParsedTodo {
  raw: string; // the full source line, verbatim
  text: string; // human text with tokens stripped

  done: boolean; // from the checkbox `[x]`
  doneDate?: string; // from a `done:` token, if present

  // provenance + soft-link anchor: which note, which line. Editing this TODO rewrites exactly this line.
  source: "event" | "daily"; // an event's note, or a day's "daily note" (the dashboard NOTE tab)
  eventId: string; // event source: the CalendarItem id; "" for daily
  eventTitle: string; // display prefix: event title, or "Daily note · YYYY-MM-DD" for daily
  eventKind: string; // "timed" | "band" | "deadline" | "daily"
  occurrenceKey: string | null; // event source: key into occurrenceNotes, else null
  dailyDate?: string; // daily source: the note's date "YYYY-MM-DD" (the soft-link anchor)
  line: number; // 1-based line number within that note

  priority?: number; // 1–5
  due?: string; // line `due:` else the event's date
  dueTz?: string;
  dueSource: "line" | "event";
  followup?: string; // resolved follow-up date (YYYY-MM-DD) from a `followup:` token; the operative date when set
  start?: string; // show-from date (line token only)
  active: boolean; // !done && (start == null || today >= start)

  tags: string[]; // event.tags ∪ line #tags (case-insensitive union, first-seen casing)
  people: string[]; // entities.person
  projects: string[]; // entities.project
  funding: string[]; // entities.funding
  entities: Record<string, string[]>; // all @type:slug refs (incl. future module types)
  links: TodoLink[];

  color?: string; // line `color:` else event.color
  colorSource: "line" | "event";
}

// ── Line tokenizer ───────────────────────────────────────────────────────────────────────────

const dateOf = (wallClock: string): string => wallClock.slice(0, 10);

// Case-insensitive union that preserves the first-seen casing of each value.
function unionCI(...lists: string[][]): string[] {
  const seen = new Map<string, string>();
  for (const list of lists) for (const v of list) {
    const k = v.toLowerCase();
    if (!seen.has(k)) seen.set(k, v);
  }
  return [...seen.values()];
}

function pushEntity(entities: Record<string, string[]>, type: string, slug: string) {
  const t = type.toLowerCase();
  (entities[t] ??= []).push(slug);
}

/**
 * Tokenize one line of text (the part after a `- [ ] ` marker, or any free text). Links are masked
 * first so URL contents can't masquerade as `#`/`@` tokens; each remaining token is stripped from
 * the text as it's consumed, leaving the human-readable remainder.
 */
export function tokenizeLine(input: string): LineTokens {
  const tags: string[] = [];
  const entities: Record<string, string[]> = {};
  const links: TodoLink[] = [];
  let priority: number | undefined;
  let due: string | undefined;
  let tz: string | undefined;
  let start: string | undefined;
  let color: string | undefined;
  let done: string | undefined;
  let followup: string | undefined;

  let text = input;

  // 1) Markdown links first — `[label](url)` — so nothing inside them tokenizes.
  text = text.replace(new RegExp(MD_LINK_RE, "g"), (_m, label: string, url: string) => {
    links.push(label ? { label, url } : { url });
    return " ";
  });
  // 2) Bare URLs.
  text = text.replace(new RegExp(BARE_URL_RE, "g"), (_m, _lead: string, url: string) => {
    links.push({ url });
    return " ";
  });

  // 3) Single-valued key:value tokens + priority. First occurrence wins (`replace` w/o /g, once).
  text = text.replace(PRIORITY_RE, (_m, _l: string, bangs: string) => {
    if (priority === undefined) priority = Math.min(MAX_PRIORITY, bangs.length);
    return " ";
  });
  text = text.replace(DUE_RE, (_m, _l: string, v: string) => { if (due === undefined) due = v; return " "; });
  text = text.replace(START_RE, (_m, _l: string, v: string) => { if (start === undefined) start = v; return " "; });
  text = text.replace(TZ_RE, (_m, _l: string, v: string) => { if (tz === undefined) tz = v; return " "; });
  text = text.replace(COLOR_RE, (_m, _l: string, v: string) => { if (color === undefined) color = v; return " "; });
  text = text.replace(DONE_RE, (_m, _l: string, v: string) => { if (done === undefined) done = v; return " "; });
  text = text.replace(FOLLOWUP_RE, (_m, _l: string, v: string) => { if (followup === undefined) followup = v; return " "; });

  // 4) Multi-valued sigil refs.
  text = text.replace(new RegExp(TAG_RE, "g"), (_m, _l: string, slug: string) => { tags.push(slug); return " "; });
  text = text.replace(new RegExp(ENTITY_RE, "g"), (_m, _l: string, type: string | undefined, slug: string) => {
    pushEntity(entities, type ?? "person", slug);
    return " ";
  });

  text = text.replace(/\s+/g, " ").trim();
  return { text, priority, due, tz, start, color, done, followup, tags, entities, links };
}

// ── followup: resolution (duration off the event end, or a literal loose date) ──────────────────
const pad2 = (n: number): string => String(n).padStart(2, "0");
const fmtUTC = (d: Date): string => `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}`;

/** `30d` / `2w` / `3m` / `1y` added to a base `YYYY-MM-DD` date (UTC-safe wall-clock arithmetic). */
function addDuration(baseIso: string, n: number, unit: "d" | "w" | "m" | "y"): string {
  const [y, m, d] = baseIso.split("-").map(Number);
  if (unit === "d") return fmtUTC(new Date(Date.UTC(y, m - 1, d + n)));
  if (unit === "w") return fmtUTC(new Date(Date.UTC(y, m - 1, d + 7 * n)));
  if (unit === "m") return fmtUTC(new Date(Date.UTC(y, m - 1 + n, d)));
  return fmtUTC(new Date(Date.UTC(y + n, m - 1, d))); // "y"
}

/** Resolve a raw `followup:` value to a `YYYY-MM-DD` date: a duration off `endDate`, or a literal date. */
function resolveFollowup(raw: string, endDate: string): string | undefined {
  const dur = raw.match(/^(\d+)([dwmy])$/);
  if (dur) return addDuration(endDate, Number(dur[1]), dur[2] as "d" | "w" | "m" | "y");
  const dt = raw.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (dt) return `${dt[1]}-${pad2(Number(dt[2]))}-${pad2(Number(dt[3]))}`;
  return undefined;
}

/**
 * Resolve a `due:`/`start:` value to a concrete date. An explicit `YYYY-MM-DD[THH:MM]` passes
 * through; a keyword (`today`/`tomorrow`/`yesterday`) or an offset (`3d`, `-2w`) resolves against
 * `today`. Returns undefined for an unresolvable token (e.g. a keyword with no `today` reference),
 * so the caller can fall back to the inherited default.
 */
function resolveDateToken(v: string, today: string | undefined): string | undefined {
  if (/^\d{4}-\d{2}-\d{2}/.test(v)) return v; // explicit date (keeps any THH:MM)
  if (today == null) return undefined;
  if (v === "today") return today;
  if (v === "tomorrow") return addDuration(today, 1, "d");
  if (v === "yesterday") return addDuration(today, -1, "d");
  const dur = v.match(/^(-?\d+)([dwmy])$/);
  if (dur) return addDuration(today, Number(dur[1]), dur[2] as "d" | "w" | "m" | "y");
  // a bare time → today at that time
  const t12 = v.match(/^(\d{1,2})(?::(\d{2}))?(am|pm)$/i);
  if (t12) {
    const h = (Number(t12[1]) % 12) + (t12[3].toLowerCase() === "pm" ? 12 : 0);
    return `${today}T${pad2(h)}:${t12[2] ?? "00"}`;
  }
  const t24 = v.match(/^(\d{1,2}):(\d{2})$/);
  if (t24) return `${today}T${pad2(Number(t24[1]))}:${t24[2]}`;
  return undefined;
}

// ── Source-aware parsing (inheritance + active filtering) ──────────────────────────────────────

// Provenance + inheritance context for one checkbox line — the part that differs between an event
// note and a daily note. The token resolution itself (below) is identical for both.
interface TodoContext {
  source: "event" | "daily";
  eventId: string;
  eventTitle: string;
  eventKind: string;
  occurrenceKey: string | null;
  dailyDate?: string;
  inheritDate: string; // default due (event start / occurrence date / the daily note's date)
  inheritEndDate: string; // followup base (event end / occurrence date / the daily note's date)
  inheritColor: string; // default color
  inheritTags: string[]; // tags unioned with the line's #tags
  originTz?: string | null; // deadline origin tz (for the inherited due tz)
}

function buildTodoFrom(ctx: TodoContext, line: number, raw: string, done: boolean, tok: LineTokens, today: string | undefined): ParsedTodo {
  const entities = tok.entities;
  // Resolve a line `due:`/`start:` (which may be a keyword/offset) to a concrete date.
  const dueTok = tok.due ? resolveDateToken(tok.due, today) : undefined;
  const startTok = tok.start ? resolveDateToken(tok.start, today) : undefined;

  const dueSource: "line" | "event" = dueTok ? "line" : "event";
  const due = dueTok ?? ctx.inheritDate;
  const dueTz = tok.tz ?? (dueSource === "event" && ctx.eventKind === "deadline" ? ctx.originTz ?? undefined : undefined);
  const followup = tok.followup ? resolveFollowup(tok.followup, ctx.inheritEndDate) : undefined;

  const colorSource: "line" | "event" = tok.color ? "line" : "event";
  const color = tok.color ?? ctx.inheritColor;

  // Deferred items are inactive until their show-from date. Without a `today` reference we can't
  // evaluate the defer, so we treat a non-done item as active (the index passes today in practice).
  const active = !done && (startTok == null || today == null || today >= startTok);

  return {
    raw,
    text: tok.text,
    done,
    doneDate: tok.done,
    source: ctx.source,
    eventId: ctx.eventId,
    eventTitle: ctx.eventTitle,
    eventKind: ctx.eventKind,
    occurrenceKey: ctx.occurrenceKey,
    dailyDate: ctx.dailyDate,
    line,
    priority: tok.priority,
    due,
    dueTz,
    dueSource,
    followup,
    start: startTok,
    active,
    tags: unionCI(ctx.inheritTags, tok.tags),
    people: entities.person ?? [],
    projects: entities.project ?? [],
    funding: entities.funding ?? [],
    entities,
    links: tok.links,
    color,
    colorSource,
  };
}

/**
 * Parse every checkbox line in an event's notes (and per-occurrence notes) into resolved
 * `ParsedTodo`s. `today` (a `YYYY-MM-DD` string) drives the `active` (defer) computation; pass it
 * for correct feed visibility, omit it to treat all non-done items as active.
 */
export function parseTodos(event: TodoEventContext, today?: string): ParsedTodo[] {
  const out: ParsedTodo[] = [];

  const scan = (notes: string | null | undefined, occurrenceKey: string | null, eventDate: string, eventEndDate: string) => {
    if (!notes) return;
    const lines = notes.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(TASK_LINE_RE);
      if (!m) continue;
      const tok = tokenizeLine(m[3]);
      if (tok.text === "") continue; // skip empty checkbox lines (`- [ ]` with no task text)
      const done = m[2].toLowerCase() === "x";
      const ctx: TodoContext = {
        source: "event", eventId: event.id, eventTitle: event.title, eventKind: event.kind,
        occurrenceKey, inheritDate: eventDate, inheritEndDate: eventEndDate,
        inheritColor: event.color, inheritTags: event.tags, originTz: event.originTz,
      };
      out.push(buildTodoFrom(ctx, i + 1, lines[i], done, tok, today));
    }
  };

  // Base note inherits the event's start date (default due) and end date (followup base); a
  // per-occurrence note inherits its occurrence date for both (single-day occurrence — §17.2).
  scan(event.notes, null, dateOf(event.start), dateOf(event.end));
  if (event.occurrenceNotes) {
    for (const [key, notes] of Object.entries(event.occurrenceNotes)) scan(notes, key, key, key);
  }
  return out;
}

/**
 * Parse the checkbox lines of a day's "daily note" (the dashboard NOTE tab) into `ParsedTodo`s.
 * Provenance is the daily note itself (`source: "daily"`, `dailyDate: date`); the default due and
 * the followup base are the note's own date. The soft-link anchor is `(dailyDate, line)`.
 */
export function parseDailyNoteTodos(date: string, notes: string | null | undefined, today?: string): ParsedTodo[] {
  if (!notes) return [];
  const out: ParsedTodo[] = [];
  const lines = notes.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(TASK_LINE_RE);
    if (!m) continue;
    const tok = tokenizeLine(m[3]);
    if (tok.text === "") continue;
    const done = m[2].toLowerCase() === "x";
    const ctx: TodoContext = {
      source: "daily", eventId: "", eventTitle: `Daily note · ${date}`, eventKind: "daily",
      occurrenceKey: null, dailyDate: date, inheritDate: date, inheritEndDate: date,
      inheritColor: "default", inheritTags: [],
    };
    out.push(buildTodoFrom(ctx, i + 1, lines[i], done, tok, today));
  }
  return out;
}

// ── The TODO index + the soft-link write primitive ─────────────────────────────────────────────

/**
 * Build the cross-event TODO index: parse every event's notes into a flat, sorted list of
 * pointer-referenced `ParsedTodo`s. Each entry soft-links back to one source line via
 * `(eventId, occurrenceKey, line)` — nothing is copied; the markdown stays the source of truth.
 */
export function indexTodos(events: TodoEventContext[], today?: string): ParsedTodo[] {
  return events.flatMap((e) => parseTodos(e, today)).sort(compareTodos);
}

/**
 * Default feed ordering: active before deferred/done, then by effective due date (undated last),
 * then higher priority first, then alphabetical. Stable enough for the panel's default view.
 */
export function compareTodos(a: ParsedTodo, b: ParsedTodo): number {
  if (a.active !== b.active) return a.active ? -1 : 1;
  if (a.done !== b.done) return a.done ? 1 : -1;
  const ad = a.due ?? "9999-99-99";
  const bd = b.due ?? "9999-99-99";
  if (ad !== bd) return ad < bd ? -1 : 1;
  const ap = a.priority ?? 0;
  const bp = b.priority ?? 0;
  if (ap !== bp) return bp - ap;
  return a.text.localeCompare(b.text);
}

/**
 * The soft-link write: flip the checkbox on `line` (1-based) of a note's markdown. `checked`
 * undefined toggles; true/false sets explicitly. When `stamp` (a `YYYY-MM-DD[THH:MM]` completion
 * time) is given, checking the box also appends a `done:<stamp>` token and unchecking strips any
 * existing `done:` token — so a ticked item records WHEN it was finished (and untick is a clean
 * undo). Omit `stamp` to flip the checkbox only. Returns the new note text, the SAME text on a
 * no-op, or `null` on a stale anchor (line gone / no longer a task line) so the caller can reject
 * rather than corrupt the note.
 */
export function toggleTodoLine(noteText: string, line: number, checked?: boolean, stamp?: string): string | null {
  const lines = noteText.split("\n");
  const cur = lines[line - 1];
  if (cur === undefined) return null;
  const m = cur.match(TASK_LINE_RE);
  if (!m) return null;
  const isChecked = m[2].toLowerCase() === "x";
  const next = checked === undefined ? !isChecked : checked;
  // Always strip any prior done: token, then re-stamp it when the box ends up checked.
  let rest = m[3].replace(new RegExp(DONE_RE.source, "g"), "").replace(/\s+$/, "");
  if (next && stamp) rest = `${rest} done:${stamp}`;
  const nextLine = `${m[1]}[${next ? "x" : " "}]${rest}`;
  if (nextLine === cur) return noteText; // no-op (state + stamp unchanged)
  lines[line - 1] = nextLine;
  return lines.join("\n");
}
