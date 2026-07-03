"use client";

// Account settings — a Dialog with a left sidebar (Account | Security).
//   • Account:  email (read-only), avatar (upload/remove), username, personal website.
//   • Security: change password (current → new → confirm).
// Avatars are cropped+resized to a small square client-side and stored as a data URL.

import { useCallback, useEffect, useRef, useState } from "react";
import { User as UserIcon, ShieldCheck, KeyRound, Camera, Trash2, Palette, Sun, Moon, Monitor, Check, ChevronDown } from "lucide-react";
import { Dialog, DialogButton } from "@/app/components/ui/Dialog";
import { getThemeMode, effectiveVariant, setThemeMode, getSelectedTheme, setSelectedTheme, themesFor, type ThemeMode, type Variant } from "./theme";

export interface AccountProfile {
  email: string;
  name: string | null;
  website: string | null;
  image: string | null;
}

type Tab = "account" | "security" | "keys" | "theme";

// Draw the picked image into a 256² cover-cropped canvas → compact JPEG data URL.
function resizeToDataURL(file: File, size = 256): Promise<string> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const url = URL.createObjectURL(file);
    img.onload = () => {
      URL.revokeObjectURL(url);
      const canvas = document.createElement("canvas");
      canvas.width = size; canvas.height = size;
      const ctx = canvas.getContext("2d");
      if (!ctx) return reject(new Error("no canvas"));
      const scale = Math.max(size / img.width, size / img.height);
      const w = img.width * scale, h = img.height * scale;
      ctx.drawImage(img, (size - w) / 2, (size - h) / 2, w, h);
      resolve(canvas.toDataURL("image/jpeg", 0.85));
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("bad image")); };
    img.src = url;
  });
}

function initials(p: AccountProfile): string {
  const s = (p.name || p.email || "?").trim();
  return s.slice(0, 1).toUpperCase();
}

export default function AccountModal({
  open, onClose, initialTab = "account", profile, onSaved,
}: {
  open: boolean;
  onClose: () => void;
  initialTab?: Tab;
  profile: AccountProfile;
  onSaved: (p: AccountProfile) => void;
}) {
  const [tab, setTab] = useState<Tab>(initialTab);
  useEffect(() => { if (open) setTab(initialTab); }, [open, initialTab]);

  return (
    <Dialog open={open} onClose={onClose} showClose cardClassName="acct-card" labelId="acct-title">
      <div className="acct-layout">
        <nav className="acct-side" aria-label="Settings sections">
          <button type="button" className={`acct-side-item${tab === "account" ? " sel" : ""}`} onClick={() => setTab("account")}>
            <UserIcon size={16} /> Account
          </button>
          <button type="button" className={`acct-side-item${tab === "security" ? " sel" : ""}`} onClick={() => setTab("security")}>
            <ShieldCheck size={16} /> Security
          </button>
          <button type="button" className={`acct-side-item${tab === "keys" ? " sel" : ""}`} onClick={() => setTab("keys")}>
            <KeyRound size={16} /> API Keys
          </button>
          <button type="button" className={`acct-side-item${tab === "theme" ? " sel" : ""}`} onClick={() => setTab("theme")}>
            <Palette size={16} /> Theme
          </button>
        </nav>
        <section className="acct-content">
          {tab === "account" ? <AccountTab profile={profile} onSaved={onSaved} />
            : tab === "security" ? <SecurityTab email={profile.email} />
            : tab === "theme" ? <ThemeTab />
            : <KeysTab />}
        </section>
      </div>
    </Dialog>
  );
}

// ── Theme ─────────────────────────────────────────────────────────────────────────────────────
const THEME_MODES: { id: ThemeMode; label: string; icon: React.ReactNode }[] = [
  { id: "light", label: "Light", icon: <Sun size={15} /> },
  { id: "dark", label: "Dark", icon: <Moon size={15} /> },
  { id: "auto", label: "Auto (System)", icon: <Monitor size={15} /> },
];

function ThemeTab() {
  const [mode, setMode] = useState<ThemeMode>("auto");
  // Which variant's themes are shown. Defaults to whatever's in effect when the tab opens
  // (dark now → Dark Theme tab; light now → Light Theme tab).
  const [pane, setPane] = useState<Variant>("light");
  // The chosen theme id per variant.
  const [sel, setSel] = useState<Record<Variant, string>>({ light: "light", dark: "dark" });

  useEffect(() => {
    const m = getThemeMode();
    setMode(m);
    setPane(effectiveVariant(m));
    setSel({ light: getSelectedTheme("light"), dark: getSelectedTheme("dark") });
  }, []);

  const chooseMode = (m: ThemeMode) => {
    setMode(m);
    setThemeMode(m); // persist + apply live
    setPane(effectiveVariant(m)); // reveal the matching variant's themes
  };
  const chooseTheme = (id: string) => {
    setSelectedTheme(pane, id); // persist + apply live (visible now if this variant is active)
    setSel((s) => ({ ...s, [pane]: id }));
  };

  return (
    <>
      <h2 id="acct-title" className="acct-h">Theme</h2>
      <p className="acct-sub">Choose how the app looks. Auto follows your system appearance.</p>

      <div className="acct-seg" role="radiogroup" aria-label="Theme mode">
        {THEME_MODES.map((m) => (
          <button
            key={m.id}
            type="button"
            role="radio"
            aria-checked={mode === m.id}
            className={`acct-seg-btn${mode === m.id ? " sel" : ""}`}
            onClick={() => chooseMode(m.id)}
          >
            {m.icon}{m.label}
          </button>
        ))}
      </div>

      <div className="acct-theme-tabs" role="tablist" aria-label="Theme variant">
        <button type="button" role="tab" aria-selected={pane === "light"} className={`acct-theme-tab${pane === "light" ? " sel" : ""}`} onClick={() => setPane("light")}>Light Theme</button>
        <button type="button" role="tab" aria-selected={pane === "dark"} className={`acct-theme-tab${pane === "dark" ? " sel" : ""}`} onClick={() => setPane("dark")}>Dark Theme</button>
      </div>

      <div className="acct-theme-panel">
        {themesFor(pane).map((t) => (
          <button
            key={t.id}
            type="button"
            className={`acct-theme-swatch${sel[pane] === t.id ? " sel" : ""}`}
            data-theme-id={t.id}
            aria-pressed={sel[pane] === t.id}
            onClick={() => chooseTheme(t.id)}
          >
            <span className="acct-theme-swatch-preview" aria-hidden />
            <span className="acct-theme-swatch-label">{t.name}</span>
            <Check size={16} className="acct-theme-swatch-check" />
          </button>
        ))}
      </div>
    </>
  );
}

function AccountTab({ profile, onSaved }: { profile: AccountProfile; onSaved: (p: AccountProfile) => void }) {
  const [name, setName] = useState(profile.name ?? "");
  const [website, setWebsite] = useState(profile.website ?? "");
  const [image, setImage] = useState<string | null>(profile.image);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  // Resync when a fresh profile arrives (e.g. reopened after a save elsewhere).
  useEffect(() => { setName(profile.name ?? ""); setWebsite(profile.website ?? ""); setImage(profile.image); }, [profile]);

  const dirty = (name.trim() || null) !== (profile.name ?? null)
    || (website.trim() || null) !== (profile.website ?? null)
    || image !== profile.image;

  async function pickAvatar(file: File) {
    setError(null);
    try { setImage(await resizeToDataURL(file)); }
    catch { setError("Couldn't read that image."); }
  }

  async function save() {
    setBusy(true); setError(null); setSaved(false);
    try {
      const res = await fetch("/api/account", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, website, image }),
      });
      const j = await res.json();
      if (!res.ok) throw new Error(j.error || "Save failed");
      onSaved(j as AccountProfile);
      setSaved(true);
    } catch (e) { setError(e instanceof Error ? e.message : "Save failed"); }
    finally { setBusy(false); }
  }

  return (
    <>
      <h2 id="acct-title" className="acct-h">Account</h2>

      <div className="acct-avatar-row">
        <div className="acct-avatar" aria-hidden>
          {image
            // eslint-disable-next-line @next/next/no-img-element -- data-URL avatar; next/image can't optimize it
            ? <img src={image} alt="" />
            : <span className="acct-avatar-fallback">{initials(profile)}</span>}
        </div>
        <div className="acct-avatar-actions">
          <button type="button" className="acct-btn-sm" onClick={() => fileInput.current?.click()}><Camera size={14} /> Change</button>
          {image && <button type="button" className="acct-btn-sm danger" onClick={() => setImage(null)}><Trash2 size={14} /> Remove</button>}
          <input ref={fileInput} type="file" accept="image/*" hidden
            onChange={(e) => { const f = e.target.files?.[0]; if (f) void pickAvatar(f); e.target.value = ""; }} />
        </div>
      </div>

      <label className="acct-field">
        <span className="acct-label">Email</span>
        <input className="acct-input" value={profile.email} readOnly disabled title="Email can't be changed" />
      </label>
      <label className="acct-field">
        <span className="acct-label">Username</span>
        <input className="acct-input" value={name} onChange={(e) => { setName(e.target.value); setSaved(false); }} placeholder="Your name" maxLength={60} />
      </label>
      <label className="acct-field">
        <span className="acct-label">Personal website</span>
        <input className="acct-input" value={website} onChange={(e) => { setWebsite(e.target.value); setSaved(false); }} placeholder="https://example.com" inputMode="url" />
      </label>

      {error && <div className="acct-error">{error}</div>}
      <div className="acct-foot">
        {saved && !dirty && <span className="acct-ok">Saved</span>}
        <DialogButton variant="primary" disabled={busy || !dirty} onClick={save}>{busy ? "Saving…" : "Save changes"}</DialogButton>
      </div>
    </>
  );
}

// A custom frosted dropdown (matches the assistant's model selector), not a native <select>.
function Dropdown({ value, options, placeholder, onChange }: {
  value: string;
  options: { id: string; label: string }[];
  placeholder?: string;
  onChange: (id: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open]);
  const current = options.find((o) => o.id === value);
  return (
    <div className="acct-dd" ref={ref}>
      <button type="button" className="acct-dd-btn" onClick={() => setOpen((o) => !o)}>
        <span className={`acct-dd-cur${current ? "" : " placeholder"}`}>{current?.label ?? placeholder ?? "Select…"}</span>
        <ChevronDown size={13} className={`acct-dd-chev${open ? " open" : ""}`} />
      </button>
      {open && (
        <div className="acct-dd-menu" role="listbox">
          {options.map((o) => (
            <button key={o.id} type="button" role="option" aria-selected={o.id === value}
              className={`acct-dd-opt${o.id === value ? " sel" : ""}`}
              onClick={() => { onChange(o.id); setOpen(false); }}>
              {o.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// ── API Keys ────────────────────────────────────────────────────────────────────────────────────
interface KeyState { service: string; configured: boolean; last4: string | null; region: string | null }

const AWS_REGIONS = [
  "us-east-1", "us-east-2", "us-west-2",
  "ca-central-1", "sa-east-1",
  "eu-central-1", "eu-west-1", "eu-west-2", "eu-west-3", "eu-north-1",
  "ap-south-1", "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2",
];

const KEY_SERVICES: { id: string; name: string; hint: string; region?: boolean; placeholder: string }[] = [
  { id: "bedrock", name: "AWS Bedrock", hint: "Assistant backend (stored for later).", region: true, placeholder: "Bedrock API key" },
  { id: "jhu-gateway", name: "JHU Gateway", hint: "The assistant's current backend.", placeholder: "jhu_live_sk_…" },
  { id: "openai", name: "OpenAI", hint: "Direct OpenAI backend (stored for later).", placeholder: "sk-…" },
  { id: "anthropic", name: "Anthropic", hint: "Direct Anthropic backend (stored for later).", placeholder: "sk-ant-…" },
];
const SEARCH_SERVICE = { id: "tavily", name: "Tavily", hint: "Powers the assistant's web search.", placeholder: "tvly-…" };

function KeysTab() {
  const [states, setStates] = useState<Record<string, KeyState> | null>(null);

  const load = useCallback(async () => {
    try {
      const res = await fetch("/api/account/keys");
      if (res.ok) {
        const j = (await res.json()) as { keys: KeyState[] };
        setStates(Object.fromEntries(j.keys.map((k) => [k.service, k])));
      }
    } catch { setStates({}); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  return (
    <>
      <h2 id="acct-title" className="acct-h">API Keys</h2>
      <p className="acct-sub">Used by the app instead of its built-in keys. Stored encrypted; only the last 4 digits are shown.</p>

      <div className="acct-group-head">AI assistant</div>
      {KEY_SERVICES.map((s) => <KeyRow key={s.id} meta={s} state={states?.[s.id]} onChanged={load} />)}

      <div className="acct-group-head">Web search</div>
      <KeyRow meta={SEARCH_SERVICE} state={states?.[SEARCH_SERVICE.id]} onChanged={load} />
    </>
  );
}

function KeyRow({ meta, state, onChanged }: {
  meta: { id: string; name: string; hint: string; region?: boolean; placeholder: string };
  state?: KeyState;
  onChanged: () => void | Promise<void>;
}) {
  const [value, setValue] = useState("");
  const [region, setRegion] = useState(state?.region ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => { setRegion(state?.region ?? ""); }, [state?.region]);

  async function send(body: object) {
    setBusy(true); setError(null);
    try {
      const res = await fetch("/api/account/keys", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      if (!res.ok) throw new Error((await res.json()).error || "Save failed");
      setValue("");
      await onChanged();
    } catch (e) { setError(e instanceof Error ? e.message : "Save failed"); }
    finally { setBusy(false); }
  }

  async function remove() {
    setBusy(true); setError(null);
    try {
      const res = await fetch(`/api/account/keys?service=${meta.id}`, { method: "DELETE" });
      if (!res.ok) throw new Error("Couldn't remove");
      await onChanged();
    } catch (e) { setError(e instanceof Error ? e.message : "Couldn't remove"); }
    finally { setBusy(false); }
  }

  return (
    <div className="acct-key">
      <div className="acct-key-head">
        <span className="acct-key-name">{meta.name}</span>
        {state?.configured
          ? <span className="acct-key-mask">•••• {state.last4}</span>
          : <span className="acct-key-unset">Not set</span>}
      </div>
      <div className="acct-key-hint">{meta.hint}</div>
      <div className="acct-key-controls">
        <input
          className="acct-input" type="password" value={value} placeholder={state?.configured ? "Enter a new key to replace" : meta.placeholder}
          autoComplete="off" onChange={(e) => setValue(e.target.value)}
        />
        <DialogButton variant="primary" disabled={busy || !value.trim()} onClick={() => send({ service: meta.id, value })}>Save</DialogButton>
        {state?.configured && <button type="button" className="acct-btn-sm danger" disabled={busy} onClick={remove}><Trash2 size={14} /> Remove</button>}
      </div>
      {meta.region && (
        <div className="acct-key-controls">
          <div className="acct-region">
            <span className="acct-label">AWS Region</span>
            <Dropdown
              value={region}
              placeholder="Select a region…"
              options={AWS_REGIONS.map((r) => ({ id: r, label: r }))}
              onChange={(r) => { setRegion(r); void send({ service: meta.id, region: r }); }}
            />
          </div>
        </div>
      )}
      {error && <div className="acct-error">{error}</div>}
    </div>
  );
}

function SecurityTab({ email }: { email: string }) {
  const [oldPassword, setOld] = useState("");
  const [newPassword, setNew] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  async function change() {
    setError(null); setDone(false);
    if (newPassword.length < 6) return setError("New password must be at least 6 characters.");
    if (newPassword !== confirm) return setError("New passwords don't match.");
    setBusy(true);
    try {
      const res = await fetch("/api/auth/change-password", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, oldPassword, newPassword }),
      });
      const j = await res.json();
      if (!res.ok) throw new Error(j.error || "Couldn't change password");
      setDone(true); setOld(""); setNew(""); setConfirm("");
    } catch (e) { setError(e instanceof Error ? e.message : "Couldn't change password"); }
    finally { setBusy(false); }
  }

  return (
    <>
      <h2 id="acct-title" className="acct-h">Security</h2>
      <p className="acct-sub">Change your password. You’ll stay signed in on this device.</p>
      <label className="acct-field">
        <span className="acct-label">Current password</span>
        <input className="acct-input" type="password" value={oldPassword} onChange={(e) => { setOld(e.target.value); setDone(false); }} autoComplete="current-password" />
      </label>
      <label className="acct-field">
        <span className="acct-label">New password</span>
        <input className="acct-input" type="password" value={newPassword} onChange={(e) => { setNew(e.target.value); setDone(false); }} autoComplete="new-password" />
      </label>
      <label className="acct-field">
        <span className="acct-label">Confirm new password</span>
        <input className="acct-input" type="password" value={confirm} onChange={(e) => { setConfirm(e.target.value); setDone(false); }} autoComplete="new-password" />
      </label>
      {error && <div className="acct-error">{error}</div>}
      <div className="acct-foot">
        {done && <span className="acct-ok">Password changed</span>}
        <DialogButton variant="primary" disabled={busy || !oldPassword || !newPassword || !confirm} onClick={change}>{busy ? "Changing…" : "Change password"}</DialogButton>
      </div>
    </>
  );
}
