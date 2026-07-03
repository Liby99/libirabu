"use client";

// Help content registry. Each section is one entry in the left rail of the Help modal
// (see HelpModal.tsx). Bodies are plain JSX so they can mix prose, shortcut tables, and
// callouts freely. Copy is end-user friendly — describe the gesture/input and the result.
// Facts here are checked against the interaction + layer code; keep them in sync on change.

import type { ReactNode } from "react";

export type HelpSectionId =
  | "overview"
  | "navigating"
  | "events"
  | "deadlines"
  | "notes"
  | "tags"
  | "daily"
  | "import"
  | "assistant"
  | "keys";

export interface HelpSection {
  id: HelpSectionId;
  label: string; // rail label
  body: ReactNode; // right-pane content
}

// Inline key-cap: <Key>⌘Z</Key>.
export function Key({ children }: { children: ReactNode }) {
  return <kbd className="cc-help-kbd">{children}</kbd>;
}

// Two-column shortcut table. Each row is { k: keys, d: description }. Objects (not tuples)
// so the JSX key-caps sit in property values, not directly in an array literal.
export function Keys({ rows }: { rows: { k: ReactNode; d: ReactNode }[] }) {
  return (
    <table className="cc-help-keys">
      <tbody>
        {rows.map((r, i) => (
          <tr key={i}>
            <td className="cc-help-keys-k">{r.k}</td>
            <td className="cc-help-keys-d">{r.d}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

// ── Sections ──────────────────────────────────────────────────────────────────

const Overview = (
  <>
    <p>
      This is a zoomable timeline calendar. The same space shows four levels of detail — a
      whole <strong>year</strong>, a <strong>month</strong>, a <strong>week</strong>, or a
      single <strong>day</strong> — and you move between them by zooming in and out.
    </p>
    <h3>Three kinds of things live on it</h3>
    <ul>
      <li><strong>Timed events</strong> — anything with a start and end time, shown as blocks on the week/day timeline.</li>
      <li><strong>All-day “band” events</strong> — multi-day bars that run across one of a month’s four tracks (T1–T4).</li>
      <li><strong>Deadlines</strong> — a single moment in time, marked on the timeline with a label.</li>
    </ul>
    <h3>Where things are</h3>
    <ul>
      <li>The <strong>breadcrumb bar</strong> across the top shows where you are (Year › Month › Week › Day); click any crumb to jump back up.</li>
      <li><strong>Edit</strong>, <strong>View</strong>, and <strong>Help</strong> menus sit in the top bar, plus a <strong>Connectivity</strong> control for import &amp; sync.</li>
      <li>The floating <strong>assistant</strong> button (bottom-right) opens an AI chat that can read and change your calendar.</li>
    </ul>
    <p>See the other sections for the details of each area, or jump straight to
      <strong> Keyboard Shortcuts</strong> for the quick reference.</p>
  </>
);

const Navigating = (
  <>
    <p>The calendar has four zoom levels. Zoom <strong>in</strong> to get more detail, zoom
      <strong> out</strong> for the bigger picture.</p>
    <h3>Zooming</h3>
    <ul>
      <li><strong>Pinch</strong> on a trackpad to zoom smoothly in and out. Zooming starts from the date under your cursor, so you land where you were looking.</li>
      <li><strong>Click</strong> a month, week, or day to zoom into it.</li>
      <li>Press <Key>Esc</Key> to zoom out one level (day → week → month → year).</li>
    </ul>
    <h3>Panning</h3>
    <ul>
      <li><strong>Year</strong> — scroll up/down through the months. Push past January or December and hold to jump to the previous/next year.</li>
      <li><strong>Month</strong> — drag up/down to page between months. Release past ~40% to commit; pull back to cancel.</li>
      <li><strong>Week</strong> — drag left/right to slide the 7-day window a day at a time; scroll up/down to move through the hours. Push past the first/last week to cross into the neighboring month.</li>
      <li><strong>Day</strong> — drag left/right to move to the previous/next day.</li>
    </ul>
    <h3>Jumping to now</h3>
    <p>Use the <strong>View</strong> menu to jump straight to <strong>Today</strong>,
      <strong> This Week</strong>, <strong>This Month</strong>, or <strong>This Year</strong>.
      The week and day views center on the current time. To change the year, click the year in
      the breadcrumb bar and pick from the list.</p>
  </>
);

const Events = (
  <>
    <h3>Creating an event</h3>
    <ul>
      <li><strong>Timed event</strong> — in week or day view, drag vertically on an empty part of the timeline. The drag sets the start and end (snapped to 30 minutes).</li>
      <li><strong>All-day band</strong> — in month view, drag sideways across a track lane to make a multi-day bar.</li>
    </ul>
    <p>A new event starts named “Event” with its name selected — just type to rename it, then
      press <Key>Enter</Key>. An untouched “Event” you never name is discarded automatically.</p>
    <h3>Selecting &amp; quick edits</h3>
    <p>Click an event to select it. With something selected:</p>
    <Keys
      rows={[
        { k: <Key>Enter</Key>, d: "Rename in place (deadlines open their editor instead)" },
        { k: <Key>Space</Key>, d: "Open the full editor (drawer)" },
        { k: <><Key>↑</Key> / <Key>↓</Key></>, d: "Nudge a timed event 15 minutes earlier / later" },
        { k: <><Key>Delete</Key> / <Key>Backspace</Key></>, d: "Delete it" },
      ]}
    />
    <p>You can also <strong>drag the body</strong> of a timed event to move it (snapped to 15
      minutes, keeping its length), or drag its <strong>top/bottom edge</strong> to resize.
      Right-click any event for a quick color swatch and a delete button.</p>
    <h3>The editor (drawer)</h3>
    <p>Press <Key>Space</Key> or double-click to open the drawer, where you can set the
      title, date and time, color, tags, notes, and:</p>
    <ul>
      <li><strong>Repeat</strong> — none, daily, weekdays, weekly (pick the days), or yearly, with an optional “until” date.</li>
      <li><strong>Promote to band</strong> — mirror a timed event or deadline as an all-day bar on a chosen track.</li>
      <li><strong>Per-occurrence notes</strong> — for a repeating event, notes attached to just that one date.</li>
    </ul>
    <h3>Copy, cut &amp; paste</h3>
    <p>With an event selected, <Key>⌘C</Key> copies and <Key>⌘X</Key> cuts it; <Key>⌘V</Key>
      pastes at your cursor. Pasting always makes a single event (any repeat rule is dropped).</p>
    <h3>Deleting a repeat</h3>
    <p>Deleting a repeating event asks what to remove: <strong>this occurrence</strong>,
      <strong> this and everything after</strong>, or <strong>the whole series</strong>.</p>
  </>
);

const Deadlines = (
  <>
    <p>A deadline marks a single moment — a due time rather than a block of time. It shows on
      the week/day timeline as a labeled line.</p>
    <h3>Creating &amp; moving</h3>
    <ul>
      <li>Hover the timeline and click the <strong>“+ Add deadline”</strong> button that appears to drop one at that time.</li>
      <li><strong>Drag</strong> a deadline up or down the timeline to change its time, or select it and use <Key>↑</Key> / <Key>↓</Key> to nudge it 15 minutes.</li>
      <li>Double-click (or select and press <Key>Space</Key>) to open its editor.</li>
    </ul>
    <h3>In the editor</h3>
    <ul>
      <li><strong>Origin timezone</strong> — set the zone the deadline is “really” in. You edit it in that zone while it’s stored and displayed in your own timezone.</li>
      <li><strong>Promote to band</strong> — also show it as an all-day bar on a track.</li>
      <li>Deadlines support the same <strong>repeat</strong>, <strong>tags</strong>, and <strong>notes</strong> as events.</li>
    </ul>
  </>
);

const Notes = (
  <>
    <p>Every event, and every day, has a Markdown notes area. Notes support headings, bold and
      italic, lists, links, code, quotes, and <strong>to-do checkboxes</strong>.</p>
    <h3>To-dos</h3>
    <p>Write a checkbox with <code>- [ ]</code> (done: <code>- [x]</code>). Every to-do across
      all your notes is gathered into the <strong>Daily View</strong> dashboard, so you can see
      and check them off in one place.</p>
    <h3>Editing</h3>
    <Keys
      rows={[
        { k: <Key>⌘F</Key>, d: "Search within the notes" },
        { k: <Key>⌘⌥F</Key>, d: "Search and replace" },
        { k: <Key>⌘⇧V</Key>, d: "Toggle between editing and rendered preview" },
        { k: <><Key>⌥↑</Key> / <Key>⌥↓</Key></>, d: "Move the current line up / down" },
      ]}
    />
    <p>In preview mode, checkboxes are clickable and links open in a new tab. Clicking a to-do
      in the preview jumps to its line in the editor. Notes editing has its own undo history,
      independent of the calendar’s.</p>
  </>
);

const Tags = (
  <>
    <h3>Tagging</h3>
    <p>Open any event’s editor and use the <strong>Tags</strong> field — type a tag and press
      <Key>Enter</Key> to add it, or click <strong>×</strong> to remove one. Tags are shared
      across every kind of item.</p>
    <h3>Filtering by tag</h3>
    <p>Open <strong>View → Tag Filter</strong>. Check the tags you want to see; anything with at
      least one checked tag stays visible. Use <strong>Show All</strong> / <strong>Show None</strong>
      to flip everything at once, and the “untagged” row to control items with no tags. When a
      filter is active the View button is highlighted so you don’t forget it’s on.</p>
    <h3>Other visibility toggles</h3>
    <ul>
      <li><strong>Dim past events</strong> — fade anything whose time has already passed, so upcoming items stand out.</li>
      <li><strong>Show hidden events</strong> — reveal imported events you’ve hidden (shown dimmed) so you can inspect or restore them.</li>
    </ul>
  </>
);

const Daily = (
  <>
    <p>Zoom all the way in to <strong>Day view</strong>: the day’s hourly timeline on the left,
      a dashboard on the right.</p>
    <h3>The dashboard</h3>
    <ul>
      <li><strong>Deadlines &amp; to-dos</strong> — everything due today, overdue, or due soon, plus the to-dos pulled from all your notes. Click a row to jump to and open that item.</li>
      <li><strong>Checking off</strong> — click a to-do’s checkbox to strike it through; after a moment it drops into “Recently completed.” It’s saved automatically.</li>
      <li><strong>Day note</strong> — a Markdown note just for that day, with the same editor and preview as event notes.</li>
    </ul>
    <p>Drag the divider between the timeline and the dashboard to resize them; the split is
      remembered. In week and day view you can also adjust the hour height so the timeline shows
      more detail or more hours at once.</p>
  </>
);

const Import = (
  <>
    <p>The <strong>Connectivity</strong> control in the top bar brings outside calendars in and
      keeps them current. It shows how many calendars are connected and when they last synced.</p>
    <h3>Apple Calendar</h3>
    <p>Grant Calendar access, then pick which of your Apple calendars to connect. <strong>Sync</strong>
      pulls in new and changed events. Turn on <strong>Automatic sync</strong> to keep them updated
      in the background.</p>
    <h3>Import an .ics file</h3>
    <p>Choose <strong>Import .ics</strong> and drop in a file. You’ll get a preview of what’s new
      and what looks like a duplicate; check the items you want and apply. Very complex repeat
      rules may be simplified on import (you’ll be warned).</p>
    <h3>Duplicates &amp; triage</h3>
    <p>When an incoming event looks like it <em>might</em> match one you already have, it goes to
      <strong> Triage</strong>. For each one you get the incoming event, the candidate it may match,
      an AI hint, and a choice: <strong>Merge</strong>, <strong>Import as new</strong>, or
      <strong> Skip</strong>.</p>
    <h3>Imported events</h3>
    <ul>
      <li>Imported events are read-only. Use <strong>Make editable</strong> in the drawer to keep your own editable copy.</li>
      <li>Deleting an imported event <strong>hides</strong> it rather than destroying it; a later sync may bring it back. Use <strong>View → Show hidden events</strong> to see and restore hidden items.</li>
      <li><strong>Clear all imported</strong> removes every imported event at once (your own events stay). The next sync re-imports from scratch.</li>
    </ul>
  </>
);

const Assistant = (
  <>
    <p>The floating button in the bottom-right corner opens an AI <strong>assistant</strong> that
      can see and act on your calendar. Drag the button to reposition it; click to open the chat.</p>
    <h3>What it can do</h3>
    <ul>
      <li>Answer questions about your schedule, notes, and what’s currently on screen.</li>
      <li><strong>Create, change, and delete</strong> events, band events, and deadlines.</li>
      <li>Navigate the calendar for you — zoom to a level and scroll to a date.</li>
      <li>Search the web when a request needs outside information.</li>
    </ul>
    <h3>Using it</h3>
    <p>Type a request and press <Key>Enter</Key> to send (<Key>⇧Enter</Key> for a new line). Use
      the paperclip to attach a file (like an <code>.ics</code>) for it to read, and the model
      selector to choose which Claude model answers. Actions it takes appear as cards you can
      expand, and the calendar refreshes as it works.</p>
  </>
);

const KeyboardSection = (
  <>
    <p>On Windows/Linux, use <Key>Ctrl</Key> wherever <Key>⌘</Key> is shown.</p>
    <h3>General</h3>
    <Keys
      rows={[
        { k: <Key>Esc</Key>, d: "Zoom out one level" },
        { k: <Key>⌘Z</Key>, d: "Undo" },
        { k: <><Key>⌘⇧Z</Key> / <Key>⌘Y</Key></>, d: "Redo" },
      ]}
    />
    <h3>Selected event</h3>
    <Keys
      rows={[
        { k: <Key>Enter</Key>, d: "Rename in place (deadline: open editor)" },
        { k: <Key>Space</Key>, d: "Open the editor" },
        { k: <><Key>↑</Key> / <Key>↓</Key></>, d: "Nudge 15 min earlier / later (timed & deadlines)" },
        { k: <><Key>Delete</Key> / <Key>Backspace</Key></>, d: "Delete" },
        { k: <Key>⌘C</Key>, d: "Copy" },
        { k: <Key>⌘X</Key>, d: "Cut" },
        { k: <Key>⌘V</Key>, d: "Paste at the cursor" },
      ]}
    />
    <h3>Notes editor</h3>
    <Keys
      rows={[
        { k: <Key>⌘F</Key>, d: "Find" },
        { k: <Key>⌘⌥F</Key>, d: "Find and replace" },
        { k: <Key>⌘⇧V</Key>, d: "Toggle edit / preview" },
        { k: <><Key>⌥↑</Key> / <Key>⌥↓</Key></>, d: "Move line up / down" },
      ]}
    />
    <h3>Assistant</h3>
    <Keys
      rows={[
        { k: <Key>Enter</Key>, d: "Send message" },
        { k: <Key>⇧Enter</Key>, d: "New line" },
      ]}
    />
  </>
);

export const HELP_SECTIONS: HelpSection[] = [
  { id: "overview", label: "Overview", body: Overview },
  { id: "navigating", label: "Navigating & Zooming", body: Navigating },
  { id: "events", label: "Events", body: Events },
  { id: "deadlines", label: "Deadlines", body: Deadlines },
  { id: "notes", label: "Notes", body: Notes },
  { id: "tags", label: "Tags & Filtering", body: Tags },
  { id: "daily", label: "Daily View", body: Daily },
  { id: "import", label: "Import & Sync", body: Import },
  { id: "assistant", label: "AI Assistant", body: Assistant },
  { id: "keys", label: "Keyboard Shortcuts", body: KeyboardSection },
];
