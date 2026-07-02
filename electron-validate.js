// TCC attribution probe (throwaway) — does a process spawned by Electron inherit Electron's
// Calendar permission? Electron main spawns the EventKit bridge (a child, like the Next server →
// bridge chain would be) and reports the result. If macOS attributes the calendar request to
// Electron.app (a real GUI app), we get a prompt + access; if it attributes to the bridge's own
// identity in a context that can't prompt, we get access-denied — telling us we'd need a native
// addon instead.
//
// Run:  npx electron electron-validate.js
// Watch for a "…wants to access your calendars" prompt (should be attributed to "Electron"), Allow
// it, and read the verdict dialog + terminal output.

const { app, dialog } = require("electron");
const { execFile } = require("child_process");
const path = require("path");

const BIN = path.join(__dirname, "native/eventkit-bridge/EventKitBridge.app/Contents/MacOS/eventkit-bridge");

app.whenReady().then(() => {
  console.log("[validate] Electron pid", process.pid, "spawning bridge:", BIN);
  execFile(BIN, ["list-calendars"], { maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
    const out = (stdout || "").trim() || (stderr || "").trim() || (err ? err.message : "(no output)");
    let verdict;
    try {
      const data = JSON.parse(out);
      if (Array.isArray(data)) verdict = `✅ SUCCESS — the Electron-spawned bridge read ${data.length} calendars.\nElectron's grant flows to child processes → full packaging will work with a plain exec.`;
      else if (data && data.error) verdict = `❌ DENIED — ${data.error}\nElectron's grant did NOT flow to the child → we'll need a native addon (EventKit inside Electron main) instead of a separate binary.`;
      else verdict = `? Unexpected output: ${out.slice(0, 300)}`;
    } catch {
      verdict = `? Non-JSON output: ${out.slice(0, 300)}`;
    }
    console.log("[validate]", verdict);
    console.log("[validate] raw:", out.slice(0, 600));
    try { dialog.showMessageBoxSync({ type: "info", message: "EventKit-under-Electron validation", detail: verdict }); } catch {}
    app.quit();
  });
});

app.on("window-all-closed", () => app.quit());
