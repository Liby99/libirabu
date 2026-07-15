// Embedded Postgres for the packaged desktop app. Starts a private Postgres cluster in the app's data
// dir (no Docker, no system Postgres), applies the Prisma migration SQL directly (Prisma 7's runtime
// client is engine-free, so we never bundle the migration engine), and returns a DATABASE_URL. The
// supervisor drives the lifecycle (start / stop).
const EmbeddedPostgres = require("embedded-postgres").default;
const fs = require("fs");
const net = require("net");
const path = require("path");

const USER = "libirabu";
const PASSWORD = "libirabu";
const DB = "libirabu";

// A free localhost TCP port at/after `from` — so a second launch (or a stray process) can't clash.
function freePort(from = 54329) {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.unref();
    srv.once("error", () => resolve(freePort(from + 1)));
    srv.listen(from, "127.0.0.1", () => { const p = srv.address().port; srv.close(() => resolve(p)); });
  });
}

// Apply every prisma/migrations/<ts>/migration.sql not yet recorded, in lexical order, each in its own
// transaction. Replaces `prisma migrate deploy`; tracks applied names in _libirabu_migrations.
async function runMigrations(client, migrationsDir, log) {
  await client.query(`CREATE TABLE IF NOT EXISTS _libirabu_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  const done = new Set((await client.query(`SELECT name FROM _libirabu_migrations`)).rows.map((r) => r.name));
  const names = fs.readdirSync(migrationsDir).filter((d) => fs.existsSync(path.join(migrationsDir, d, "migration.sql"))).sort();
  let applied = 0;
  for (const name of names) {
    if (done.has(name)) continue;
    const sql = fs.readFileSync(path.join(migrationsDir, name, "migration.sql"), "utf8");
    await client.query("BEGIN");
    try {
      await client.query(sql);
      await client.query(`INSERT INTO _libirabu_migrations (name) VALUES ($1)`, [name]);
      await client.query("COMMIT");
      applied++;
      log(`migration applied: ${name}`);
    } catch (e) {
      await client.query("ROLLBACK");
      throw new Error(`migration ${name} failed: ${e.message}`);
    }
  }
  log(`migrations: ${applied} newly applied, ${names.length} total`);
}

// Boot the embedded cluster (initdb on first run), ensure the db exists, run migrations. Returns the
// EmbeddedPostgres handle (call .stop() on quit) and the DATABASE_URL connection string.
async function startEmbeddedPostgres({ dataDir, migrationsDir, log = () => {} }) {
  fs.mkdirSync(dataDir, { recursive: true });
  const port = await freePort();
  const fresh = !fs.existsSync(path.join(dataDir, "PG_VERSION"));
  const pg = new EmbeddedPostgres({ databaseDir: dataDir, port, user: USER, password: PASSWORD, persistent: true, onLog: log, onError: log });
  if (fresh) { log("initialising database (first run)…"); await pg.initialise(); }
  log(`starting postgres on 127.0.0.1:${port}…`);
  await pg.start();
  try { await pg.createDatabase(DB); } catch { /* already exists */ }
  const client = pg.getPgClient(DB);
  await client.connect();
  try { await runMigrations(client, migrationsDir, log); } finally { await client.end(); }
  return { pg, connectionString: `postgresql://${USER}:${PASSWORD}@127.0.0.1:${port}/${DB}` };
}

module.exports = { startEmbeddedPostgres };
