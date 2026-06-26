# Research OS — Design Plan

A single-user, AI-assisted dashboard for running a research group: calendar,
projects, people, papers, proposals, API keys, and funding — surfaced on desktop,
a big office screen, mobile, and a Mac app.

> Built on the proven stack from `../yearly-tracker` (GridCal): **Next.js 16
> (App Router) + Prisma 7 + Postgres + Electron**. We lift the year-grid calendar
> UI directly and build the relational system around it.

---

## 0. Locked decisions

| Area | Decision | Consequence |
|---|---|---|
| **Hosting** | **Self-hosted on an always-on home box + ZeroTier** | Long-running Next.js server (Docker) on a home machine you own, reached privately via the ZeroTier mesh — never public-facing, no vendor cloud. **$0.** Removes all serverless limits (no function timeouts, in-process cron, local DB). Trade-off: you own uptime + backups (a second home box covers both). Data on your hardware → still encrypt sensitive cols + metadata-only API keys (§7). |
| **LLM** | **JHU gateway** (`gateway.engineering.jhu.edu`), behind a provider adapter | Institutional data governance; sensitive PDFs (invoices, student docs) never go to a third party. Swap to Bedrock/Anthropic by changing one module. |
| **Access** | **Single-user** (you) | One login, no per-row permissions. TV display + mobile are surfaces over the same single account. Multi-user can come later without a rewrite (every row already has `userId`). |

---

## 1. System architecture

```
  ┌─ ZeroTier mesh (private, encrypted; NAT-traversed, no public IP) ──┐
  │  Laptop   Phone(PWA)   Electron   Office-TV box   ◄── all enrolled │
  └─────────────────────────────┬─────────────────────────────────────┘
                                 │  https://<zerotier-name-or-IP>
                                 ▼
        ┌──────────────────────────────────────────────────────────┐
        │   Always-on HOME box (Docker Compose)                      │
        │   ┌──────────┐   Caddy/nginx (TLS) ──► Next.js (next start)│
        │   │ ZeroTier │        │                  ├─ Server Comps   │
        │   │  client  │        │                  ├─ Server Actions │
        │   └──────────┘        ▼                  ├─ Route Handlers │
        │                  Postgres (Docker)        └─ node-cron      │
        │                  Local encrypted file store                │
        └───────────────────────────┬──────────────────────────────-┘
                                     │ server-side only
                                     ▼
                          JHU gateway (gateway.engineering.jhu.edu,
                          OpenAI-compatible)  ◄─ verify reachability
                          from home (API key? VPN-gated?) — see §8
        Backup: nightly pg_dump + file snapshot ──► a 2nd home box + off-site
                                                    encrypted copy
```

**Principles**
- **Server Components for reads, Server Actions for writes**, `zod`-validated. Route
  Handlers only where you need a raw HTTP endpoint (AI stream, file download, ICS).
- **No secret ever reaches the client.** Gateway key, encryption key, DB URL live in
  a root-only `.env` on the home box. API-key *values* and sensitive notes are
  AES-256-GCM encrypted at rest (data is on your hardware, but encryption + the
  private network are belt-and-suspenders).
- **Long-running server = no limits.** In-process `node-cron` (reminders at any
  cadence), streaming AI, and heavy PDF/OCR all run without function timeouts.
- **Private by construction.** The app is never exposed to the public internet; only
  ZeroTier-enrolled devices can reach it. The network *is* the outer auth layer; app
  login is the inner layer.
- **Adapters at the edges** so the volatile bits stay swappable: `llm/` (gateway ↔
  Bedrock ↔ Anthropic), `storage/` (local FS ↔ S3 ↔ Blob), `auth/` (credentials ↔
  JHU SSO later). Lets you relocate to a dept VM / cloud later without touching features.

---

## 2. Tech stack

| Layer | Choice | Why |
|---|---|---|
| Framework | Next.js 16 App Router | Same as GridCal; reuse calendar UI |
| Language | TypeScript | — |
| DB | Postgres in Docker (local) | Relational; runs on the home box. (SQLite is a simpler single-file-backup alternative if you prefer) |
| ORM | Prisma 7 (driver adapter) | Already used; migrations, type-safety |
| Auth | next-auth (credentials) | Single user; behind JHU VPN. SSO later via adapter |
| Styling | Tailwind v4 | Same as GridCal |
| Validation | `zod` | Every action + AI tool call |
| Recurrence | `rrule` | 1:1s, lectures, office hours, rehearsals |
| PDF | `pdf-parse` / `pdfjs-dist` | Extract text from invoices/receipts for AI |
| Files | Local encrypted disk | Attachments/receipts on the home box; sensitive files AES-GCM encrypted, served via authed route |
| Proxy/TLS | Caddy (recommended) | Auto-HTTPS: real Let's Encrypt cert via DNS-01 if you own a domain, else internal CA / mkcert |
| VPN | ZeroTier | Private mesh; all devices enrolled once, reach the box by stable address |
| LLM | JHU gateway via OpenAI-compatible client | Locked |
| Voice | Web Speech API | "Siri-like" panel input |
| Desktop | Electron (remote-URL shell) | Same approach as GridCal |
| Mobile | PWA (manifest + service worker) | Installable, quick actions |
| Crypto | Node `crypto` AES-256-GCM | Encrypt API keys + sensitive notes |

---

## 3. Database schema

Designed around your emphasis on **connections**. Every entity is reachable from
the calendar (deadlines→events), from tasks (todo on anything), and from people.

### 3.1 Entity map

```
                              ┌────────┐
                ┌─────────────│ Person │─────────────┐
                │ author      └───┬────┘  advisor(self)│
                │             collaborator              │
            ┌───┴────┐   ┌────────┴────────┐      ┌────┴─────┐
            │ Paper  │   │     Project     │      │ ApiKey   │ issuedTo
            └───┬────┘   └──┬───┬───┬───┬──┘      └────┬─────┘
       authors  │           │   │   │   │              │ provider="OpenAI"…
                │     tasks │   │   │   │ milestones    │
            ┌───┴────┐  ┌───┴─┐ │   │ ┌─┴──────────┐   │
            │Proposal│  │Task │ │   │ │ CalEvent   │◄──┘ (renewal/rotation)
            └───┬────┘  └─────┘ │   │ └────┬───────┘
        awarded │               │   │      │ on Track (year-view lane)
            ┌───┴─────────┐     │   │   ┌──┴───────┐
            │FundingSource│◄────┘   │   │  Track   │  RESEARCH|TEACHING|
            └───┬─────────┘         │   └──────────┘  SERVICE|REVIEWING|
        ┌───────┼──────────┐        │                 COURSES|TRAVEL|…
   ┌────┴───┐ ┌─┴────────┐ ┌┴──────┐│
   │Expense │ │Subscript.│ │ Trip  ││ traveler=Person
   └───┬────┘ └──────────┘ └───────┘│
       │ receipts                    │
   ┌───┴──────┐                      │
   │Attachment│──────────────────────┘ (also on Proposal, Paper, FundingSource)
   └──────────┘

   AIConversation → AIMessage      ActionLog (audit: every AI write)
```

### 3.2 Prisma models (abbreviated)

```prisma
// ── Identity (kept from GridCal) ────────────────────────────────
model User { id String @id @default(cuid()) email String @unique
  name String? password String  /* + accounts, sessions */ }

// ── Calendar / time ─────────────────────────────────────────────
model Track {            // the year-view "lanes" you draw bars on
  id String @id @default(cuid()) userId String
  key   String           // RESEARCH|TEACHING|SERVICE|REVIEWING|COURSES|TRAVEL|PERSONAL
  name  String  color String  order Int
  events CalEvent[]
}

model CalEvent {
  id String @id @default(cuid()) userId String
  trackId String?  track Track? @relation(fields:[trackId],references:[id])
  title String  notes String?
  start DateTime  end DateTime  allDay Boolean @default(true)
  type  String    // DEADLINE|MEETING|CLASS|TRAVEL|CONFERENCE|REVIEW|FOCUS|OTHER
  color String?  recurrence String?           // RRULE
  // connections — a deadline knows what it's for:
  projectId String? paperId String? proposalId String? apiKeyId String?
  tripId String? fundingSourceId String?
  attendees EventPerson[]
}

// ── Work ────────────────────────────────────────────────────────
model Project {
  id String @id @default(cuid()) userId String
  trackId String?  parentId String?           // sub-projects
  title String  description String?
  status String   // IDEA|ACTIVE|PAUSED|DONE|DROPPED
  priority Int    startDate DateTime? targetDate DateTime?
  people ProjectPerson[]  tasks Task[]  papers Paper[] proposals Proposal[]
}

model Task {
  id String @id @default(cuid()) userId String
  title String  notes String?
  status String   // TODO|DOING|DONE|BLOCKED
  priority Int  dueAt DateTime? scheduledAt DateTime?
  // a todo can hang off ANY object:
  projectId String? paperId String? proposalId String? personId String?
  fundingSourceId String? apiKeyId String? eventId String?
}

// ── People ──────────────────────────────────────────────────────
model Person {
  id String @id @default(cuid()) userId String
  name String  email String?
  role String   // STUDENT|COLLABORATOR|COAUTHOR|FACULTY|COMMITTEE|ADVISOR|OTHER
  affiliation String?                          // other school, dept
  advisorId String?  advisor Person? @relation("advises", fields:[advisorId],references:[id])
  advisees  Person[] @relation("advises")
  notesEnc  Bytes?                             // AES-GCM encrypted
  projects ProjectPerson[] authored PaperAuthor[]
}
model ProjectPerson { projectId String  personId String  role String  @@id([projectId,personId]) }
model EventPerson   { eventId String  personId String  role String  @@id([eventId,personId]) }

// ── Papers ──────────────────────────────────────────────────────
model Paper {
  id String @id @default(cuid()) userId String  projectId String?
  title String  venue String?  year Int?
  status String   // IN_PREP|SUBMITTED|UNDER_REVIEW|MAJOR_REV|ACCEPTED|PUBLISHED|REJECTED
  overleafUrl String?  githubUrl String?  arxivUrl String?  doi String?
  abstract String?  authors PaperAuthor[]  attachments Attachment[]
}
model PaperAuthor { paperId String  personId String  order Int  isCorresponding Boolean @default(false)  @@id([paperId,personId]) }

// ── Conference / submission deadlines (the /deadlines board) ─────
model Deadline {
  id String @id @default(cuid()) userId String
  venue String                                 // "NeurIPS 2026", "TOPLAS"
  kind  String   // CONF_ABSTRACT|CONF_FULL|JOURNAL|REVIEW|REBUTTAL|CAMERA_READY
  dueAt DateTime                               // ranked ascending by (dueAt - now)
  timezone String?  url String?                // CFP link
  trackId String?                              // filter by research area/lane
  watched Boolean @default(true)               // show on the board
  paperId String?                              // the paper we're targeting at it
  eventId String?                              // mirrored onto the calendar
  notes String?
  // seedable from aideadlin.es / WikiCFP, or added manually / by the AI
}

// ── Proposals / grants ──────────────────────────────────────────
model Proposal {
  id String @id @default(cuid()) userId String  projectId String?
  title String  agency String?  program String?
  role   String?  // PI|CO_PI|SENIOR_PERSONNEL
  status String   // DRAFTING|SUBMITTED|UNDER_REVIEW|AWARDED|DECLINED
  amount Decimal? submittedAt DateTime? periodStart DateTime? periodEnd DateTime?
  funding FundingSource?  attachments Attachment[]
}

// ── API keys (sensitive) ────────────────────────────────────────
model ApiKey {
  id String @id @default(cuid()) userId String
  label String                                 // "OpenAI prod", "AWS lab"
  provider String                              // FROM WHERE: OpenAI|AWS|Anthropic|…
  valueEnc Bytes?                              // encrypted secret (optional, see §7)
  last4 String?                                // for identification w/o decrypt
  purpose String?  environment String?         // dev|prod
  status String    // ACTIVE|REVOKED|EXPIRED
  issuedToPersonId String?                     // GIVEN TO WHOM (a Person) …
  issuedToLabel String?                        // … or free text (a service/CI)
  projectId String?  fundingSourceId String?   // billed against
  issuedAt DateTime? expiresAt DateTime? lastRotatedAt DateTime?
  notesEnc Bytes?
}

// ── Funding ─────────────────────────────────────────────────────
model FundingSource {                          // a grant / gift / discretionary pool
  id String @id @default(cuid()) userId String  proposalId String? @unique
  name String  agency String?  awardNumber String?
  amount Decimal?  startDate DateTime? endDate DateTime?
  expenses Expense[] subscriptions Subscription[] trips Trip[] attachments Attachment[]
}
model Expense {
  id String @id @default(cuid()) userId String  fundingSourceId String?
  description String  amount Decimal  category String  date DateTime
  personId String?                             // who incurred / traveled
  tripId String?  status String                // PLANNED|SUBMITTED|REIMBURSED
  attachments Attachment[]                      // receipts / invoices
}
model Subscription {
  id String @id @default(cuid()) userId String  fundingSourceId String?  apiKeyId String?
  name String  vendor String  cost Decimal  cycle String  // MONTHLY|ANNUAL
  renewalDate DateTime?  status String          // ACTIVE|CANCELLED
}
model Trip {
  id String @id @default(cuid()) userId String  fundingSourceId String? projectId String?
  title String  destination String  purpose String  // CONFERENCE|VISIT|FIELDWORK
  travelerPersonId String?                      // student travel vs. your travel
  start DateTime  end DateTime  estCost Decimal? actualCost Decimal?
  expenses Expense[]  events CalEvent[]
}

// ── Files ───────────────────────────────────────────────────────
model Attachment {
  id String @id @default(cuid()) userId String
  filename String  mime String  bytes Int  sha256 String
  storagePath String                           // path on encrypted volume
  // polymorphic-ish: explicit nullable FKs keep Prisma joins clean
  expenseId String? proposalId String? paperId String? fundingSourceId String?
  createdAt DateTime @default(now())
}

// ── AI + audit ──────────────────────────────────────────────────
model AIConversation { id String @id @default(cuid()) userId String  title String?  createdAt DateTime @default(now()) }
model AIMessage { id String @id @default(cuid()) conversationId String  role String  content Json  toolCalls Json?  createdAt DateTime @default(now()) }
model ActionLog {                              // every AI-initiated write, for confirm/undo
  id String @id @default(cuid()) userId String
  actor String   // USER|AI
  kind String    // create_task|update_project_status|create_expense|…
  payload Json    status String                // PROPOSED|CONFIRMED|APPLIED|REVERTED
  createdAt DateTime @default(now())
}
```

This satisfies every connection you named: project↔people, project↔papers/proposals,
papers↔co-authors, funding↔travel↔students, API-key↔provider("from where")↔person
("to whom"), and **todos that attach to anything**, all surfacing on the calendar.

---

## 4. Pages / UI

| Route | View | Notes |
|---|---|---|
| `/` | **Year grid (GridCal)** | Landing. Tracks = lanes (courses, teaching, service, reviewing, research…). Paint bars; deadlines from papers/proposals/funding auto-appear. |
| `/week` | Week timeline | Real clock times, meetings, focus blocks |
| `/day` | Day timeline | Hour-by-hour |
| `/projects` `/projects/[id]` | Board + detail | Tasks (kanban), linked people/papers/proposals |
| `/people` `/people/[id]` | Directory + profile | Role, affiliation, advisor↔advisee graph, linked work |
| `/papers` | Table | Overleaf / GitHub / arXiv / DOI links, status, authors |
| `/deadlines` | **Countdown board** | Conference/journal/review **submission deadlines ranked by days remaining** (nearest first), with live countdowns, track filter, "watched" venues. Each can spawn a target `Paper` + a calendar `CalEvent`. See `Deadline` model (§3.2). |
| `/proposals` | Table | Agency, status, amount, → funding when awarded |
| `/keys` | API-key registry | Provider, last-4, **issued-to**, expiry, rotation alerts |
| `/funding` | Grants + ledger | Sources, expenses, subscriptions, trips, reimbursement status |
| `/funding/travel` | Travel | Your trips + student trips, cost vs. budget |
| `/tasks` | Global todo | Filter by project/person/due |
| `/display` | **TV kiosk** | Read-only, sanitized, auto-refresh, device-token (no login) |
| `/m/*` | Mobile quick actions | Add task/event/expense, today view, AI panel |

**AI floating panel** — present on every page; click → Siri-like overlay with voice
(Web Speech API) + text + drag-drop file upload. See §6.

---

## 5. Surfaces

- **Desktop web** — full app, the primary editing surface.
- **Office TV** (`/display`) — full-screen, auto-refreshing (SSE or poll), **device
  token** auth (a long-lived token in the URL/cookie, no interactive login),
  **sanitized**: shows group deadlines, travel, teaching at a glance — never
  `Person.notesEnc`, never API-key values, never expense detail.
- **Mobile PWA** — installable; quick actions only (add task, add deadline, log an
  expense w/ photo, "what's today", AI panel). Reuses the same Server Actions.
- **Electron (Mac)** — remote-URL shell (like GridCal) pointing at the JHU host;
  add menubar presence, global hotkey to summon the AI panel, native notifications,
  deep links. Bundling the full app locally is a later option.

---

## 6. AI assistant (agentic, confirmation-gated)

**Flow:** floating panel → message (+optional PDF/image) → server route → JHU gateway
in an OpenAI-style **tool-use loop** → tools map to Server Actions → **writes return a
*proposal*** the UI shows for one-tap confirm → on confirm, applied + recorded in
`ActionLog` (enables undo). Responses stream.

**Tools (each `zod`-validated):** `query_schedule`, `create_task`, `update_task`,
`create_event`, `move_event`, `create_person`, `create_project`,
`update_project_status`, `create_paper`, `create_proposal`, `create_expense`,
`register_api_key`, `generate_briefing`.

**Attachments / PDFs (invoices, reimbursements):** server-side extract text with
`pdf-parse`/`pdfjs` → feed to the model → it proposes a structured `create_expense`
(vendor, amount, date, category, funding source) with the file stored as an encrypted
`Attachment` on Vercel Blob. If the gateway exposes native vision/PDF input, use it;
otherwise the text-extraction path is the fallback. **The text/image sent for analysis
goes to the JHU gateway — institutional inference, not a third-party LLM** (the stored
file itself sits encrypted on Vercel Blob, off-campus — see §7).
- *No timeout constraint here:* on the long-running home server, even scanned-doc OCR
  and long multi-step tool loops run inline — no function limits to design around.

**Provider adapter** (`src/lib/llm/`): a thin `LLMProvider` interface
(`chat`, `streamChat`, `withTools`) with a `JhuGatewayProvider` (OpenAI-compatible).
Swapping to Bedrock/Anthropic = new file, same interface. *Verify with JHU: (a)
gateway base URL + auth header, (b) which models, (c) function-calling/tool-use
support, (d) vision/PDF support.*

**Guardrail:** consequential writes (anything touching money, people, external
attendees, or deletes) **always** require confirmation; trivial private creates
(a personal task) can be set to auto-apply. Configurable.

---

## 7. Security (heightened — you store keys you've handed out)

- **Private-by-construction:** the app is never on the public internet — only
  ZeroTier-enrolled devices can reach it. That alone removes the entire
  remote-attacker surface. Data lives on **your own hardware**, not a vendor cloud.
- **Network = outer auth.** Only devices you've authorized into the ZeroTier network
  can connect; app login (next-auth, single account, long random password) is the
  inner layer. Authorize each device explicitly in the ZeroTier admin.
- **TLS** via **Caddy** — real Let's Encrypt cert (DNS-01) if you own a domain, else
  Caddy's internal CA / mkcert with the CA trusted on each device. Needed so the
  **PWA is installable** (secure-context requirement) and Electron/mobile get clean TLS.
- **Encryption at rest (AES-256-GCM)** for: `ApiKey.valueEnc`, `Person.notesEnc`,
  any sensitive `notes`, and sensitive files. Key in a **root-only `.env`** on the
  home box (not in the repo or DB). Since both the key and data sit on hardware you
  physically control, this is a strong story — just keep the box patched and the disk
  encrypted (FileVault / LUKS).
- **JHU data note:** Restricted data on personal home hardware is a gray area
  institutionally; disk encryption + the private network + metadata-only API keys keep
  it defensible for a single-user tool. If you ever need it strictly on-campus, the
  §1 adapters let you relocate the box to a dept VM unchanged.
- **API-key storage decision (recommended):** prefer **metadata-only** —
  `provider`, `last4`, `issuedTo`, `expiresAt`, `purpose` — and *not* the full
  secret, unless you genuinely need to retrieve it. If you do store the secret,
  encrypt it and gate reveal behind a re-auth + log every reveal in `ActionLog`.
  Storing live secrets to third-party services is the single biggest risk here.
- **File access**: attachments on local disk, served only through an authenticated
  Route Handler (never a static path); the most sensitive files (invoices, proposal
  docs) are AES-GCM encrypted on disk.
- **TV/data boundary**: `/display` queries a sanitized projection — enforced in
  code, not just UI hiding.
- **Audit**: `ActionLog` records every AI write and every secret reveal.
- **Backups (you own these now)**: nightly `pg_dump` + file-store snapshot, pushed to
  **a second home box** *and* an **off-site encrypted copy** (encrypt the dump, then it's
  safe to park even in a free cloud bucket). Test a restore periodically. With several
  home machines, also consider one as a warm standby.

---

## 8. Deployment — home box + ZeroTier ($0)

### 8.1 One-time setup on the home box
1. **OS prep**: enable full-disk encryption (FileVault/LUKS); install Docker +
   Docker Compose; install the **ZeroTier** client and join your network; authorize
   the box in the ZeroTier admin (note its stable ZeroTier IP).
2. **Compose stack**: `app` (Next.js `next start`, built with `output: 'standalone'`)
   + `postgres` + `caddy`. Volumes for Postgres data and the encrypted file store.
3. **TLS / hostname**:
   - *Have a domain?* Point `dash.yourdomain.com` → the ZeroTier IP and let **Caddy
     get a real Let's Encrypt cert via DNS-01** (works even though the IP is private).
     Cleanest — trusted HTTPS everywhere, PWA installs with no per-device fuss.
   - *No domain?* Use Caddy's internal CA (or `mkcert`) and install the local CA cert
     on each device once.
4. **Env** (root-only `.env` on the box): `DATABASE_URL` (local Postgres),
   `NEXTAUTH_URL` (the ZeroTier hostname), `NEXTAUTH_SECRET`, `ENCRYPTION_KEY`
   (32-byte base64), `FILE_STORE_PATH`, `JHU_GATEWAY_URL`, `JHU_GATEWAY_KEY`.
5. **Migrate & run**: `prisma migrate deploy` then `docker compose up -d`. Set the
   stack to restart on boot so it survives reboots/power blips.
6. **Enroll devices**: install ZeroTier on laptop, phone, Electron host, and the
   office-TV box; authorize each; they reach the app at the hostname from step 3.

### 8.2 Operational must-dos
- **⚠️ Verify JHU-gateway reachability from home first.** The home box must be able to
  call `gateway.engineering.jhu.edu`. If the gateway is campus/VPN-gated, run the
  **JHU VPN client on the box** (or route only gateway traffic through it). *Confirm
  this before building the AI layer — it's the one external dependency.*
- **Cron**: in-process `node-cron` for deadline reminders, renewal/rotation alerts,
  the digest, and the nightly backup — any cadence you want.
- **Backups**: nightly `pg_dump` + file snapshot → a **second home box** + an
  **encrypted off-site copy** (see §7). Test a restore.
- **Updates**: keep Docker images + the OS patched; it's your responsibility now.
- **Office TV**: a cheap Pi/mini-PC at the TV runs ZeroTier + a kiosk browser pointed
  at `/display`. Works as long as the home box + its internet are up.

### 8.3 Cost — **$0**
Hardware you already own + ZeroTier (free, ≤25 devices) + open-source stack. LLM is
billed to JHU via the gateway. Only optional spend: ~$10/yr for a domain (nicer TLS),
and electricity for the always-on box. No vendor cloud, no tiers, no limits.

---

### 8.4 Reference: alternatives (if you ever move off the home box)
- **Dept VM** (on-campus, always-on): same Compose stack; keeps data at JHU. Caveats
  per §8.5 — "not for production," you sponsor + manage it.
- **Vercel + Neon** (managed, $0 Hobby / $20 Pro): zero-ops but data goes to US cloud
  and serverless timeouts return; the §1 adapters make this a config change, not a rewrite.
- **Oracle Cloud "Always Free" VM**: a free-forever real server if you want it off-prem.

### 8.5 Reference: the on-campus path (if data-residency rules ever require it)
You chose Vercel+Neon, but I read the CS IT policy in case you need to move Restricted
data on-campus later. Summary so it's on record:
- **Shared CS webserver** (`lab.cs.jhu.edu`, faculty-only) is **static-only** and
  public-facing → unsuitable (can't run Node; can't hold Restricted data).
- **CS VM** can run Node+Postgres but is officially **"not for production,"** needs a
  faculty sponsor (you), and you'd own backups/patching/firewall. Dept managed DB is
  **MySQL**, not Postgres.
- JHU data classes: **Restricted** (student/financial/credentials) vs Unrestricted.
- **Migration path** if needed: the §1 adapters let you keep the **app on Vercel** but
  move **DB + Blob → a CS VM behind the JHU VPN** (the hybrid), so Restricted data
  returns on-campus with minimal code change.

**Sources:** [Lab & Other Website Hosting](https://support.cs.jhu.edu/wiki/Lab_And_Other_Website_Hosting) ·
[Virtual Machines (VMs)](https://support.cs.jhu.edu/wiki/Category:Virtual_Machines_(VMs)) ·
[Services Provided By CS IT](https://support.cs.jhu.edu/wiki/Services_Provided_By_CS_IT) ·
[JHU IT Acceptable Use & Data Classification](https://it.johnshopkins.edu/wp-content/uploads/2021/07/Johns_Hopkins_Information_Technology_Policies.pdf)

---

## 9. Phased roadmap

| Phase | Scope | Outcome |
|---|---|---|
| **0 — Foundation** | Home box: Docker Compose (app + Postgres + Caddy) + ZeroTier + TLS; scaffold repo from GridCal; Prisma schema (§3); auth; encryption helper; LLM adapter stub; **verify gateway reachability from home** | Private skeleton reachable from all your devices |
| **1 — Calendar** | Year grid (lift GridCal) + week + day; Tracks; CalEvent; deadlines auto-surface | The landing page works |
| **2 — Work & people** | Projects + Tasks (kanban) + People + relations (advisor↔advisee, project↔people) | Core relational system |
| **3 — Research records** | Papers (overleaf/github/arxiv) + Proposals + API-key registry | Your research admin in one place |
| **4 — Funding** | FundingSource + Expense + Subscription + Trip + Attachments + document storage | Money & travel tracked |
| **5 — AI assistant** | Floating panel, agentic tool-use, PDF/invoice analysis, confirmation + ActionLog | "Siri for your lab" |
| **6 — Surfaces** | TV `/display`, mobile PWA quick actions, Electron packaging, notifications | Everywhere |

Each phase ships usable on its own.

---

## 10. Things worth deciding (beyond what you listed)

- **API-key secrets:** store full encrypted values, or metadata-only? (Recommend
  metadata-only + reveal-gated — see §7.)
- **Imports:** auto-pull papers from arXiv/DBLP/Google Scholar + BibTeX import?
  ICS import for calendars? (Big time-savers, easy to add in Phase 3/1.)
- **Notifications channel:** email via JHU SMTP, web push, native (Electron), or all?
- **Reimbursement export:** JHU uses specific expense systems (e.g. Concur/SAP) —
  do you want CSV/PDF export shaped for those, rather than submitting from here?
- **Auth upgrade:** start with credentials; move to **JHU SSO (Shibboleth/SAML)**
  later? (Adapter leaves room.)
- **Legacy GridCal data:** import your existing year-blob, or start clean?
- **Voice scope:** is Web Speech API ("push to talk" in the panel) enough, or do
  you want always-listening wake-word? (Recommend push-to-talk.)
```
