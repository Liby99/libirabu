// The "managed note block" for imported events (docs/calendar-import-design.md §7).
//
// An imported event's note has a fixed two-region layout: a vendor-owned managed block (PREFIX) and
// the user's own free text (POSTFIX). The block is delimited by HTML comments, which render
// invisibly in NotesPreview (it runs react-markdown without rehype-raw) yet persist in the stored
// string — so we can split on them to replace just the vendor part on re-sync, leaving user text
// untouched. The editor only ever edits the postfix, so the user can't touch the managed region.
//
// Marker namespace is source-neutral ("libirabu:import"), not Google-specific, since the primary
// source is Apple Calendar.

import type { VendorDetails, Attendee } from "./types";

const BEGIN = "libirabu:import:begin";
const END = "libirabu:import:end";

// Matches a whole managed block (markers + body), tolerant of the attributes on the begin marker.
const BLOCK_RE = new RegExp(`<!--\\s*${BEGIN}[\\s\\S]*?${END}\\s*-->`, "i");

export interface ManagedSplit {
  managed: string; // the full managed block incl. markers ("" when none)
  user: string; // everything the user owns (the editable postfix)
}

/** Split a stored note into its managed prefix and user postfix. `managed` is "" for native notes. */
export function splitNote(notes: string | null | undefined): ManagedSplit {
  const text = notes ?? "";
  const m = BLOCK_RE.exec(text);
  if (!m) return { managed: "", user: text };
  const before = text.slice(0, m.index);
  const after = text.slice(m.index + m[0].length);
  // The block is canonically the prefix; fold any stray before/after text into the user region.
  const user = `${before}${after}`.replace(/^\s+/, "").trimEnd();
  return { managed: m[0], user };
}

/** Recombine a managed block and user text into the canonical "prefix + blank line + postfix" note. */
export function composeNote(managed: string, user: string): string {
  const m = managed.trim();
  const u = (user ?? "").trim();
  if (!m) return u;
  return u ? `${m}\n\n${u}` : m;
}

/** Re-sync: swap in a freshly-rendered managed block, preserving the user's postfix verbatim. */
export function replaceManaged(notes: string | null | undefined, freshManaged: string): string {
  const { user } = splitNote(notes);
  return composeNote(freshManaged, user);
}

/** Strip just the managed-block MARKERS (keeping their content) → a plain, fully-editable note.
 *  Used when "internalizing" an imported event into a manual copy: the vendor details become
 *  ordinary markdown the user owns (no longer replaced on re-sync). */
export function flattenManaged(notes: string | null | undefined): string {
  return (notes ?? "")
    .replace(new RegExp(`[ \\t]*<!--\\s*${BEGIN}[\\s\\S]*?-->[ \\t]*\\n?`, "i"), "")
    .replace(new RegExp(`[ \\t]*<!--\\s*${END}\\s*-->[ \\t]*\\n?`, "i"), "")
    .trim();
}

// ── Rendering vendor details → the managed block ────────────────────────────────────────────────

// Keep vendor-supplied text from smuggling in our markers (which would corrupt later splits).
const sanitize = (s: string): string => s.replace(/libirabu:import:(begin|end)/gi, "libirabu import");

const STATUS_MARK: Record<Attendee["status"], string> = {
  accepted: "✓",
  declined: "✗",
  tentative: "~",
  "needs-action": "?",
  unknown: "",
};

function renderAttendee(a: Attendee): string {
  const name = a.name?.trim() || a.email?.trim() || "someone";
  const mark = STATUS_MARK[a.status];
  return mark ? `${name} ${mark}` : name;
}

export interface ManagedMeta {
  provenance: string; // human label shown in the block ("Apple · Google · Liby's Work")
  uid?: string | null;
  rev?: string | null; // change token (etag/lastModified) — lets re-sync skip unchanged
}

const isUrl = (s: string) => /^https?:\/\//i.test(s.trim());

// Vendor descriptions (Google/Exchange) are often HTML. Convert to clean markdown so it renders
// nicely (links clickable, no raw tags) and stays safe (no raw-HTML injection into the preview).
export function htmlToMarkdown(s: string): string {
  if (!/[<&]/.test(s)) return s.trim(); // plain text already
  return s
    .replace(/<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, (_m, href, text) => `[${text.replace(/<[^>]+>/g, "").trim() || href}](${href})`)
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|h[1-6]|li|tr)>/gi, "\n")
    .replace(/<li\b[^>]*>/gi, "\n• ")
    .replace(/<[^>]+>/g, "") // strip remaining tags
    .replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"').replace(/&#0?39;/gi, "'").replace(/&#(\d+);/g, (_m, n) => String.fromCharCode(+n))
    .replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}

// Label a meeting URL by its provider (so a Zoom link reads "zoom:", a Meet link "meet:", …).
function linkLabel(url: string): string {
  try {
    const host = new URL(url).hostname.replace(/^www\./, "").toLowerCase();
    if (host.includes("zoom.")) return "zoom";
    if (host.includes("meet.google")) return "meet";
    if (host.includes("teams.")) return "teams";
    if (host.includes("webex")) return "webex";
    return "link";
  } catch { return "link"; }
}

/**
 * Render a vendor event's details into a managed block. The machine identity (uid + rev) lives ONLY
 * in the marker comment (invisible in preview, stripped from the editor). The body is a set of
 * `key: value` lines — clean as monospace in the raw editor, and parsed into a key/value table by
 * the preview (parseManaged). Any free-text description trails after a blank line. Result is a
 * PREFIX — callers compose it with the user's postfix.
 */
export function renderManagedNote(vendor: VendorDetails, meta: ManagedMeta): string {
  const attrs = [meta.uid ? `uid=${meta.uid}` : "", meta.rev ? `rev=${meta.rev}` : ""]
    .filter(Boolean)
    .join(" ");
  const lines: string[] = [`<!-- ${BEGIN}${attrs ? " " + attrs : ""} -->`];

  lines.push(`imported from: ${sanitize(meta.provenance)}`);
  const revDate = meta.rev ? String(meta.rev).slice(0, 10) : "";
  if (revDate) lines.push(`rev: ${revDate}`);

  const url = vendor.meetingUrl?.trim() || (vendor.location && isUrl(vendor.location) ? vendor.location.trim() : "");
  if (url) lines.push(`${linkLabel(url)}: ${url}`);
  if (vendor.location?.trim() && !isUrl(vendor.location)) lines.push(`location: ${sanitize(vendor.location.trim())}`);
  if (vendor.organizer?.trim()) lines.push(`organizer: ${sanitize(vendor.organizer.trim())}`);

  const attendees = vendor.attendees ?? [];
  if (attendees.length) lines.push(`attendees: ${attendees.map(renderAttendee).map(sanitize).join(", ")}`);

  const desc = vendor.description ? htmlToMarkdown(vendor.description) : "";
  if (desc) {
    lines.push("");
    lines.push(sanitize(desc));
  }

  lines.push(`<!-- ${END} -->`);
  return lines.join("\n");
}

export interface ManagedField { label: string; value: string; href?: string }

/**
 * Parse a stored managed block (markers stripped) into its `key: value` fields + trailing free-text
 * description — for the structured key/value rendering in the note preview. The UID is never here
 * (it lives in the marker comment, which is dropped by flattenManaged).
 */
export function parseManaged(managed: string): { fields: ManagedField[]; description: string } {
  const lines = flattenManaged(managed).split("\n");
  const fields: ManagedField[] = [];
  let i = 0;
  for (; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "") { i++; break; } // blank line → the rest is the description
    const m = line.match(/^([\w ]+?):\s*(.*)$/);
    if (!m) break; // first non key:value line → description starts here
    const value = m[2].trim();
    fields.push({ label: m[1].trim(), value, href: isUrl(value) ? value : undefined });
  }
  return { fields, description: lines.slice(i).join("\n").trim() };
}
