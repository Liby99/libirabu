// Unit tests for the TODO tokenizer (design §17.1). Runnable without a test framework:
//   npx tsc --strict --target es2020 --module commonjs --outDir <tmp> todos.ts todos.test.ts
//   node <tmp>/todos.test.js
// Exits non-zero on the first failure.

import { tokenizeLine, parseTodos, parseDailyNoteTodos, indexTodos, toggleTodoLine, linesNeedingCreated, type TodoEventContext } from "./todos";

let passed = 0;
const failures: string[] = [];

function check(name: string, cond: boolean, detail?: unknown) {
  if (cond) { passed++; return; }
  failures.push(`${name}${detail !== undefined ? ` — got ${JSON.stringify(detail)}` : ""}`);
}
const eq = (name: string, a: unknown, b: unknown) =>
  check(name, JSON.stringify(a) === JSON.stringify(b), a);

// ── 1. The worked example from the design doc (priority updated to p:!!) ───────────────────────
{
  const line =
    "submit the abstract due:2026-07-01 p:!! #paper-submission @tommy " +
    "@project:driving-scene-synthesis @funding:toyota [HotCRP](https://pldi27.hotcrp.com) color:orange";
  const t = tokenizeLine(line);
  eq("worked: text stripped", t.text, "submit the abstract");
  eq("worked: due", t.due, "2026-07-01");
  eq("worked: priority", t.priority, 2);
  eq("worked: tags", t.tags, ["paper-submission"]);
  eq("worked: people", t.entities.person, ["tommy"]);
  eq("worked: projects", t.entities.project, ["driving-scene-synthesis"]);
  eq("worked: funding", t.entities.funding, ["toyota"]);
  eq("worked: color", t.color, "orange");
  eq("worked: links", t.links, [{ label: "HotCRP", url: "https://pldi27.hotcrp.com" }]);
}

// ── 2. Priority: count = level, clamp at 5, prose-safe ─────────────────────────────────────────
eq("prio 1", tokenizeLine("x p:!").priority, 1);
eq("prio 5", tokenizeLine("x p:!!!!!").priority, 5);
eq("prio clamps to 5", tokenizeLine("x p:!!!!!!!").priority, 5);
eq("prio needs p: prefix — bare bangs ignored", tokenizeLine("this is huge!!").priority, undefined);
eq("prio bare bangs leave text intact", tokenizeLine("this is huge!!").text, "this is huge!!");
eq("prio malformed (p:!x) ignored", tokenizeLine("p:!x oops").priority, undefined);

// ── 3. Anchoring: emails and mid-word sigils don't match ───────────────────────────────────────
{
  const t = tokenizeLine("email tommy@cs.jhu.edu about #grant");
  eq("email not a person ref", t.entities.person, undefined);
  eq("trailing tag still matches", t.tags, ["grant"]);
  eq("email text preserved", t.text, "email tommy@cs.jhu.edu about");
}

// ── 4. Link contents are masked — no tokens harvested from inside a URL ────────────────────────
{
  const t = tokenizeLine("see https://example.com/path#section/@handle for details");
  eq("url: no tag from #section", t.tags, []);
  eq("url: no person from @handle", t.entities.person, undefined);
  eq("url: captured as link", t.links, [{ url: "https://example.com/path#section/@handle" }]);
}

// ── 5. Single-valued tokens: first occurrence wins ─────────────────────────────────────────────
eq("first due wins", tokenizeLine("a due:2026-01-01 b due:2026-02-02").due, "2026-01-01");

// ── 6. tz + due with time ──────────────────────────────────────────────────────────────────────
{
  const t = tokenizeLine("finalize due:2026-07-01T23:59 tz:AOE");
  eq("due with time", t.due, "2026-07-01T23:59");
  eq("tz AOE", t.tz, "AOE");
}

// ── 7. parseTodos: scans only checkbox lines, applies inheritance + active ─────────────────────
{
  const event: TodoEventContext = {
    id: "evt1",
    kind: "deadline",
    title: "PLDI 2026 — Abs",
    color: "blue",
    tags: ["pldi"],
    start: "2026-07-01T23:59:00",
    end: "2026-07-01T23:59:00",
    originTz: "AOE",
    notes: [
      "# PLDI 2026",
      "- [ ] submit abstract p:!!! #paper @tommy",
      "just a prose line, not a todo",
      "- [x] register done:2026-06-01",
      "- [ ] book travel start:2026-12-01 due:2026-12-15",
    ].join("\n"),
  };
  const todos = parseTodos(event, "2026-06-28");
  eq("parse: count (3 checkbox lines)", todos.length, 3);

  const abstract = todos[0];
  eq("parse: line number", abstract.line, 2);
  eq("parse: eventTitle carried", abstract.eventTitle, "PLDI 2026 — Abs");
  eq("parse: eventKind carried", abstract.eventKind, "deadline");
  eq("parse: occurrenceKey null for base note", abstract.occurrenceKey, null);
  eq("parse: priority", abstract.priority, 3);
  eq("parse: tags inherited ∪ line", abstract.tags, ["pldi", "paper"]);
  eq("parse: people", abstract.people, ["tommy"]);
  eq("parse: due inherited from event date", abstract.due, "2026-07-01");
  eq("parse: dueSource event", abstract.dueSource, "event");
  eq("parse: dueTz inherited from deadline originTz", abstract.dueTz, "AOE");
  eq("parse: color inherited", abstract.color, "blue");
  eq("parse: colorSource event", abstract.colorSource, "event");
  check("parse: abstract active", abstract.active === true);

  const register = todos[1];
  check("parse: register done", register.done === true);
  eq("parse: doneDate", register.doneDate, "2026-06-01");
  check("parse: done item inactive", register.active === false);

  const travel = todos[2];
  eq("parse: line due overrides", travel.due, "2026-12-15");
  eq("parse: dueSource line", travel.dueSource, "line");
  eq("parse: start token", travel.start, "2026-12-01");
  check("parse: deferred (start in future) is inactive", travel.active === false);
}

// ── 8. parseTodos: per-occurrence notes carry the occurrence key ───────────────────────────────
{
  const event: TodoEventContext = {
    id: "evt2",
    kind: "timed",
    title: "Weekly sync",
    color: "default",
    tags: [],
    start: "2026-03-10T09:00:00",
    end: "2026-03-10T10:00:00",
    notes: null,
    occurrenceNotes: { "2026-03-17": "- [ ] prep slides" },
  };
  const todos = parseTodos(event, "2026-03-10");
  eq("occurrence: count", todos.length, 1);
  eq("occurrence: key", todos[0].occurrenceKey, "2026-03-17");
  eq("occurrence: text", todos[0].text, "prep slides");
  // inherits the OCCURRENCE date as default due, not the base event start
  eq("occurrence: due inherits occurrence date", todos[0].due, "2026-03-17");
  eq("occurrence: dueSource event", todos[0].dueSource, "event");
}

// ── 9. indexTodos: flat cross-event list, sorted (active→due→priority) ──────────────────────────
{
  const events: TodoEventContext[] = [
    {
      id: "a", kind: "timed", title: "Paper A", color: "blue", tags: [],
      start: "2026-09-01T09:00:00", end: "2026-09-01T10:00:00",
      notes: "- [ ] later task start:2026-12-01\n- [x] finished thing",
    },
    {
      id: "b", kind: "deadline", title: "Grant B", color: "red", tags: [],
      start: "2026-07-15T17:00:00", end: "2026-07-15T17:00:00",
      notes: "- [ ] urgent p:!!!\n- [ ] soon due:2026-07-01",
    },
  ];
  const idx = indexTodos(events, "2026-06-28");
  eq("index: total todos across events", idx.length, 4);
  // active+dated first: "soon" due 2026-07-01 < "urgent" (due = event date 2026-07-15)
  eq("index: first is earliest active due", idx[0].text, "soon");
  eq("index: second by date", idx[1].text, "urgent");
  // deferred (future start) and done sink below the active ones
  check("index: deferred not active", idx.find((t) => t.text === "later task")?.active === false);
  check("index: done sinks last", idx[idx.length - 1].done === true);
  eq("index: cross-event eventTitle preserved", idx[0].eventTitle, "Grant B");
}

// ── 10. toggleTodoLine: the soft-link write primitive ──────────────────────────────────────────
{
  const note = "intro\n- [ ] do it #tag\n- [x] done one";
  eq("toggle: check line 2", toggleTodoLine(note, 2), "intro\n- [x] do it #tag\n- [x] done one");
  eq("toggle: explicit uncheck line 3", toggleTodoLine(note, 3, false), "intro\n- [ ] do it #tag\n- [ ] done one");
  eq("toggle: no-op when already in state", toggleTodoLine(note, 2, false), note);
  eq("toggle: non-task line → null (stale anchor)", toggleTodoLine(note, 1), null);
  eq("toggle: out-of-range line → null", toggleTodoLine(note, 99), null);
  // preserves indent + ordered-list markers
  eq("toggle: keeps marker/indent", toggleTodoLine("  1. [ ] x", 1), "  1. [x] x");
}

// ── 11. toggleTodoLine: done: completion stamping (minute precision) ───────────────────────────
{
  const stamp = "2026-01-02T14:35";
  // checking with a stamp appends done:<stamp>
  eq("stamp: check appends done:", toggleTodoLine("- [ ] ship it", 1, true, stamp), "- [x] ship it done:2026-01-02T14:35");
  // unchecking strips any existing done: token (clean undo)
  eq("stamp: uncheck strips done:", toggleTodoLine("- [x] ship it done:2026-01-02T14:35", 1, false, stamp), "- [ ] ship it");
  // re-checking replaces an old stamp with the new one (no duplicate tokens)
  eq("stamp: re-stamp replaces", toggleTodoLine("- [x] ship it done:2025-12-01T09:00", 1, true, stamp), "- [x] ship it done:2026-01-02T14:35");
  // a done: token mid-line is also stripped on uncheck, spacing preserved
  eq("stamp: strips mid-line done:", toggleTodoLine("- [x] ship it done:2026-01-02T14:35 #tag", 1, false, stamp), "- [ ] ship it #tag");
  // without a stamp, it just flips (no token added) — the in-editor toggle path
  eq("stamp: no stamp → plain flip", toggleTodoLine("- [ ] ship it", 1, true), "- [x] ship it");
  // the tokenizer reads the minute-precision done: into doneDate
  eq("stamp: tokenized doneDate", tokenizeLine("ship it done:2026-01-02T14:35").done, "2026-01-02T14:35");
}

// ── 12. followup: duration off the event END date, or a loose literal date ─────────────────────
{
  const ev: TodoEventContext = {
    id: "f", kind: "timed", title: "Vendor call", color: "default", tags: [],
    start: "2026-07-10T09:00:00", end: "2026-07-10T10:00:00",
    notes: [
      "- [ ] circle back followup:30d",        // +30 days off the END date (2026-07-10)
      "- [ ] hard date followup:2026-7-31",    // loose literal date → normalized
      "- [ ] two weeks followup:2w",
    ].join("\n"),
  };
  const todos = parseTodos(ev, "2026-07-15");
  eq("followup: 30d off end date", todos[0].followup, "2026-08-09");
  eq("followup: loose date normalized", todos[1].followup, "2026-07-31");
  eq("followup: 2w off end date", todos[2].followup, "2026-07-24");
  // followup is captured as a raw token by the line tokenizer
  eq("followup: raw token", tokenizeLine("x followup:30d").followup, "30d");
  // month/year units
  eq("followup: 3m", tokenizeLine("x followup:3m").followup, "3m");
  // a non-followup todo has no followup
  check("followup: absent when no token", parseTodos({ ...ev, notes: "- [ ] plain" }, "2026-07-15")[0].followup === undefined);
}

// ── 13. empty checkbox lines are not indexed ───────────────────────────────────────────────────
{
  const ev: TodoEventContext = {
    id: "e", kind: "timed", title: "Notes", color: "default", tags: [],
    start: "2026-05-01T09:00:00", end: "2026-05-01T10:00:00",
    notes: [
      "- [ ] ",            // empty → skipped
      "- [ ]",             // empty (no trailing space) → skipped
      "- [x]    ",         // whitespace-only, checked → skipped
      "- [ ] real task",   // counts
    ].join("\n"),
  };
  const todos = parseTodos(ev, "2026-05-01");
  eq("empty: only the real task is indexed", todos.length, 1);
  eq("empty: it's the real one", todos[0].text, "real task");
}

// ── 14. parseDailyNoteTodos: daily-note provenance + own-day due inheritance ───────────────────
{
  const todos = parseDailyNoteTodos("2026-06-30", "# Plan\n- [ ] call the vendor p:!!\n- [ ] file report due:2026-07-05", "2026-06-30");
  eq("daily: count", todos.length, 2);
  eq("daily: source", todos[0].source, "daily");
  eq("daily: dailyDate anchor", todos[0].dailyDate, "2026-06-30");
  eq("daily: provenance title", todos[0].eventTitle, "Daily note · 2026-06-30");
  eq("daily: eventKind", todos[0].eventKind, "daily");
  eq("daily: empty eventId", todos[0].eventId, "");
  eq("daily: line anchor", todos[0].line, 2);
  eq("daily: due inherits the note's date", todos[0].due, "2026-06-30");
  eq("daily: line due overrides", todos[1].due, "2026-07-05");
  eq("daily: priority parsed", todos[0].priority, 2);
  // empty checkbox lines are skipped here too
  eq("daily: empty skipped", parseDailyNoteTodos("2026-06-30", "- [ ] \n- [ ] real").length, 1);
  // no notes → no todos
  eq("daily: null notes", parseDailyNoteTodos("2026-06-30", null).length, 0);
}

// ── 15. relative due:/start: keywords + offsets resolve against "today" ─────────────────────────
{
  const ev = (notes: string): TodoEventContext => ({
    id: "r", kind: "timed", title: "T", color: "default", tags: [],
    start: "2026-06-01T09:00:00", end: "2026-06-01T10:00:00", notes,
  });
  const at = (notes: string) => parseTodos(ev(notes), "2026-06-29")[0];
  eq("due:today → today", at("- [ ] x due:today").due, "2026-06-29");
  eq("due:tomorrow → +1", at("- [ ] x due:tomorrow").due, "2026-06-30");
  eq("due:yesterday → −1", at("- [ ] x due:yesterday").due, "2026-06-28");
  eq("due:3d → +3 days", at("- [ ] x due:3d").due, "2026-07-02");
  eq("due:-3d → −3 days", at("- [ ] x due:-3d").due, "2026-06-26");
  eq("due:2w → +2 weeks", at("- [ ] x due:2w").due, "2026-07-13");
  eq("due:1m → +1 month", at("- [ ] x due:1m").due, "2026-07-29");
  eq("due: explicit date still works", at("- [ ] x due:2026-12-25").due, "2026-12-25");
  eq("due:today marks line source", at("- [ ] x due:today").dueSource, "line");
  // start: keyword drives the defer/active flag
  check("start:tomorrow → deferred (inactive)", at("- [ ] x start:tomorrow").active === false);
  check("start:yesterday → active", at("- [ ] x start:yesterday").active === true);
  eq("start:3d resolves", at("- [ ] x start:3d").start, "2026-07-02");
  // works in a daily note too (the user's case)
  eq("daily due:today", parseDailyNoteTodos("2026-06-30", "- [ ] ship due:today", "2026-06-29")[0].due, "2026-06-29");
  eq("daily due:tomorrow", parseDailyNoteTodos("2026-06-30", "- [ ] ship due:tomorrow", "2026-06-29")[0].due, "2026-06-30");
  // bare time → today at that time
  eq("due:5pm → today 17:00", at("- [ ] x due:5pm").due, "2026-06-29T17:00");
  eq("due:9am → today 09:00", at("- [ ] x due:9am").due, "2026-06-29T09:00");
  eq("due:5:30pm → today 17:30", at("- [ ] x due:5:30pm").due, "2026-06-29T17:30");
  eq("due:12pm → noon", at("- [ ] x due:12pm").due, "2026-06-29T12:00");
  eq("due:12am → midnight", at("- [ ] x due:12am").due, "2026-06-29T00:00");
  eq("due:17:00 (24h) → today 17:00", at("- [ ] x due:17:00").due, "2026-06-29T17:00");
  eq("due:5pm still due today (date part)", (at("- [ ] x due:5pm").due ?? "").slice(0, 10), "2026-06-29");
}

// ── 16. nesting: indented task lines are children of the nearest shallower task line ────────────
{
  const note = [
    "- [ ] parent",         // line 1: root
    "  - [x] child A",      // line 2: child of 1
    "    - [ ] grandchild", // line 3: child of 2
    "  - [ ] child B",      // line 4: pops back to child of 1
    "- [ ] second root",    // line 5: root
  ].join("\n");
  const t = parseDailyNoteTodos("2026-06-30", note, "2026-06-30");
  eq("nest: count", t.length, 5);
  eq("nest: root", [t[0].indent, t[0].parentLine], [0, null]);
  eq("nest: child A", [t[1].indent, t[1].parentLine], [1, 1]);
  eq("nest: grandchild", [t[2].indent, t[2].parentLine], [2, 2]);
  eq("nest: child B pops back", [t[3].indent, t[3].parentLine], [1, 1]);
  eq("nest: second root", [t[4].indent, t[4].parentLine], [0, null]);

  // top-level prose between lists breaks the chain…
  const broken = parseDailyNoteTodos("2026-06-30", "- [ ] a\nsome prose\n  - [ ] b");
  eq("nest: prose resets", [broken[1].indent, broken[1].parentLine], [0, null]);
  // …but a wrapped continuation line indented under its item keeps it
  const cont = parseDailyNoteTodos("2026-06-30", "- [ ] a\n  wrapped continuation\n  - [ ] b");
  eq("nest: continuation keeps parent", [cont[1].indent, cont[1].parentLine], [1, 1]);
  // blank lines keep the chain (loose lists)
  const loose = parseDailyNoteTodos("2026-06-30", "- [ ] a\n\n  - [ ] b");
  eq("nest: blank line keeps parent", [loose[1].indent, loose[1].parentLine], [1, 1]);
  // an empty checkbox line is skipped and never parents — deeper items attach to the grandparent
  const skip = parseDailyNoteTodos("2026-06-30", "- [ ] a\n  - [ ] \n    - [ ] c");
  eq("nest: empty task never parents", [skip[1].indent, skip[1].parentLine], [1, 1]);
  // event notes get the same nesting
  const ev: TodoEventContext = {
    id: "n", kind: "timed", title: "N", color: "default", tags: [],
    start: "2026-06-01T09:00:00", end: "2026-06-01T10:00:00",
    notes: "- [ ] top\n  - [ ] sub",
  };
  eq("nest: event notes too", [parseTodos(ev)[1].indent, parseTodos(ev)[1].parentLine], [1, 1]);
}

// ── 17. created: token + "start time marking" (linesNeedingCreated) ────────────────────────────
{
  const t = tokenizeLine("call the vendor created:2026-07-20T14:33 p:!");
  eq("created: parsed", t.created, "2026-07-20T14:33");
  eq("created: stripped from text", t.text, "call the vendor");
  eq("created: date-only accepted", tokenizeLine("x created:2026-07-20").created, "2026-07-20");
  eq("created: with seconds", tokenizeLine("x created:2026-07-20T14:33:05").created, "2026-07-20T14:33:05");
  eq("created: prose-safe (no value)", tokenizeLine("it was created: yesterday").created, undefined);
  // surfaces on the parsed todo
  eq("created: on ParsedTodo", parseDailyNoteTodos("2026-06-30", "- [ ] x created:2026-06-29T09:00")[0].created, "2026-06-29T09:00");

  const note = [
    "- [ ] new item",                          // 1: top-level, unstamped → needs it
    "  - [ ] sub item",                        // 2: nested → left alone
    "- [x] older created:2026-07-01T08:00",    // 3: already stamped
    "- [ ] ",                                  // 4: empty checkbox → skipped
    "prose line",
    "- [ ] another new one",                   // 6: top-level, unstamped → needs it
  ].join("\n");
  eq("stamp: only unstamped top-level lines", linesNeedingCreated(note), [1, 6]);
  eq("stamp: nothing to do", linesNeedingCreated("- [ ] a created:2026-07-01\nprose"), []);
  eq("stamp: empty note", linesNeedingCreated(""), []);
}

// ── 18. project: token (sugar for @project:) ────────────────────────────────────────────────────
{
  const t = tokenizeLine("wire the parser project:driving-scene_2 p:!");
  eq("project: parsed into entities", t.entities.project, ["driving-scene_2"]);
  eq("project: stripped from text", t.text, "wire the parser");
  // both spellings land in the same bucket
  eq("project: merges with @project:", tokenizeLine("x project:alpha @project:beta").entities.project, ["alpha", "beta"]);
  // strict charset: anything outside [A-Za-z0-9_-] fails the whole token (text left untouched)
  eq("project: dot rejected", tokenizeLine("x project:foo.bar").entities.project, undefined);
  eq("project: dot rejected — text intact", tokenizeLine("x project:foo.bar").text, "x project:foo.bar");
  eq("project: slash rejected", tokenizeLine("x project:a/b").entities.project, undefined);
  // mid-word never matches (anchored to whitespace/line-start)
  eq("project: mid-word ignored", tokenizeLine("subproject:x").entities.project, undefined);
  // surfaces on the parsed todo's projects list
  eq("project: on ParsedTodo", parseDailyNoteTodos("2026-06-30", "- [ ] x project:magical")[0].projects, ["magical"]);
}

// ── report ─────────────────────────────────────────────────────────────────────────────────────
if (failures.length) {
  console.error(`FAILED ${failures.length} / ${passed + failures.length}:`);
  for (const f of failures) console.error("  ✗ " + f);
  process.exit(1);
}
console.log(`OK — ${passed} assertions passed`);
