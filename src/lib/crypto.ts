import crypto from "node:crypto";

// AES-256-GCM for sensitive columns (ApiKey.valueEnc, Person.notesEnc, …) and
// sensitive files. The key comes from ENCRYPTION_KEY (32 bytes, base64) and lives
// only on the server (root-only .env on the home box). See DESIGN.md §7.
//
// Wire format (stored in a `Bytes` column): [12-byte IV][16-byte auth tag][ciphertext].

const ALGO = "aes-256-gcm";
const IV_LEN = 12;
const TAG_LEN = 16;

function getKey(): Buffer {
  const raw = process.env.ENCRYPTION_KEY;
  if (!raw) throw new Error("ENCRYPTION_KEY is not set");
  const key = Buffer.from(raw, "base64");
  if (key.length !== 32) {
    throw new Error(
      `ENCRYPTION_KEY must decode to 32 bytes (got ${key.length}). Generate one with: openssl rand -base64 32`,
    );
  }
  return key;
}

/** Encrypt a UTF-8 string (or Buffer) → packed bytes suitable for a Prisma Bytes column. */
export function encrypt(plain: string | Buffer): Uint8Array<ArrayBuffer> {
  const key = getKey();
  const iv = crypto.randomBytes(IV_LEN);
  const cipher = crypto.createCipheriv(ALGO, key, iv);
  const data = typeof plain === "string" ? Buffer.from(plain, "utf8") : plain;
  const ciphertext = Buffer.concat([cipher.update(data), cipher.final()]);
  const tag = cipher.getAuthTag();
  // Return a fresh ArrayBuffer-backed Uint8Array — Prisma Bytes expects this, not Buffer.
  const packed = Buffer.concat([iv, tag, ciphertext]);
  const out = new Uint8Array(packed.byteLength);
  out.set(packed);
  return out;
}

/** Decrypt a packed Buffer (from encrypt) → Buffer. */
export function decrypt(packed: Buffer): Buffer {
  const key = getKey();
  const iv = packed.subarray(0, IV_LEN);
  const tag = packed.subarray(IV_LEN, IV_LEN + TAG_LEN);
  const ciphertext = packed.subarray(IV_LEN + TAG_LEN);
  const decipher = crypto.createDecipheriv(ALGO, key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

/** Convenience: decrypt to a UTF-8 string. */
export function decryptToString(packed: Buffer): string {
  return decrypt(packed).toString("utf8");
}

/** Mask a secret for display, keeping the last 4 chars (e.g. "sk-…a1b2"). */
export function last4(secret: string): string {
  return secret.slice(-4);
}
