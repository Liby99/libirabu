// Electron main for libirabu (docs/calendar-import-design.md §5.2 / §12).
//
// WHY this shape: macOS attributes Calendar (TCC) access to the "responsible process". When the app
// is launched via LaunchServices (double-click, or `open`), Electron.app IS that responsible process
// and holds the Calendar grant. The Next.js server is spawned HERE as a CHILD of Electron, so its
// API routes — and the EventKit bridge they exec — inherit Electron's grant. (Running the Next
// server straight from a terminal makes the terminal responsible → calendar access is denied.)
//
// Launch it the LaunchServices way (NOT `electron electron.js` from a shell, which re-poisons the
// responsible process):
//     npm run electron:app
// which runs: open -n node_modules/electron/dist/Electron.app --args "$PWD/electron.js"

const { app, BrowserWindow } = require("electron");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const http = require("http");

const PORT = Number(process.env.PORT) || 8100;
let server = null;
let logFile = "";

// Spawn the Next.js server using Electron's bundled Node (ELECTRON_RUN_AS_NODE) so we don't depend
// on a system node/npm being on PATH — LaunchServices-launched apps get a minimal PATH. Launched via
// `open`, stdout is detached, so pipe the server's output to a log file for debugging.
function startNextServer() {
  const nextBin = path.join(__dirname, "node_modules", "next", "dist", "bin", "next");
  const mode = process.env.LIBIRABU_ELECTRON_START || "dev"; // set =start for a production build
  logFile = path.join(app.getPath("logs"), "next-server.log");
  fs.mkdirSync(path.dirname(logFile), { recursive: true });
  const out = fs.openSync(logFile, "a");
  console.log("[electron] next server log →", logFile);
  server = spawn(process.execPath, [nextBin, mode, "-p", String(PORT)], {
    cwd: __dirname,
    env: { ...process.env, ELECTRON_RUN_AS_NODE: "1", PORT: String(PORT) },
    stdio: ["ignore", out, out],
  });
  server.on("exit", (code) => console.log("[electron] next server exited:", code));
}

function waitForServer() {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 120_000;
    const tick = () => {
      http
        .get({ host: "localhost", port: PORT, path: "/" }, (res) => { res.destroy(); resolve(); })
        .on("error", () => (Date.now() > deadline ? reject(new Error("Next server did not start")) : setTimeout(tick, 500)));
    };
    tick();
  });
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1400,
    height: 950,
    title: "libirabu",
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  });
  win.loadURL(`http://localhost:${PORT}/calendar`);
}

app.whenReady().then(async () => {
  startNextServer();
  try { await waitForServer(); } catch (e) { console.error("[electron]", e.message); }
  createWindow();
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

function stopServer() { if (server && !server.killed) { try { server.kill("SIGTERM"); } catch {} } }
app.on("before-quit", stopServer);
app.on("window-all-closed", () => { stopServer(); if (process.platform !== "darwin") app.quit(); });
