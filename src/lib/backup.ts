// Full backup / restore (Connectivity → Export / Import). This is a single-user app, so a backup is
// a complete logical dump of EVERY table (all rows) + the uploaded files + a manifest, packed into a
// .zip. Restore WIPES every table and rebuilds it from the zip inside one transaction — an atomic,
// destructive replace. Logical (Prisma) rather than pg_dump so it's portable across Postgres versions
// and self-contained in the app (no external binaries).

import JSZip from "jszip";
import { prisma } from "./prisma";
import { readRawFile, writeRawFile } from "./storage";

const APP = "libirabu";
const FORMAT = 1; // bump if the on-disk shape changes incompatibly

// All tables in INSERT order (parents before children, satisfying FKs). Wipe uses the reverse.
// Keys are Prisma delegate names (model name, first letter lower-cased).
const TABLES = [
  "user", "verificationToken", "account", "session", "calendarData",
  "track", "person", "project", "paper", "proposal", "fundingSource", "trip", "subscription", "deadline", "apiKey",
  "calEvent", "calendarItem", "calendarConnection", "triageItem", "userApiKey", "calendarPrefs", "dailyNote",
  "task", "expense",
  "eventPerson", "projectPerson", "paperAuthor", "attachment",
  "aIConversation", "aIMessage", "actionLog", "assistantMemory",
] as const;

/** Thrown for user-facing validation problems (mapped to a 400 by the route). */
export class BackupError extends Error {}

// A minimal view of a Prisma model delegate — enough for dump/wipe/restore without `any`.
interface Delegate {
  findMany(args?: unknown): Promise<Record<string, unknown>[]>;
  deleteMany(args?: unknown): Promise<unknown>;
  createMany(args: { data: unknown[]; skipDuplicates?: boolean }): Promise<unknown>;
}
type DelegateMap = Record<string, Delegate>;

// JSON can't hold Date or Bytes, so tag them. Nested Json columns are plain JSON and pass through.
const TAG = "__bk";
function encodeRow(row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(row)) {
    if (v instanceof Date) out[k] = { [TAG]: "date", v: v.toISOString() };
    else if (v instanceof Uint8Array) out[k] = { [TAG]: "bytes", v: Buffer.from(v).toString("base64") };
    else out[k] = v;
  }
  return out;
}
function decodeRow(row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(row)) {
    if (v && typeof v === "object" && TAG in (v as Record<string, unknown>)) {
      const tagged = v as { [TAG]: string; v: string };
      out[k] = tagged[TAG] === "date" ? new Date(tagged.v) : Buffer.from(tagged.v, "base64");
    } else out[k] = v;
  }
  return out;
}

/** Build the export .zip: manifest + full database dump + attachment files. Returns bytes + filename. */
export async function buildExportZip(): Promise<{ filename: string; body: Uint8Array }> {
  const client = prisma as unknown as DelegateMap;
  const db: Record<string, Record<string, unknown>[]> = {};
  const counts: Record<string, number> = {};
  for (const t of TABLES) {
    const rows = await client[t].findMany();
    db[t] = rows.map(encodeRow);
    counts[t] = rows.length;
  }

  const zip = new JSZip();
  zip.file("database.json", JSON.stringify(db));

  // Uploaded files: back up each attachment's raw bytes verbatim (encryption state preserved).
  const attachments = await prisma.attachment.findMany({ select: { storagePath: true } });
  let fileCount = 0;
  for (const a of attachments) {
    const buf = await readRawFile(a.storagePath);
    if (buf) { zip.file(`files/${a.storagePath}`, buf); fileCount++; }
  }

  const user = await prisma.user.findFirst({ select: { email: true, name: true } });
  const username = (user?.name || user?.email || "user").split("@")[0];
  const now = new Date();
  zip.file("manifest.json", JSON.stringify({ app: APP, format: FORMAT, exportedAt: now.toISOString(), username, counts, files: fileCount }, null, 2));

  const body = await zip.generateAsync({ type: "uint8array", compression: "DEFLATE" });
  const slug = username.replace(/[^a-zA-Z0-9._-]/g, "") || "user";
  return { filename: `${APP}-${slug}-${now.toISOString().slice(0, 10)}.zip`, body };
}

export interface ImportSummary { restored: number; files: number; exportedAt: string | null }

/** Restore from an export .zip: validate → WIPE every table → recreate, atomically. Then restore files. */
export async function restoreFromZip(data: Uint8Array): Promise<ImportSummary> {
  let zip: JSZip;
  try { zip = await JSZip.loadAsync(data); }
  catch { throw new BackupError("That file isn't a valid .zip."); }

  const manifestFile = zip.file("manifest.json");
  const dbFile = zip.file("database.json");
  if (!manifestFile || !dbFile) throw new BackupError("Not a libirabu backup (missing manifest/database).");
  const manifest = JSON.parse(await manifestFile.async("string")) as { app?: string; exportedAt?: string };
  if (manifest.app !== APP) throw new BackupError("This .zip is not a libirabu backup.");
  const db = JSON.parse(await dbFile.async("string")) as Record<string, Record<string, unknown>[]>;

  let restored = 0;
  await prisma.$transaction(async (tx) => {
    const client = tx as unknown as DelegateMap;
    for (const t of [...TABLES].reverse()) await client[t].deleteMany({}); // children → parents
    for (const t of TABLES) {                                              // parents → children
      const rows = (db[t] ?? []).map(decodeRow);
      if (rows.length) { await client[t].createMany({ data: rows, skipDuplicates: true }); restored += rows.length; }
    }
  }, { timeout: 120_000, maxWait: 15_000 });

  // Files live outside the DB transaction — write them after the DB commits.
  let files = 0;
  for (const name of Object.keys(zip.files)) {
    const entry = zip.files[name];
    if (entry.dir || !name.startsWith("files/")) continue;
    await writeRawFile(name.slice("files/".length), await entry.async("uint8array"));
    files++;
  }
  return { restored, files, exportedAt: manifest.exportedAt ?? null };
}
