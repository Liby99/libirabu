# Note Attachments — Design Document

Status: **Draft v0.1** · Owner: ziyang · Last updated: 2026-09-16

> Attach files — images first, PDFs second, any file type third — to **every markdown note**
> (event notes, per-occurrence notes, daily/weekly/monthly scope notes). Import by **paste or
> drag** into either the editor or the preview. The markdown source carries a compact token
> (`![@pdf:…](…)`); the preview renders a **thumbnail** you can single-click to select, ⌘C to
> copy, and **space** to Quick Look (the Finder experience). Storage is a **content-addressed
> blob store** with a metadata index: the same file attached in five notes exists once on disk,
> and deleting the last reference frees the space. Sync rides the existing CKSyncEngine as a new
> asset-bearing record type. **Zero third-party dependencies** — everything is an Apple framework.

---

## 1. Goals

1. Paste (⌘V) or drag an image / PDF / any file into a note — editor **or** preview pane.
2. A stable, human-readable token in the markdown source; plain-markdown renderers degrade
   gracefully (it's still standard image syntax).
3. Preview: inline **thumbnails** (images and PDFs at least; any type with a Quick Look
   generator gets one, others get an icon chip). Click to select → highlighted; ⌘C copies the
   real file; **space** opens the system Quick Look panel; double-click opens in the default app.
4. **Deduplicated storage**: content-addressed by SHA-256; N references, 1 blob.
5. **Space reclamation**: removing the last markdown reference eventually deletes the blob.
6. **Sync**: attachments follow their calendar's iCloud zone; the iPhone client renders them
   read-only.
7. **Backup**: `.mgc` exports carry the blobs (matching the web format's `files/` convention).

Non-goals (v1): editing attachments in place, video/audio playback inline, attachment search,
external-file *links* (referencing without copying), per-attachment encryption.

---

## 2. Current state (from the 2026-09-16 code audit)

| Subsystem | Fact | Consequence |
|---|---|---|
| Editor | `NativeNoteEditor` (NSTextView, `isRichText = false`, no dragged types registered, no `paste` override) | Paste/drop entry points must be added; plain-text model is *right* — we insert a token, never an attachment object |
| Highlight | `MarkdownHighlight.linkRe` doesn't know `![…](…)` | Add a token regex + pill styling |
| Preview | `MarkdownPreview` = custom line parser → one `NSAttributedString` in a `PreviewTextView`; no `![` branch; checkbox clicks route via a `cc-todo://` link scheme | Add an attachment block/inline branch with `NSTextAttachment` thumbnails; reuse the link-scheme routing for clicks |
| Storage | `Application Support/CalendarKit/` has no blob dir; `RichFields` decodes tolerantly | `files/` CAS is virgin space; no schema migration risk |
| Sync | Zone per calendar; record types materialized in `CloudSync.materialize`, diffed in `recordDelta`; **CKAsset unused so far**; record cache stores system fields only | One new record type + one new diff branch; asset payloads never bloat the record cache |
| Backup | `Zipper` already round-trips nested entry paths; web format defines `files/<storagePath>` + an `attachment` table (`sha256`, `storagePath`, `mime`, `bytes`) | Backup shape is pre-paved; native just starts filling it |
| iPhone | `PhoneMarkdown` is a separate small renderer (no images), data via the same CloudSync (read-only) | Needs its own (small) image case + QuickLook |

---

## 3. Token grammar (the markdown source form)

Standard markdown **image** syntax, so any other renderer shows readable alt text instead of
garbage:

```
![@image:screenshot 2026-09-16.png](ccfile:9f8a3b2c1d4e5f60)
![@pdf:NSF proposal draft.pdf](ccfile:0a1b2c3d4e5f6a7b)
![@file:results.csv](ccfile:aa11bb22cc33dd44)
```

- **Alt part** `@<kind>:<display name>`: `kind ∈ {image, pdf, file}` — a *display* hint only
  (renderers decide by the real UTI from the index; the kind keeps the raw source scannable,
  per the product requirement that PDFs read as `![@pdf:…]`). The display name is the original
  filename, editable by the user in place (it's just text — renaming the token renames the
  attachment's display name everywhere *in that note only*, by design).
- **URL part** `ccfile:<id>`: `id` = the **first 16 hex chars of the blob's SHA-256** (64 bits —
  collision-proof at personal scale; the index stores the full hash, and the importer extends
  the id to 20/24 chars in the astronomically-unlikely prefix-collision case).
- Grammar (both editor highlight and preview parse):
  `!\[@(image|pdf|file):([^\]]*)\]\(ccfile:([0-9a-f]{16,64})\)`
- **Placement rule**: a token alone on its line renders as a **block thumbnail**; a token inside
  a line renders as a small **inline chip** (icon + name). Paste/drag always inserts block form
  (own line) — inline chips only arise from hand-editing.

Why not bare `![name](ccfile:…)`? The explicit `@kind:` satisfies the requirement that the raw
source telegraphs what it is, and gives the highlighter an anchor that can't collide with
ordinary web images (`![chart](https://…)` still renders as alt text, unchanged).

---

## 4. Storage scheme (local)

```
Application Support/CalendarKit/
  files/
    blobs/9f/9f8a3b2c…<full 64-hex sha256>.png      ← content-addressed, fan-out by first byte
    thumbs/9f8a3b2c1d4e5f60@2x.png                  ← generated thumbnail cache (disposable)
    index.json                                       ← the metadata "small database"
```

- **CAS is global** (not per calendar): dedup works across calendars; sync/GC reference-tracking
  is per calendar (§6). The extension on the blob file is cosmetic (helps Quick Look and manual
  inspection); identity is the hash.
- **`index.json`** — one JSON dict keyed by full sha256, mirroring the repo's JSON-store
  philosophy (`data.json`, `calendars.json`; no SQLite — at personal scale, hundreds of
  attachments, a single JSON file loaded once is simpler than a second database technology,
  and it stays greppable/debuggable):

```json
{
  "version": 1,
  "files": {
    "<sha256>": {
      "name": "NSF proposal draft.pdf",      // original filename at first import
      "uti": "com.adobe.pdf",                 // UTType identifier (authoritative kind)
      "bytes": 1834022,
      "addedAt": "2026-09-16T10:22",
      "lastReferencedAt": "2026-09-16T10:22"  // GC grace-period clock (§7)
    }
  }
}
```

- Import pipeline (`AttachmentStore.import(data:suggestedName:) -> Token`):
  1. SHA-256 via **CryptoKit** on the raw bytes.
  2. Already in `files/`? → bump `lastReferencedAt`, return the existing id (dedup).
  3. Else write blob atomically (temp + rename), insert index row, return token.
  - Images: paste can arrive as TIFF from the pasteboard — **normalize to PNG** before hashing
    (otherwise the same screenshot pasted twice can hash differently). Files dragged from disk
    are hashed as-is. Oversize guard: warn > 50 MB, refuse > 200 MB (headroom under the
    ~250 MB practical CKAsset ceiling).
- `AttachmentStore` is a `@MainActor` engine-owned object (like `ItemStore`), with the index
  held in memory and persisted through the same debounced `schedulePersist` rhythm.

---

## 5. UX & rendering

### 5.1 Import surfaces

| Surface | Mechanism |
|---|---|
| Editor paste | `EditorTextView.paste(_:)` override: pasteboard has file URLs / image data / PDF data → import → insert token(s) at caret (own line); else `super.paste` |
| Editor drag | `registerForDraggedTypes([.fileURL, .png, .tiff, .pdf])` + `performDragOperation`; caret follows the drag point (`characterIndexForInsertion(at:)`); accept `NSFilePromiseReceiver` too (drags from Mail/Photos deliver promises, not URLs) |
| Preview drag/click-paste | `PreviewTextView` gets the same drop handling; the token is **appended to the end of the note** (preview has no caret), then the preview rebuilds |
| Sandbox note | Import copies bytes into the CAS immediately, inside the drag/paste grant window — no security-scoped bookmarks needed since we never re-open the source path |

### 5.2 Editor display

The editor stays plain text (the token *is* the source of truth — no hidden attachment objects,
no `isRichText`). `MarkdownHighlight` gains the token regex: the `@kind:name` span renders in
the accent color over a rounded background wash (the existing token-pill treatment), the
`ccfile:…` span dims to `textMuted` — visually "this is an object", still hand-editable.

### 5.3 Preview display

New `MarkdownDoc` branch (before the bullet/paragraph fallthrough):

- **Block token** (alone on its line) → an `NSTextAttachment` sized to the thumbnail
  (images: max 320×220 pt, actual aspect; PDFs: first page at the same cap with a subtle page
  edge; other types: the file's icon at 64 pt + name/size caption line). A `.link:
  ccsel://<line>/<id>` attribute rides on the attachment for click routing, exactly like
  `cc-todo://`.
- **Inline token** → small chip: 16 pt icon + display name, same link attribute.
- **Thumbnails are async**: `QLThumbnailGenerator` (QuickLookThumbnailing) covers images, PDFs,
  and anything with a QL plugin. First render inserts a placeholder (icon + name); the
  generation callback writes `files/thumbs/<id>@2x.png` and bumps a `thumbGen` observable →
  preview rebuilds; every later render is synchronous from the disk cache. Cache invalidation
  is trivial: content-addressed → a thumb is immutable; deleting the blob deletes the thumb.

### 5.4 Selection, copy, Quick Look, open

- **Single click** (via the `ccsel://` link route, which fires on mouse-up without needing
  text selection): `PreviewTextView` records `selectedAttachment: (line, id)` and redraws a
  selection ring (accent, rounded — the `decor` overlay pattern) around the attachment rect;
  clicking elsewhere clears it. Single selection only in v1.
- **⌘C** with a selected attachment: `PreviewTextView.copy(_:)` override writes to the general
  pasteboard: the **file URL** (a hardlink in a temp dir named `<display name>` so a Finder
  paste produces "NSF proposal draft.pdf", not "0a1b…pdf") + image data flavor for images.
- **Space** → **`QLPreviewPanel`** (QuickLookUI): `PreviewTextView` implements
  `acceptsPreviewPanelControl` / `beginPreviewPanelControl` / `endPreviewPanelControl` +
  `QLPreviewPanelDataSource` (the responder-chain contract). The preview item is a small
  `QLPreviewItem` wrapper: `previewItemURL` = the display-named hardlink, `previewItemTitle` =
  display name. `keyDown` space with a selection toggles the shared panel — byte-for-byte the
  Finder interaction. The app-level key monitor (`CatcherView.installKeyMonitor`) must yield
  space to the preview text view when it's first responder with a selection.
- **Double-click** → `NSWorkspace.open` on the hardlink (default app).
- **Editor-side niceties** (v1.5): ⌘-click a token in the editor Quick Looks it
  (`NativeNoteEditor.linkAt` learns `ccfile:`).

---

## 6. Synchronization scheme

New record type **`NoteFile`** in **each calendar's existing zone** (no new zone, no schema
container changes — first use of `CKAsset` in the app):

| Field | Type | Note |
|---|---|---|
| `sha256` | String | full hash (the record name is `file-<sha256>`) |
| `name` | String | display name at import |
| `uti` | String | UTType id |
| `bytes` | Int | for quota UX |
| `payload` | **CKAsset** | the blob itself (assets bypass the 1 MB record cap; ~250 MB practical ceiling — our import guard stays well under) |

- **Ownership**: an attachment record lives in every calendar zone whose notes reference it
  (cross-calendar dedup is local-only; zones must be self-contained so removing a calendar's
  zone never breaks another calendar). Refcounts are per (calendar, hash) at the sync layer.
- **Outbound**: `PersistedState` gains `attachmentRefs: [String: [String]]?` — calendar-scoped
  map of hash → referencing note keys, *derived* at persist time by scanning changed notes for
  tokens (cheap: only notes the delta already touched are rescanned). `recordDelta` gains a
  branch: a hash newly referenced in this calendar → upsert `file-<hash>`; a hash no longer
  referenced anywhere in this calendar → delete `file-<hash>`. `materialize` reads the blob
  from the CAS into the CKAsset.
- **Inbound**: `applyFetched` gains a `NoteFile` case → copy the downloaded asset file into the
  CAS (verify the hash — an asset that doesn't match its declared sha256 is dropped and
  logged), insert the index row. Deletions of `file-*` records do **not** delete local blobs
  (local GC is the only authority for local space — a delete from another device merely means
  *that calendar* stopped referencing it).
- **Ordering**: notes and their `NoteFile` records travel in the same zone but CKSyncEngine
  gives no cross-record ordering guarantee — the preview must tolerate a token whose blob
  hasn't arrived yet: render the icon chip with a "downloading…" caption; when the asset lands,
  `thumbGen` bumps and it becomes a thumbnail. Same placeholder covers the iPhone cold start.
- **iPhone (read-only)**: fetch-applies `NoteFile` into its local CAS; `PhoneMarkdown` gains an
  image/attachment case (thumbnail via the same QuickLookThumbnailing API, tap →
  `QLPreviewController`). No upload path (already gated by `readOnly`).

---

## 7. Reference counting & space reclamation

**Derived, not stored.** A persisted refcount drifts under exactly the operations this app is
built on — undo/redo of note edits, sync merges (local-wins races), crash between note-write
and count-write. The notes *are* the reference database; counting is a scan:

- `references(hash)` = token occurrences across **all calendars'** `rich.notes` +
  `occurrenceNotes` + `dailyNotes` (open calendars from their `data.json` — StoreCensus
  already demonstrates the read-every-calendar pattern).
- **Sweep** runs at app idle (and at most once/day): for every index row with zero references,
  if `lastReferencedAt` is older than the **7-day grace period** → delete blob + thumb + index
  row (and the per-calendar sync deletes have long since propagated via the delta branch, which
  reacts to the note edit itself, not to the sweep). Any reference sighting during a sweep
  refreshes `lastReferencedAt`.
- The grace period is what makes "remove the token, then ⌘Z" and "delete on Mac while the
  laptop's note edit is still in flight" safe. Immediate-delete is explicitly rejected.
- Settings ▸ Developer gets an "Attachment store census" row (count, total bytes, orphan count,
  "Sweep now") — same spirit as Log Store Census.

---

## 8. Backup (`.mgc`)

Adopt the web format's existing convention (contract already defined in `src/lib/backup.ts` +
the Prisma `Attachment` model):

- `database.json` `attachment` table rows: `{ id: <sha256>, filename, mime, bytes,
  sha256, storagePath: "<sha256>.<ext>", createdAt }` (the note linkage lives in the note text
  itself — no join rows needed).
- Zip entries `files/<storagePath>` — `Zipper` already round-trips nested paths untouched.
- `manifest.files` = count (finally non-zero).
- Import: restore every `files/*` entry into the CAS (hash-verify), merge index rows. Old
  backups without `files/` import exactly as today.

---

## 9. Libraries (all Apple, no new dependencies)

| Framework | Use |
|---|---|
| **CryptoKit** | SHA-256 (already linked transitively; pure Apple) |
| **UniformTypeIdentifiers** | UTType detection from pasteboard/extension (already used by ICS export) |
| **QuickLookThumbnailing** | `QLThumbnailGenerator` — thumbnails for images/PDFs/anything (macOS 10.15+/iOS 13+; floor is macOS 15) |
| **QuickLookUI** (macOS) | `QLPreviewPanel` + `QLPreviewPanelDataSource` — the space-bar Finder panel |
| **QuickLook** (iOS) | `QLPreviewController` for the phone |
| **AppKit** | pasteboard, drag types, `NSFilePromiseReceiver`, `NSTextAttachment` |

Explicitly rejected: SQLite/CoreData/SwiftData for the index (second storage tech for a
hundreds-scale dict), any markdown library (the custom parser is the renderer), Kingfisher-type
caches (content-addressed thumbs make caching trivial).

---

## 10. Implementation phases

- **P0 — store + import + render (local-only, the 80%)**: `AttachmentStore` (CAS + index +
  import pipeline), editor paste/drag, token grammar in `MarkdownHighlight`, preview
  block-thumbnail + inline chip with async QL thumbnails. *Exit: paste a screenshot and a PDF
  into an event note and a weekly note; thumbnails render; source shows tokens; same file twice
  = one blob.*
- **P1 — the object interactions**: click-select ring, ⌘C file copy, space Quick Look panel,
  double-click open, preview-pane drop, editor ⌘-click preview. *Exit: the Finder loop
  (click → space → arrow through panel) feels native.*
- **P2 — sync**: `NoteFile` records, delta branch, inbound CAS fill, downloading placeholder,
  iPhone render + QuickLook. *Exit: paste on the Mac, thumbnail appears on the phone.*
- **P3 — lifecycle**: reference scan + 7-day sweep, per-calendar sync deletes, Developer census
  row, `.mgc` files round-trip. *Exit: delete the last token, sweep reclaims the bytes, backup
  carries attachments both ways.*

Risks & open questions: CKAsset quota UX (attachments count against the *user's* iCloud —
surface total bytes in Settings ▸ Account); very large drags blocking the main thread (hash on
a background queue, insert token on completion); `NSFilePromiseReceiver` timing (promise
delivery is async — insert a placeholder token? v1: block the drop with a brief progress
spinner instead, simpler); whether the AI assistant should read/attach files (out of scope,
noted for the assistant design doc).
