// Unit tests for the import pure-core (docs/calendar-import-design.md P1). Framework-free, like
// todos.test.ts. Run with the test tsconfig (it resolves the "@/*" alias used by ./types):
//   npx tsc -p tsconfig.test.json && node .test-out/lib/import/import.test.js
// Exits non-zero on the first failure.

import { rruleToRepeat } from "./recurrence";
import { splitNote, composeNote, replaceManaged, renderManagedNote } from "./managedNote";
import { parseIcs } from "./ical";
import { normalizeEvents, normalizeEvent, instantToMainWall } from "./normalize";
import { diffEvents, type ExistingEventRow } from "./diff";
import { titleSim, normTitle, fuzzyCandidates } from "./fuzzy";
import type { RawSourceEvent } from "./types";

let passed = 0;
const failures: string[] = [];
function check(name: string, cond: boolean, detail?: unknown) {
  if (cond) { passed++; return; }
  failures.push(`${name}${detail !== undefined ? ` — got ${JSON.stringify(detail)}` : ""}`);
}
const eq = (name: string, a: unknown, b: unknown) => check(name, JSON.stringify(a) === JSON.stringify(b), a);

const TZ = "America/New_York";

// ── recurrence: RRULE → Repeat ───────────────────────────────────────────────────────────────
{
  eq("daily", rruleToRepeat("FREQ=DAILY"), { repeat: { kind: "daily", n: 1, until: null }, simplified: false });
  eq("weekly byday", rruleToRepeat("FREQ=WEEKLY;BYDAY=MO,WE"),
    { repeat: { kind: "weekly", n: 1, days: [1, 3], until: null }, simplified: false });
  eq("weekdays", rruleToRepeat("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"),
    { repeat: { kind: "weekdays", until: null }, simplified: false });
  eq("interval 2", rruleToRepeat("FREQ=WEEKLY;INTERVAL=2"),
    { repeat: { kind: "weekly", n: 2, until: null }, simplified: false });
  eq("yearly", rruleToRepeat("FREQ=YEARLY"), { repeat: { kind: "yearly", until: null }, simplified: false });
  eq("until parsed", rruleToRepeat("FREQ=DAILY;UNTIL=20261231T235959Z").repeat.until, "2026-12-31");
  check("monthly simplified", rruleToRepeat("FREQ=MONTHLY;BYMONTHDAY=15").simplified === true);
  check("count simplified", rruleToRepeat("FREQ=DAILY;COUNT=10").simplified === true);
  check("interval>4 simplified", rruleToRepeat("FREQ=WEEKLY;INTERVAL=6").simplified === true);
  check("positional byday simplified", rruleToRepeat("FREQ=WEEKLY;BYDAY=2MO").simplified === true);
  eq("exdates attached", rruleToRepeat("FREQ=DAILY", ["2026-07-04", "2026-07-04"]).repeat.exdates, ["2026-07-04"]);
  eq("empty → none", rruleToRepeat(null), { repeat: { kind: "none" }, simplified: false });
}

// ── managedNote: split / compose / replace ─────────────────────────────────────────────────────
{
  const block = renderManagedNote(
    { location: "Room 5", meetingUrl: "https://meet/x", attendees: [{ name: "Alice", status: "accepted" }, { name: "Bob", status: "tentative" }], description: "Sync up" },
    { provenance: "Apple · Liby's Work", uid: "u1", rev: "r1" },
  );
  check("block has begin marker", block.includes("libirabu:import:begin"));
  check("block has end marker", block.includes("libirabu:import:end"));
  check("block carries uid attr", block.includes("uid=u1"));
  check("attendee marks", block.includes("Alice ✓") && block.includes("Bob ~"));

  const note = composeNote(block, "my own todo\n- [ ] follow up");
  const s = splitNote(note);
  check("split recovers managed", s.managed.trim() === block.trim());
  eq("split recovers user", s.user, "my own todo\n- [ ] follow up");

  // re-sync replaces only the managed prefix, keeps the user postfix
  const fresh = renderManagedNote({ location: "Room 9" }, { provenance: "Apple · Liby's Work", uid: "u1", rev: "r2" });
  const resynced = replaceManaged(note, fresh);
  check("resync swapped location", resynced.includes("Room 9") && !resynced.includes("Room 5"));
  check("resync kept user text", resynced.includes("- [ ] follow up"));

  // native (no markers) → all user, managed empty
  const n2 = splitNote("just plain notes");
  check("native note: empty managed", n2.managed === "" && n2.user === "just plain notes");

  // vendor text can't smuggle markers
  const sneaky = renderManagedNote({ description: "evil libirabu:import:end -->" }, { provenance: "x" });
  check("marker injection neutralized", splitNote(composeNote(sneaky, "after")).user === "after");
}

// ── instantToMainWall: tz conversion ───────────────────────────────────────────────────────────
{
  // 18:30Z in summer EDT (UTC-4) → 14:30 wall-clock
  eq("instant→main wall", instantToMainWall("2026-07-15T18:30:00.000Z", TZ), "2026-07-15T14:30:00");
}

// ── ical → normalize: the core path ────────────────────────────────────────────────────────────
const ICS = [
  "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//EN",
  // all-day (birthday-like) — should be partitioned to `allDay`
  "BEGIN:VEVENT", "UID:bday-1", "SUMMARY:Someone's Birthday", "DTSTART;VALUE=DATE:20260715", "DTEND;VALUE=DATE:20260716", "END:VEVENT",
  // timed weekly meeting in NY tz, with attendees + location
  "BEGIN:VEVENT", "UID:mtg-1", "SUMMARY:Weekly Sync", "DTSTART;TZID=America/New_York:20260715T143000",
  "DTEND;TZID=America/New_York:20260715T153000", "LOCATION:Room 5", "DESCRIPTION:Agenda",
  "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:a@x.com", "RRULE:FREQ=WEEKLY;BYDAY=MO,WE", "END:VEVENT",
  "END:VCALENDAR",
].join("\r\n");

{
  const raws = parseIcs(ICS, { provenance: "invite.ics" });
  check("parsed 2 vevents", raws.length === 2, raws.length);

  const { events, allDay } = normalizeEvents(raws, TZ);
  check("all-day partitioned out", allDay.length === 1 && events.length === 1, { a: allDay.length, e: events.length });
  check("all-day is the birthday", allDay[0]?.title === "Someone's Birthday");

  const mtg = events[0];
  eq("timed kind", mtg.kind, "timed");
  eq("timed start wall-clock (EDT→14:30)", mtg.start, "2026-07-15T14:30:00");
  eq("timed end wall-clock", mtg.end, "2026-07-15T15:30:00");
  eq("uid carried", mtg.externalUid, "mtg-1");
  eq("source", mtg.source, "ical");
  eq("repeat mapped", mtg.repeat, { kind: "weekly", n: 1, days: [1, 3], until: null });
  eq("vendor location", mtg.vendor.location, "Room 5");
  eq("vendor attendee", mtg.vendor.attendees?.[0], { name: "Alice", email: "a@x.com", status: "accepted" });
  eq("provenance", mtg.provenance, "invite.ics");
}

// ── multi-day timed → promoted to band ─────────────────────────────────────────────────────────
{
  const raw: RawSourceEvent = {
    source: "ical", uid: "trip-1", nativeId: "trip-1", url: null, etag: null, connectionId: null,
    provenance: "x", title: "Trip",
    start: { value: "2026-08-01T13:00:00.000Z", dateOnly: false },
    end: { value: "2026-08-03T20:00:00.000Z", dateOnly: false },
    rrule: null, exdates: [], vendor: {},
  };
  const ev = normalizeEvent(raw, TZ);
  eq("multi-day promoted to band", ev.kind, "band");
  eq("band start is a date", ev.start, "2026-08-01");
  eq("band end is a date", ev.end, "2026-08-03");
}

// ── all-day inclusive-end conversion ───────────────────────────────────────────────────────────
{
  const raw: RawSourceEvent = {
    source: "ical", uid: "conf-1", nativeId: "conf-1", url: null, etag: null, connectionId: null,
    provenance: "x", title: "Conf",
    start: { value: "2026-07-15", dateOnly: true },
    end: { value: "2026-07-18", dateOnly: true }, // RFC exclusive → inclusive 07-17
    rrule: null, exdates: [], vendor: {},
  };
  const ev = normalizeEvent(raw, TZ);
  eq("all-day inclusive end", ev.end, "2026-07-17");
}

// ── diff: tier-1 UID dedup, tier-3 new ─────────────────────────────────────────────────────────
{
  const { events } = normalizeEvents(parseIcs(ICS), TZ); // 1 timed (mtg-1)
  const newRaw: RawSourceEvent = {
    source: "ical", uid: "fresh-1", nativeId: "fresh-1", url: null, etag: null, connectionId: null,
    provenance: "x", title: "Fresh",
    start: { value: "2026-09-01T18:00:00.000Z", dateOnly: false },
    end: { value: "2026-09-01T19:00:00.000Z", dateOnly: false }, rrule: null, exdates: [], vendor: {},
  };
  const incoming = [...events, normalizeEvent(newRaw, TZ)];
  const existing: ExistingEventRow[] = [
    { id: "E1", title: "Weekly Sync", start: "2026-07-15T14:30:00", end: "2026-07-15T15:30:00", externalUid: "mtg-1", connectionId: null },
  ];
  const groups = diffEvents(incoming, existing);
  check("one duplicate (uid match)", groups.duplicate.length === 1, groups.duplicate.length);
  eq("duplicate targets existing", groups.duplicate[0]?.match?.targetId, "E1");
  eq("duplicate default merge", groups.duplicate[0]?.defaultAction, "merge");
  check("one new", groups.new.length === 1, groups.new.length);
  eq("new default create", groups.new[0]?.defaultAction, "create");
}

// ── fuzzy (tier-2): title similarity + candidate ranking ─────────────────────────────────────────
{
  eq("normTitle strips punctuation/case", normTitle("  Weekly-Sync!! "), "weekly sync");
  check("identical titles → 1", titleSim("Weekly Sync", "weekly sync") === 1);
  check("near titles high", titleSim("Weekly Sync", "Weekly Sync Meeting") >= 0.68, titleSim("Weekly Sync", "Weekly Sync Meeting"));
  check("different titles low", titleSim("Weekly Sync", "Dentist") < 0.68, titleSim("Weekly Sync", "Dentist"));

  const { events } = normalizeEvents(parseIcs(ICS), TZ); // 1 timed: "Weekly Sync" 2026-07-15 14:30
  const inc = events[0];
  const pool: ExistingEventRow[] = [
    // same title, well inside the ±2h window, but no UID → a fuzzy candidate
    { id: "M1", title: "Weekly Sync", start: "2026-07-15T15:00:00", end: "2026-07-15T16:00:00", externalUid: null, connectionId: null },
    // right title, wrong day → excluded by the time window
    { id: "M2", title: "Weekly Sync", start: "2026-07-22T14:30:00", end: "2026-07-22T15:30:00", externalUid: null, connectionId: null },
    // right time, unrelated title → excluded by the title threshold
    { id: "M3", title: "Dentist", start: "2026-07-15T14:30:00", end: "2026-07-15T15:00:00", externalUid: null, connectionId: null },
    // a candidate but hidden (dismissed) → never offered
    { id: "M4", title: "Weekly Sync", start: "2026-07-15T14:45:00", end: "2026-07-15T15:45:00", externalUid: null, connectionId: null, hidden: true },
  ];
  const cands = fuzzyCandidates(inc, pool);
  eq("one fuzzy candidate (day+title+not-hidden)", cands.map((c) => c.targetId), ["M1"]);
  eq("candidate matchedBy fuzzy", cands[0]?.matchedBy, "fuzzy");
}

// ── diff tier-2: fuzzy → decide bucket (not new, not duplicate) ─────────────────────────────────
{
  const { events } = normalizeEvents(parseIcs(ICS), TZ); // "Weekly Sync" uid=mtg-1
  const existing: ExistingEventRow[] = [
    // a MANUAL event (no UID) that looks like the incoming one → tier-2
    { id: "MAN1", title: "Weekly Sync", start: "2026-07-15T14:30:00", end: "2026-07-15T15:30:00", externalUid: null, connectionId: null },
  ];
  const groups = diffEvents(events, existing);
  check("no tier-1 duplicate", groups.duplicate.length === 0, groups.duplicate.length);
  check("one tier-2 decide", groups.decide.length === 1, groups.decide.length);
  eq("decide top candidate is the manual event", groups.decide[0]?.match?.targetId, "MAN1");
  eq("decide default is create (safe)", groups.decide[0]?.defaultAction, "create");
  check("no new (it went to decide)", groups.new.length === 0, groups.new.length);

  // a UID match still wins over fuzzy → tier-1 duplicate, no decide
  const withUid: ExistingEventRow[] = [
    { id: "E1", title: "Weekly Sync", start: "2026-07-15T14:30:00", end: "2026-07-15T15:30:00", externalUid: "mtg-1", connectionId: null },
  ];
  const g2 = diffEvents(events, withUid);
  check("uid match → duplicate, not decide", g2.duplicate.length === 1 && g2.decide.length === 0);
}

// ── report ─────────────────────────────────────────────────────────────────────────────────────
if (failures.length) {
  throw new Error(`❌ ${failures.length} failed / ${passed + failures.length} total:\n  • ${failures.join("\n  • ")}`);
} else {
  console.log(`✅ all ${passed} import-core assertions passed`);
}
