# Calendar API (`/api/calendar`)

REST API backing the semantic-zoom calendar (`/calendar`). It is the single source of
truth for the user's calendar data and is designed to be driven both by the web UI and by
LLM tools.

## Conventions

- **Auth**: every endpoint requires the NextAuth session cookie. Unauthenticated requests
  get `401 {"error":"unauthorized"}`. All data is scoped to the signed-in user.
- **Content type**: request and response bodies are JSON.
- **Times are floating wall-clock** in the user's *main* timezone (see
  `GET /settings.mainTz`). There is **no timezone offset** in event times — `start`/`end`
  are local wall-clock strings. The alternate timezone is display-only and never changes
  stored data.
  - Timed events: `start`/`end` = `"YYYY-MM-DDTHH:MM:SS"` (seconds optional on input),
    both on the **same day**.
  - All-day "band" events: `start`/`end` = `"YYYY-MM-DD"`, **inclusive**, within a
    **single month**.
  - "deadline" events: a single moment. `start`==`end` = `"YYYY-MM-DDTHH:MM:SS"` in the
    **main tz**. `originTz` (or null) is the tz it was originally given in (e.g. `"AOE"`).
    To create one in its origin tz (the common case for an AI reading a CfP), send
    `originTz` + `originAt` (the wall-clock in that tz) and the server converts it to the
    main-tz `start`. Origin-tz time for display = convert `start` from main tz → `originTz`.
- **Errors**: `{ "error": <code>, "message": <text>, "issues"?: <zod issues> }` with HTTP
  status `400` (bad_request), `401` (unauthorized), `404` (not_found), `409` (conflict),
  `500` (server_error).

## The Event resource

| field       | type                       | notes |
|-------------|----------------------------|-------|
| `id`        | string                     | cuid; may be client-supplied on create |
| `kind`      | `"timed"` \| `"band"`      | timed = hourly single-day; band = all-day multi-day on a lane |
| `title`     | string (1–200)             | |
| `color`     | string                     | palette key (e.g. `default`); defaults to `default` |
| `notes`     | string \| null             | up to 4000 chars |
| `allDay`    | boolean                    | `false` for timed, `true` for band (derived) |
| `start`     | string                     | timed: `YYYY-MM-DDTHH:MM:SS`; band: `YYYY-MM-DD` |
| `end`       | string                     | same format as `start` |
| `track`     | number \| null             | band only: lane index `0–3`; `null` for timed/deadline |
| `originTz`  | string \| null             | deadline only: origin tz id (IANA, or `"AOE"`); `null` = main tz is canonical |
| `tags`      | string[]                   | freeform `#tags` (without the `#`) |
| `repeat`    | object                     | recurrence (see below); `{ "kind": "none" }` when not recurring |
| `createdAt` | string (ISO-8601 UTC)      | |
| `updatedAt` | string (ISO-8601 UTC)      | |

### Recurrence (`repeat`)
`{ "kind": "none" | "daily" | "weekly" | "weekdays" | "yearly", "n"?: 1–4, "until"?: "YYYY-MM-DD"|null, "days"?: number[] }`
- `daily` → every day until `until`.
- `weekly` → every `n` weeks on the event's own weekday, until `until`.
- `weekdays` → every `n` weeks on the weekdays in `days` (0=Sun..6=Sat; the event's own
  weekday is always included), until `until`.
- `yearly` → every year on the event's own month/day, until `until` (set `until` to a date in
  a later year to stop the series).
- omitted/`{kind:"none"}` → single occurrence. (Occurrence expansion on the grid is not
  rendered yet; the config is stored.)

### Validation
- **timed**: `start`/`end` must be date-times on the **same day**, `end > start`,
  `track` omitted/null.
- **band**: `start`/`end` must be dates in the **same month**, `end >= start`, `track` in
  `0–3` required.

## Endpoints

### `GET /api/calendar/events`
List events overlapping a window. Query params (one of):
- `?year=2026` — the whole calendar year, **or**
- `?from=2026-06-01&to=2026-07-01` — half-open `[from, to)` date range.
- optional `&kind=timed|band` filter.

Response `200`: `{ "events": Event[] }` (ordered by `start`). For `?year=`, the result also
includes recurring events whose **base lives in an earlier year** but whose occurrences reach
the requested year (so cross-year recurrence renders); expand their `repeat` to place the
in-year occurrences. (Not applied to the `from/to` range form.)

### `POST /api/calendar/events`
Create an event. Body = Event without the read-only fields; `id` optional (supply your own
or let the server assign one). Examples:

```jsonc
// timed
{ "kind": "timed", "title": "Advising meeting", "color": "rose",
  "start": "2026-06-30T14:00", "end": "2026-06-30T15:30" }

// band (all-day, lane 2, June 10–14 inclusive)
{ "kind": "band", "title": "ICML", "track": 2,
  "start": "2026-06-10", "end": "2026-06-14" }

// deadline specified in its origin tz (AI from a call-for-papers): server stores the
// main-tz start, label shows "<main HH:MM> (AOE 11:59)"
{ "kind": "deadline", "title": "NeurIPS abstract",
  "originTz": "AOE", "originAt": "2026-05-15T11:59" }

// deadline at a plain main-tz time (UI quick-create), no origin tz
{ "kind": "deadline", "title": "Reviews due", "start": "2026-05-20T17:00" }
```
Valid `originTz` values are listed in `DEADLINE_TZS` (AOE, UTC, US zones, CET, China,
Japan, India). Editing a deadline's time: PATCH `start` (main tz) when `originTz` is null,
or PATCH `originAt` when `originTz` is set (the server reconverts).
Response `201`: the created Event. `409` if a supplied `id` already exists.

### `GET /api/calendar/events/:id`
Response `200`: the Event, or `404`.

### `PATCH /api/calendar/events/:id`
Partial update; any subset of `title`, `notes`, `color`, `start`, `end`, `track`. `kind`
is immutable (delete + recreate to change it). The resolved event is re-validated against
its kind. Response `200`: the updated Event.

### `DELETE /api/calendar/events/:id`
Response `204` on success, `404` if not found.

### `GET /api/calendar/settings`
Response `200`: `{ "mainTz": string, "altTz": string|null, "trackNames": { [year: string]: string[12][4] } }`
(defaults if never set). Track-lane names are **per-year**: `trackNames[year][m][lane]` is the
editable name of lane `0–3` in month `m` (`0`=Jan) of that 4-digit `year`. Years absent from the
map have no custom names. `mainTz`/`altTz` are global.

### `PUT /api/calendar/settings`
Partial update of `mainTz` (IANA id), `altTz` (IANA id or `null` to clear), and/or
`trackNames` (the full per-year map `{ year: 12×4 grid }`). Upserts. Response `200`: the
resulting settings.

## Examples (curl)

```sh
# list June-containing events for 2026
curl -s --cookie "$COOKIE" "$BASE/api/calendar/events?year=2026"

# create an all-day band event
curl -s --cookie "$COOKIE" -H 'content-type: application/json' \
  -d '{"kind":"band","title":"Sabbatical","track":3,"start":"2026-07-01","end":"2026-07-31"}' \
  "$BASE/api/calendar/events"

# move/rename a timed event
curl -s -X PATCH --cookie "$COOKIE" -H 'content-type: application/json' \
  -d '{"start":"2026-06-30T16:00","end":"2026-06-30T17:00","title":"Rescheduled"}' \
  "$BASE/api/calendar/events/<id>"

# set the alternate timezone
curl -s -X PUT --cookie "$COOKIE" -H 'content-type: application/json' \
  -d '{"altTz":"Asia/Tokyo"}' "$BASE/api/calendar/settings"
```
