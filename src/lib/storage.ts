import { promises as fs } from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { encrypt, decrypt } from "./crypto";

// Local file store for attachments (invoices/receipts/proposal docs). On the home box
// this is an encrypted volume; here it's FILE_STORE_PATH. Sensitive files are AES-GCM
// encrypted at rest. Files are served only through an authenticated route (never static).
// See DESIGN.md §7.

function storeRoot(): string {
  return process.env.FILE_STORE_PATH || path.join(process.cwd(), ".data", "files");
}

export interface StoredFile {
  storagePath: string; // relative path within the store
  sha256: string;
  bytes: number;
  encrypted: boolean;
}

/** Persist bytes to the store. `enc` encrypts at rest. Returns metadata for the DB row. */
export async function saveFile(
  data: Uint8Array,
  opts: { encrypt?: boolean } = {},
): Promise<StoredFile> {
  const root = storeRoot();
  await fs.mkdir(root, { recursive: true });
  const sha256 = crypto.createHash("sha256").update(data).digest("hex");
  const id = crypto.randomUUID();
  const rel = opts.encrypt ? `${id}.enc` : id;
  const buf = opts.encrypt ? Buffer.from(encrypt(Buffer.from(data))) : Buffer.from(data);
  await fs.writeFile(path.join(root, rel), buf);
  return { storagePath: rel, sha256, bytes: data.byteLength, encrypted: Boolean(opts.encrypt) };
}

/** Read bytes back, decrypting if stored encrypted. */
export async function readFile(storagePath: string, encrypted: boolean): Promise<Buffer> {
  const raw = await fs.readFile(path.join(storeRoot(), storagePath));
  return encrypted ? decrypt(raw) : raw;
}

export async function deleteFile(storagePath: string): Promise<void> {
  try {
    await fs.unlink(path.join(storeRoot(), storagePath));
  } catch {
    /* ignore missing file */
  }
}
