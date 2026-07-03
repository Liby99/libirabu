// Next.js instrumentation — runs once when the server process starts.
// We use it to kick off the background calendar sync (docs §12.3).

export async function register(): Promise<void> {
  if (process.env.NEXT_RUNTIME !== "nodejs") return;

  // Only auto-sync from the real (production) server: in `next dev` the controlling terminal — not
  // this app — is the TCC-responsible process, so the EventKit bridge would be denied and every
  // tick would just error. AUTO_SYNC=1 forces it on anyway; AUTO_SYNC=0 forces it off.
  const enabled = process.env.AUTO_SYNC === "1" || (process.env.AUTO_SYNC !== "0" && process.env.NODE_ENV === "production");
  if (!enabled) return;

  const { startAutoSync } = await import("@/lib/import/autoSync");
  startAutoSync();
}
