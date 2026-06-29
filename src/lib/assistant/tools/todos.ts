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
/** `due:YYYY-MM-DD` with optional `THH:MM` (or space-separated time). */
export const DUE_RE = /(^|\s)due:(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2})?)(?=\s|$)/;
/** `start:YYYY-MM-DD` — show-from / defer date. */
export const START_RE = /(^|\s)start:(\d{4}-\d{2}-\d{2})(?=\s|$)/;
/** `tz:AOE` or an IANA id (`tz:America/New_York`). Applies to `due:`. */
export const TZ_RE = /(^|\s)tz:(AOE|[A-Za-z][\w/+-]*)(?=\s|$)/;
/** `color:KEY` — a palette key from EVENT_COLORS. */
export const COLOR_RE = /(^|\s)color:([\w-]+)(?=\s|$)/;
/** `done:YYYY-MM-DD` — completion timestamp, with an optional `THH:MM` (auto-stamped on tick). */
export const DONE_RE = /(^|\s)done:(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2})?)(?=\s|$)/;
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

  // soft-link anchor: which note, which line. Editing this TODO rewrites exactly this line.
  eventId: string;
  eventTitle: string; // parent event's title (for the "Event · text" display prefix)
  eventKind: string; // "timed" | "band" | "deadline"
  occurrenceKey: string | null; // key into occurrenceNotes, or null for the base note
  line: number; // 1-based line number within that note

  priority?: number; // 1–5
  due?: string; // line `due:` else the event's date
  dueTz?: string;
  dueSource: "line" | "event";
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

  // 4) Multi-valued sigil refs.
  text = text.replace(new RegExp(TAG_RE, "g"), (_m, _l: string, slug: string) => { tags.push(slug); return " "; });
  text = text.replace(new RegExp(ENTITY_RE, "g"), (_m, _l: string, type: string | undefined, slug: string) => {
    pushEntity(entities, type ?? "person", slug);
    return " ";
  });

  text = text.replace(/\s+/g, " ").trim();
  return { text, priority, due, tz, start, color, done, tags, entities, links };
}

// ── Event-aware parsing (inheritance + active filtering) ───────────────────────────────────────

function buildTodo(
  event: TodoEventContext,
  occurrenceKey: string | null,
  eventDate: string, // the date this note inherits as the default due (base start, or occurrence date)
  line: number,
  raw: string,
  done: boolean,
  tok: LineTokens,
  today: string | undefined,
): ParsedTodo {
  const entities = tok.entities;
  const dueSource: "line" | "event" = tok.due ? "line" : "event";
  const due = tok.due ?? eventDate;
  const dueTz =
    tok.tz ?? (dueSource === "event" && event.kind === "deadline" ? event.originTz ?? undefined : undefined);

  const colorSource: "line" | "event" = tok.color ? "line" : "event";
  const color = tok.color ?? event.color;

  // Deferred items are inactive until their show-from date. Without a `today` reference we can't
  // evaluate the defer, so we treat a non-done item as active (the index passes today in practice).
  const active = !done && (tok.start == null || today == null || today >= tok.start);

  return {
    raw,
    text: tok.text,
    done,
    doneDate: tok.done,
    eventId: event.id,
    eventTitle: event.title,
    eventKind: event.kind,
    occurrenceKey,
    line,
    priority: tok.priority,
    due,
    dueTz,
    dueSource,
    start: tok.start,
    active,
    tags: unionCI(event.tags, tok.tags),
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

  const scan = (notes: string | null | undefined, occurrenceKey: string | null, eventDate: string) => {
    if (!notes) return;
    const lines = notes.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(TASK_LINE_RE);
      if (!m) continue;
      const done = m[2].toLowerCase() === "x";
      out.push(buildTodo(event, occurrenceKey, eventDate, i + 1, lines[i], done, tokenizeLine(m[3]), today));
    }
  };

  // Base note inherits the event's start date; a per-occurrence note inherits its occurrence date
  // (so moving/expanding a recurrence cascades the right default due — design §17.2).
  scan(event.notes, null, dateOf(event.start));
  if (event.occurrenceNotes) {
    for (const [key, notes] of Object.entries(event.occurrenceNotes)) scan(notes, key, key);
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
 * undefined toggles; true/false sets explicitly. Returns the new note text, the SAME text on a
 * no-op, or `null` if the line no longer exists or isn't a task line (a stale anchor — the caller
 * should reject rather than corrupt the note). Mirrors NotesPreview's in-note toggle exactly.
 */
export function toggleTodoLine(noteText: string, line: number, checked?: boolean): string | null {
  const lines = noteText.split("\n");
  const cur = lines[line - 1];
  if (cur === undefined) return null;
  const m = cur.match(TASK_LINE_RE);
  if (!m) return null;
  const isChecked = m[2].toLowerCase() === "x";
  const next = checked === undefined ? !isChecked : checked;
  if (next === isChecked) return noteText; // no-op (already in the requested state)
  lines[line - 1] = `${m[1]}[${next ? "x" : " "}]${m[3]}`;
  return lines.join("\n");
}
