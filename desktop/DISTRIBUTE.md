# libirabu — desktop app (macOS menu-bar)

A self-contained macOS menu-bar app that runs its own local database + server and opens the app in your
default browser. No Docker, no database setup, no configuration.

## For the recipient

**Requirements:** a Mac with Apple Silicon (M1 or newer), macOS 13+.

1. Unzip `libirabu.zip` → `libirabu.app`. Move it to `/Applications` (optional).
2. The app is **unsigned**, so on first launch macOS blocks it. Clear that once — open **Terminal** and run:
   ```
   xattr -cr /path/to/libirabu.app
   ```
   (Or right-click the app → **Open** → **Open**. The `xattr` command is the reliable way on recent macOS.)
3. **Double-click** the app. A **calendar icon** appears in your menu bar (top-right). On first launch it
   sets up its database — give it ~10–20 seconds — then it **auto-opens your default browser**.
4. **Register an account** on the sign-in page (it's a fresh, empty, local copy).

**Menu-bar icon:** click it for **Open libirabu** (reopen in the browser), **Open Logs Folder**, and **Quit**.

**Your data** lives on your Mac at `~/Library/Application Support/libirabu/` (database, files, logs). Nothing
leaves your machine. The **AI assistant** is optional — add your own key under *Account → API Keys* in the app.

To fully remove: Quit the app, delete `libirabu.app`, and delete `~/Library/Application Support/libirabu/`.

---

## For the builder (this repo)

```
npm run app:build      # → dist/libirabu.app  (rebuilds Next + assembles the bundle; arm64)
npm run app:run        # open dist/libirabu.app locally
npm run app:zip        # → dist/libirabu.zip  (what you send)
```

**How it works:** `desktop/build-app.sh` bundles a native Swift menu-bar shell (`desktop/shell/main.swift`)
over a Node "supervisor" (`desktop/supervisor.cjs`). On launch the shell spawns the supervisor, which starts
an **embedded Postgres** (`desktop/db.cjs`, applies `prisma/migrations` directly), generates per-install
secrets (`desktop/secrets.cjs`), starts the **Next.js standalone server**, and prints `READY <port>`; the
shell then opens the browser. Everything is bundled under `Contents/Resources/runtime/`.

**Notes / not-yet:** unsigned (no notarization); Apple-Silicon only; ~370 MB; Apple Calendar *import* (the
EventKit bridge) isn't bundled yet — the rest of the calendar works. Login is required (register once).
