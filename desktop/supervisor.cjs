// Node supervisor for the libirabu desktop app. Run by the Swift menu-bar shell (via the bundled Node).
// It: loads/creates secrets → starts the embedded Postgres + applies migrations → starts the Next.js
// standalone server pointed at that DB → prints "READY <port>" on STDOUT for the shell to read. Human
// logs go to STDERR + a log file; STDOUT carries only the machine protocol (READY / EXIT lines).
//
// Paths resolve for BOTH dev (run from the repo) and the packaged bundle, via env overrides:
//   LIBIRABU_ROOT       app root that holds prisma/migrations + the standalone server (default: repo root)
//   LIBIRABU_HOME       writable data dir (default: ~/Library/Application Support/libirabu)
//   LIBIRABU_SERVER     path to the Next standalone server.js (default: <ROOT>/.next/standalone/server.js)
const fs = require("fs");
const os = require("os");
const net = require("net");
const http = require("http");
const path = require("path");
const { spawn } = require("child_process");
const { startEmbeddedPostgres } = require("./db.cjs");
const { loadOrCreateSecrets } = require("./secrets.cjs");

const ROOT = process.env.LIBIRABU_ROOT || path.resolve(__dirname, "..");
const HOME = process.env.LIBIRABU_HOME || path.join(os.homedir(), "Library", "Application Support", "libirabu");
const SERVER_ENTRY = process.env.LIBIRABU_SERVER || path.join(ROOT, ".next", "standalone", "server.js");
const MIGRATIONS = process.env.LIBIRABU_MIGRATIONS || path.join(ROOT, "prisma", "migrations");

fs.mkdirSync(path.join(HOME, "logs"), { recursive: true });
const logStream = fs.createWriteStream(path.join(HOME, "logs", "supervisor.log"), { flags: "a" });
const log = (m) => { const line = `[${new Date().toISOString()}] ${String(m).trimEnd()}\n`; logStream.write(line); process.stderr.write(line); };
const emit = (line) => process.stdout.write(line + "\n"); // machine protocol for the Swift shell

function freePort(from = 8100) {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.unref();
    srv.once("error", () => resolve(freePort(from + 1)));
    srv.listen(from, "127.0.0.1", () => { const p = srv.address().port; srv.close(() => resolve(p)); });
  });
}

function waitForServer(port, ms = 120_000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const tick = () => http
      .get({ host: "127.0.0.1", port, path: "/" }, (res) => { res.destroy(); resolve(); })
      .on("error", () => (Date.now() > deadline ? reject(new Error("Next server did not become ready")) : setTimeout(tick, 400)));
    tick();
  });
}

let pg = null;
let server = null;
let shuttingDown = false;

async function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  log("shutting down…");
  if (server && !server.killed) { try { server.kill("SIGTERM"); } catch {} }
  if (pg) { try { await pg.stop(); log("postgres stopped"); } catch (e) { log(`pg stop error: ${e}`); } pg = null; }
  logStream.end(() => process.exit(code));
}
process.on("SIGTERM", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));

(async () => {
  try {
    log(`libirabu supervisor starting — ROOT=${ROOT} HOME=${HOME}`);
    const secrets = loadOrCreateSecrets(HOME);
    const { pg: pgHandle, connectionString } = await startEmbeddedPostgres({
      dataDir: path.join(HOME, "pgdata"), migrationsDir: MIGRATIONS, log,
    });
    pg = pgHandle;

    const port = await freePort();
    if (!fs.existsSync(SERVER_ENTRY)) throw new Error(`Next server not found at ${SERVER_ENTRY} — run \`npm run build\` first`);
    const env = {
      ...process.env,
      NODE_ENV: "production",
      HOSTNAME: "127.0.0.1",
      PORT: String(port),
      DATABASE_URL: connectionString,
      NEXTAUTH_SECRET: secrets.NEXTAUTH_SECRET,
      ENCRYPTION_KEY: secrets.ENCRYPTION_KEY,
      NEXTAUTH_URL: `http://localhost:${port}`,
      FILE_STORE_PATH: path.join(HOME, "filestore"),
    };
    log(`starting next server on 127.0.0.1:${port} (${SERVER_ENTRY})`);
    const out = fs.openSync(path.join(HOME, "logs", "server.log"), "a");
    server = spawn(process.execPath, [SERVER_ENTRY], { cwd: path.dirname(SERVER_ENTRY), env, stdio: ["ignore", out, out] });
    server.on("exit", (c) => { log(`next server exited: ${c}`); emit(`EXIT ${c}`); shutdown(c === 0 ? 0 : 1); });

    await waitForServer(port);
    log(`ready on http://127.0.0.1:${port}`);
    emit(`READY ${port}`); // ← the Swift shell reads this and enables "Open"
  } catch (e) {
    log(`FATAL: ${e && e.stack ? e.stack : e}`);
    emit(`ERROR ${e && e.message ? e.message : e}`);
    await shutdown(1);
  }
})();
