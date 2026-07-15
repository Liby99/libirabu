// Per-install secrets for the desktop app. Generated once on first launch and persisted in the app's
// data dir, so each recipient gets unique keys and — crucially — ENCRYPTION_KEY stays STABLE across
// restarts (it decrypts their stored API keys / notes; a changing key would orphan that data).
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

function loadOrCreateSecrets(dataDir) {
  const file = path.join(dataDir, "secrets.json");
  if (fs.existsSync(file)) {
    try {
      const s = JSON.parse(fs.readFileSync(file, "utf8"));
      if (s.NEXTAUTH_SECRET && s.ENCRYPTION_KEY) return s;
    } catch { /* fall through to regenerate */ }
  }
  const secrets = {
    NEXTAUTH_SECRET: crypto.randomBytes(32).toString("base64"),
    ENCRYPTION_KEY: crypto.randomBytes(32).toString("base64"), // 32 bytes, base64 — matches src/lib/crypto.ts
  };
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(file, JSON.stringify(secrets, null, 2), { mode: 0o600 });
  return secrets;
}

module.exports = { loadOrCreateSecrets };
