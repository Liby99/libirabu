"use client";

import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Search, Globe, CalendarDays, CalendarPlus, Pencil, Trash2, Eye, Loader2, Check, X, ArrowUp, Ban, Compass, Brain, Paperclip, FileText, History, Undo2, CircleStop, RotateCcw, MessagesSquare, SquarePen, Settings, ChevronDown } from "lucide-react";

interface HistoryItem { id: string; kind: string; status: string; createdAt: string; title: string; occurrenceDate: string | null }
const histVerb = (it: HistoryItem) =>
  it.kind === "create" ? "Created" : it.kind === "update" ? "Edited" : it.occurrenceDate ? "Skipped an occurrence of" : "Deleted";
const HIST_ICON: Record<string, React.ComponentType<{ size?: number }>> = { create: CalendarPlus, update: Pencil, delete: Trash2 };
import type { ActionBlock, Message, UploadedAttachment, ConversationMeta, AssistantSettings } from "./useAssistant";
import { VENDORS } from "@/lib/assistant/models";

const ACTION_ICON: Record<string, React.ComponentType<{ size?: number }>> = {
  web_search: Search,
  web_open: Globe,
  read_calendar: CalendarDays,
  get_screen_state: Eye,
  create_event: CalendarPlus,
  update_event: Pencil,
  delete_event: Trash2,
  set_view: Compass,
  remember: Brain,
  forget: Trash2,
};

// ── Formatted action detail (click an action → see the underlying payload as real elements) ──
const D = (o: unknown): Record<string, unknown> => (o && typeof o === "object" ? o as Record<string, unknown> : {});
const wallDate = (iso: string) => { const [y, m, d] = iso.slice(0, 10).split("-").map(Number); return new Date(y, (m || 1) - 1, d || 1).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }); };
const wallTime = (iso: string) => { const t = iso.split("T")[1]; if (!t) return ""; const [h, mi] = t.split(":").map(Number); const ap = h >= 12 ? "PM" : "AM"; return `${((h + 11) % 12) + 1}:${String(mi).padStart(2, "0")} ${ap}`; };
function whenLabel(ev: Record<string, unknown>): string {
  const start = String(ev.start ?? ""), end = String(ev.end ?? ""), kind = String(ev.kind ?? "");
  if (!start) return "";
  if (kind === "band") return `${wallDate(start)} – ${wallDate(end)}`;
  if (kind === "deadline") return `${wallDate(start)} · ${wallTime(start)}`;
  return `${wallDate(start)} · ${wallTime(start)}${end ? ` – ${wallTime(end)}` : ""}`;
}
function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return <div className="ca-detail-row"><span className="ca-detail-key">{label}</span><span className="ca-detail-val">{children}</span></div>;
}
function ActionDetail({ kind, detail }: { kind: string; detail: unknown }) {
  const d = D(detail);
  // event-shaped (create/update return the full event)
  if ("title" in d && "start" in d) {
    const repeat = D(d.repeat), tags = Array.isArray(d.tags) ? d.tags as string[] : [];
    return (
      <div className="ca-detail">
        <Row label="Title">{String(d.title)}</Row>
        {d.kind ? <Row label="Kind"><span className="ca-detail-badge">{String(d.kind)}</span></Row> : null}
        <Row label="When">{whenLabel(d)}</Row>
        {d.color ? <Row label="Color"><span className={`ca-detail-swatch cc-ev-${d.color}`} /> {String(d.color)}</Row> : null}
        {repeat.kind && repeat.kind !== "none" ? <Row label="Repeats">{String(repeat.kind)}{repeat.n && Number(repeat.n) > 1 ? ` ×${repeat.n}` : ""}</Row> : null}
        {tags.length ? <Row label="Tags"><span className="ca-detail-tags">{tags.map((t) => <span key={t} className="ca-detail-tag">#{t}</span>)}</span></Row> : null}
        {d.notes ? <Row label="Notes"><span className="ca-detail-notes">{String(d.notes)}</span></Row> : null}
      </div>
    );
  }
  // delete spec
  if ("mode" in d && "id" in d) return (
    <div className="ca-detail">
      <Row label="Event">{String(d.title ?? d.id)}</Row>
      <Row label="Scope">{d.mode === "occurrence" ? `This occurrence${d.occurrenceDate ? ` (${wallDate(String(d.occurrenceDate))})` : ""}` : "Whole series"}</Row>
    </div>
  );
  // set_view
  if ("zoom" in d || "focusedMonth" in d) return (
    <div className="ca-detail">
      {d.year ? <Row label="Year">{String(d.year)}</Row> : null}
      {d.zoom ? <Row label="Zoom">{String(d.zoom)}</Row> : null}
      {d.focusedMonth != null ? <Row label="Month">{["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][Number(d.focusedMonth)] ?? String(d.focusedMonth)}</Row> : null}
    </div>
  );
  // web_search
  if (Array.isArray(d.results)) return (
    <div className="ca-detail">
      {(d.results as Record<string, unknown>[]).slice(0, 6).map((r, i) => (
        <a key={i} className="ca-detail-link" href={String(r.url)} target="_blank" rel="noreferrer">{String(r.title ?? r.url)}</a>
      ))}
    </div>
  );
  // web_open
  if ("url" in d && "text" in d) return (
    <div className="ca-detail">
      <Row label="URL"><a className="ca-detail-link" href={String(d.url)} target="_blank" rel="noreferrer">{String(d.title ?? d.url)}</a></Row>
      {d.text ? <div className="ca-detail-notes">{String(d.text).slice(0, 400)}{String(d.text).length > 400 ? "…" : ""}</div> : null}
    </div>
  );
  // fallback
  return <pre className="ca-detail-json">{JSON.stringify(d, null, 2)}</pre>;
}

function ActionCard({ b, onResolve, onAllow }: { b: ActionBlock; onResolve: (id: string, confirmed: boolean) => void; onAllow: (id: string) => void }) {
  const Icon = ACTION_ICON[b.kind] ?? CalendarDays;
  const [open, setOpen] = useState(false);
  const blocked = b.status === "blocked";
  const reason = blocked ? (b.detail as { reason?: string } | undefined)?.reason : undefined;
  // blocked cards render their reason inline (below), so they're not the generic expandable kind
  const hasDetail = !blocked && b.detail != null && typeof b.detail === "object" && Object.keys(b.detail as object).length > 0;
  return (
    <div className={`ca-action ca-action-${b.status}${open ? " open" : ""}`}>
      <div
        className={`ca-action-head${hasDetail ? " ca-action-clickable" : ""}`}
        onClick={hasDetail ? () => setOpen((o) => !o) : undefined}
        role={hasDetail ? "button" : undefined}
        tabIndex={hasDetail ? 0 : undefined}
        onKeyDown={hasDetail ? (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setOpen((o) => !o); } } : undefined}
      >
        <span className="ca-action-icon"><Icon size={13} /></span>
        <span className="ca-action-text">{b.summary}</span>
        {hasDetail && <ChevronDown size={12} className={`ca-action-chev${open ? " open" : ""}`} />}
        {b.status === "confirm" ? (
          <span className="ca-confirm-btns" onClick={(e) => e.stopPropagation()}>
            <button className="ca-confirm-yes" onClick={() => onResolve(b.id, true)}>Delete</button>
            <button className="ca-confirm-no" onClick={() => onResolve(b.id, false)}>Cancel</button>
          </span>
        ) : (
          <span className="ca-action-status">
            {b.status === "running" && <Loader2 size={12} className="ca-spin" />}
            {b.status === "done" && <Check size={12} />}
            {b.status === "error" && <X size={12} />}
            {b.status === "blocked" && <Ban size={12} />}
            {b.status === "cancelled" && <X size={12} />}
          </span>
        )}
      </div>
      {open && hasDetail && <ActionDetail kind={b.kind} detail={b.detail} />}
      {blocked && (
        <div className="ca-blocked">
          {reason && <div className="ca-blocked-reason">{reason}</div>}
          <button className="ca-allow-btn" onClick={() => onAllow(b.id)}>Allow anyway</button>
        </div>
      )}
    </div>
  );
}

// A custom dropdown styled like the top-bar year selector (frosted list), not a native <select>.
function Dropdown({ value, options, onChange }: {
  value: string;
  options: { id: string; label: string; note?: string }[];
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
    <div className="ca-dropdown" ref={ref}>
      <button type="button" className="ca-dropdown-btn" onClick={() => setOpen((o) => !o)}>
        <span className="ca-dropdown-cur">{current?.label ?? "Select…"}{current?.note ? <span className="ca-dropdown-note"> · {current.note}</span> : null}</span>
        <ChevronDown size={13} className={`ca-dropdown-chev${open ? " open" : ""}`} />
      </button>
      {open && (
        <div className="ca-dropdown-menu" role="listbox">
          {options.map((o) => (
            <button key={o.id} type="button" role="option" aria-selected={o.id === value}
              className={`ca-dropdown-opt${o.id === value ? " sel" : ""}`}
              onClick={() => { onChange(o.id); setOpen(false); }}>
              <span>{o.label}</span>
              {o.note && <span className="ca-dropdown-note">{o.note}</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// The reasoning-model "thinking" for a step — a collapsed-by-default bubble you can expand.
function ThinkingBubble({ content }: { content: string }) {
  const [open, setOpen] = useState(false);
  return (
    <div className={`ca-think${open ? " open" : ""}`}>
      <button className="ca-think-head" onClick={() => setOpen((o) => !o)}>
        <Brain size={12} />
        <span className="ca-think-label">Thinking</span>
        <ChevronDown size={11} className={`ca-think-chev${open ? " open" : ""}`} />
      </button>
      {open && <div className="ca-think-body">{content}</div>}
    </div>
  );
}

export default function AssistantPanel({ messages, busy, send, onStop, onRetry, onClear, onClose, onResolveDelete, onAllow, onListConversations, onLoadConversation, onDeleteConversation, onGetSettings, onSetModel }: {
  messages: Message[];
  busy: boolean;
  send: (t: string, attachments?: UploadedAttachment[]) => void;
  onStop: () => void;
  onRetry: () => void;
  onClear: () => void;
  onClose: () => void;
  onResolveDelete: (id: string, confirmed: boolean) => void;
  onAllow: (id: string) => void;
  onListConversations: () => Promise<ConversationMeta[]>;
  onLoadConversation: (id: string) => void | Promise<void>;
  onDeleteConversation: (id: string) => void | Promise<void>;
  onGetSettings: () => Promise<AssistantSettings>;
  onSetModel: (id: string) => void | Promise<void>;
}) {
  const [draft, setDraft] = useState("");
  const [attachments, setAttachments] = useState<UploadedAttachment[]>([]);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);
  const taRef = useRef<HTMLTextAreaElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages]);
  useEffect(() => { taRef.current?.focus(); }, []);
  // Auto-grow the input with its content (CSS max-height caps it at ~5 lines, then it scrolls).
  useEffect(() => {
    const ta = taRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = `${ta.scrollHeight}px`;
  }, [draft]);

  const onFiles = async (files: FileList | null) => {
    if (!files?.length) return;
    setUploadError(null);
    setUploading(true);
    try {
      for (const file of Array.from(files)) {
        const fd = new FormData();
        fd.append("file", file);
        const res = await fetch("/api/assistant/upload", { method: "POST", body: fd });
        if (!res.ok) {
          const msg = await res.json().catch(() => null);
          setUploadError(`${file.name}: ${msg?.message ?? `upload failed (${res.status})`}`);
          continue;
        }
        const a = (await res.json()) as UploadedAttachment;
        setAttachments((prev) => [...prev, a]);
      }
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  };

  const submit = () => {
    const t = draft.trim();
    if (!t || busy) return;
    send(t, attachments);
    setDraft("");
    setAttachments([]);
  };

  // AI operation history (persistent, back-trackable; separate from ⌘Z).
  const [showHistory, setShowHistory] = useState(false);
  const [histItems, setHistItems] = useState<HistoryItem[]>([]);
  const [histLoading, setHistLoading] = useState(false);
  const [reverting, setReverting] = useState<string | null>(null);

  const loadHistory = async () => {
    setHistLoading(true);
    try {
      const res = await fetch("/api/assistant/history");
      setHistItems(res.ok ? ((await res.json()).actions as HistoryItem[]) : []);
    } catch { setHistItems([]); } finally { setHistLoading(false); }
  };
  // Past conversations (persistent; resumable).
  const [showConvos, setShowConvos] = useState(false);
  const [convos, setConvos] = useState<ConversationMeta[]>([]);
  const [convLoading, setConvLoading] = useState(false);
  const loadConvos = async () => {
    setConvLoading(true);
    try { setConvos(await onListConversations()); } finally { setConvLoading(false); }
  };
  // Settings (model picker).
  const [showSettings, setShowSettings] = useState(false);
  const [vendor, setVendor] = useState("jhu"); // LLM vendor; only "jhu" is wired up so far
  const [settings, setSettings] = useState<AssistantSettings | null>(null);
  const loadSettings = async () => { setSettings(await onGetSettings()); };
  const pickModel = async (id: string) => { setSettings((s) => (s ? { ...s, model: id } : s)); await onSetModel(id); };
  // Memory browser — the durable facts the assistant has remembered (view + forget).
  const [showMemory, setShowMemory] = useState(false);
  const [mems, setMems] = useState<{ key: string; value: unknown; updatedAt: string }[]>([]);
  const [memLoading, setMemLoading] = useState(false);
  const loadMems = async () => {
    setMemLoading(true);
    try { const res = await fetch("/api/assistant/memory"); setMems(res.ok ? (await res.json()).memories : []); }
    finally { setMemLoading(false); }
  };
  const delMem = async (key: string) => {
    await fetch("/api/assistant/memory", { method: "DELETE", headers: { "content-type": "application/json" }, body: JSON.stringify({ key }) });
    await loadMems();
  };

  const toggleHistory = () => { setShowConvos(false); setShowSettings(false); setShowMemory(false); setShowHistory((v) => { const nv = !v; if (nv) loadHistory(); return nv; }); };
  const toggleConvos = () => { setShowHistory(false); setShowSettings(false); setShowMemory(false); setShowConvos((v) => { const nv = !v; if (nv) loadConvos(); return nv; }); };
  const toggleSettings = () => { setShowHistory(false); setShowConvos(false); setShowMemory(false); setShowSettings((v) => { const nv = !v; if (nv) loadSettings(); return nv; }); };
  const toggleMemory = () => { setShowHistory(false); setShowConvos(false); setShowSettings(false); setShowMemory((v) => { const nv = !v; if (nv) loadMems(); return nv; }); };
  const openConvo = async (id: string) => { await onLoadConversation(id); setShowConvos(false); };
  const delConvo = async (id: string) => { await onDeleteConversation(id); await loadConvos(); };
  const doRevert = async (id: string) => {
    setReverting(id);
    try {
      const res = await fetch("/api/assistant/history", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id }) });
      if (res.ok && typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:changed"));
      await loadHistory();
    } finally { setReverting(null); }
  };

  // Drag-and-drop attachments: drop files anywhere on the panel → same upload path as the
  // paperclip button. (Only reacts to file drags; the server validates the file types.)
  const onDragOver = (e: React.DragEvent) => {
    if (!e.dataTransfer.types.includes("Files")) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
    if (!dragOver) setDragOver(true);
  };
  const onDragLeave = (e: React.DragEvent) => {
    if (e.currentTarget.contains(e.relatedTarget as Node | null)) return; // moving over a child, still inside
    setDragOver(false);
  };
  const onDrop = (e: React.DragEvent) => {
    if (!e.dataTransfer.types.includes("Files")) return;
    e.preventDefault();
    setDragOver(false);
    onFiles(e.dataTransfer.files);
  };

  return (
    <div className="ca-panel" onMouseDown={(e) => e.stopPropagation()} onDragOver={onDragOver} onDragLeave={onDragLeave} onDrop={onDrop}>
      <div className="ca-head">
        <span className="ca-title">Assistant</span>
        <div className="ca-head-actions">
          <button className={`ca-close${showMemory ? " ca-head-active" : ""}`} onClick={toggleMemory} title="Memory" aria-label="Memory"><Brain size={15} /></button>
          <button className={`ca-close${showSettings ? " ca-head-active" : ""}`} onClick={toggleSettings} title="Settings" aria-label="Settings"><Settings size={15} /></button>
          <button className={`ca-close${showConvos ? " ca-head-active" : ""}`} onClick={toggleConvos} title="Past conversations" aria-label="Past conversations"><MessagesSquare size={15} /></button>
          <button className={`ca-close${showHistory ? " ca-head-active" : ""}`} onClick={toggleHistory} title="AI change history" aria-label="AI change history"><History size={15} /></button>
          <button className="ca-close" onClick={onClear} disabled={messages.length === 0} title="New chat" aria-label="New chat"><SquarePen size={15} /></button>
          <button className="ca-close" onClick={onClose} title="Close" aria-label="Close"><X size={15} /></button>
        </div>
      </div>

      {showSettings ? (
        <div className="ca-scroll ca-settings">
          <div className="ca-settings-label">Vendor</div>
          <Dropdown value={vendor} onChange={setVendor}
            options={VENDORS.map((v) => ({ id: v.id, label: v.label, note: v.soon ? "coming soon" : undefined }))} />

          {vendor === "jhu" ? (
            <>
              <div className="ca-settings-label">Model</div>
              {!settings ? (
                <div className="ca-empty">Loading…</div>
              ) : (
                <Dropdown value={settings.model} onChange={pickModel}
                  options={settings.models.map((m) => ({ id: m.id, label: m.label, note: m.note }))} />
              )}
              <div className="ca-settings-hint">Changing the model affects new messages. Open-weights models vary a lot at multi-step tasks.</div>
            </>
          ) : (
            <div className="ca-settings-hint">Amazon Bedrock support isn’t wired up yet — coming soon.</div>
          )}
        </div>
      ) : showConvos ? (
        <div className="ca-scroll ca-history">
          {convLoading && <div className="ca-empty">Loading…</div>}
          {!convLoading && convos.length === 0 && <div className="ca-empty">No past conversations yet. Your chats are saved here automatically.</div>}
          {convos.map((c) => (
            <div key={c.id} className="ca-hist-item">
              <span className="ca-hist-icon"><MessagesSquare size={13} /></span>
              <button className="ca-hist-text ca-conv-open" onClick={() => openConvo(c.id)} title="Open conversation">
                <span className="ca-hist-summary">{c.title}</span>
                <span className="ca-hist-time">{new Date(c.updatedAt).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}</span>
              </button>
              <button className="ca-hist-revert" onClick={() => delConvo(c.id)} title="Delete conversation" aria-label="Delete conversation"><Trash2 size={12} /></button>
            </div>
          ))}
        </div>
      ) : showHistory ? (
        <div className="ca-scroll ca-history">
          {histLoading && <div className="ca-empty">Loading…</div>}
          {!histLoading && histItems.length === 0 && <div className="ca-empty">No AI changes yet. Events the assistant creates, edits, or deletes will appear here to review and back-track.</div>}
          {histItems.map((it) => {
            const Icon = HIST_ICON[it.kind] ?? CalendarDays;
            const reverted = it.status === "REVERTED";
            return (
              <div key={it.id} className={`ca-hist-item${reverted ? " ca-hist-reverted" : ""}`}>
                <span className="ca-hist-icon"><Icon size={13} /></span>
                <span className="ca-hist-text">
                  <span className="ca-hist-summary">{histVerb(it)} “{it.title}”</span>
                  <span className="ca-hist-time">{new Date(it.createdAt).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}</span>
                </span>
                {reverted ? (
                  <span className="ca-hist-tag">reverted</span>
                ) : (
                  <button className="ca-hist-revert" onClick={() => doRevert(it.id)} disabled={reverting === it.id}>
                    {reverting === it.id ? <Loader2 size={12} className="ca-spin" /> : <><Undo2 size={12} /> Revert</>}
                  </button>
                )}
              </div>
            );
          })}
        </div>
      ) : showMemory ? (
        <div className="ca-scroll ca-history">
          <div className="ca-settings-hint">Durable facts the assistant remembers across chats (preferences, conventions, contacts). Forget anything that's wrong.</div>
          {memLoading && <div className="ca-empty">Loading…</div>}
          {!memLoading && mems.length === 0 && <div className="ca-empty">Nothing remembered yet. When the assistant learns a durable preference or contact, it appears here to review or forget.</div>}
          {mems.map((mem) => (
            <div key={mem.key} className="ca-hist-item">
              <span className="ca-hist-icon"><Brain size={13} /></span>
              <span className="ca-hist-text">
                <span className="ca-mem-key">{mem.key}</span>
                <span className="ca-mem-value">{typeof mem.value === "string" ? mem.value : JSON.stringify(mem.value)}</span>
              </span>
              <button className="ca-hist-revert" onClick={() => delMem(mem.key)} title="Forget this" aria-label="Forget"><Trash2 size={12} /></button>
            </div>
          ))}
        </div>
      ) : (
      <>
      <div className="ca-scroll" ref={scrollRef}>
        {messages.length === 0 && (
          <div className="ca-empty">
            Ask about your calendar — e.g. <em>“what’s on my calendar next week?”</em> or
            <em> “when are the PLDI 2026 deadlines?”</em>
          </div>
        )}
        {messages.map((m, i) =>
          m.role === "user" ? (
            <div key={i} className="ca-row ca-row-user">
              <div className="ca-user-wrap">
                {!!m.attachments?.length && (
                  <div className="ca-att-row ca-att-row-user">
                    {m.attachments.map((a, k) => (
                      <span key={k} className="ca-chip"><FileText size={11} />{a.filename}</span>
                    ))}
                  </div>
                )}
                <div className="ca-bubble ca-bubble-user">{m.text}</div>
              </div>
            </div>
          ) : (
            <div key={i} className="ca-row ca-row-asst">
              <div className="ca-asst-blocks">
                {m.blocks.map((b, j) =>
                  b.type === "action" ? (
                    <ActionCard key={b.id || j} b={b} onResolve={onResolveDelete} onAllow={onAllow} />
                  ) : b.type === "thinking" ? (
                    <ThinkingBubble key={j} content={b.content} />
                  ) : (
                    <div key={j} className="ca-bubble ca-bubble-asst ca-md">
                      <ReactMarkdown remarkPlugins={[remarkGfm]}>{b.text}</ReactMarkdown>
                    </div>
                  ),
                )}
                {/* Awaiting-LLM indicator: show while busy on the active turn, unless a tool is
                    already spinning (its own spinner covers that wait). */}
                {busy && i === messages.length - 1 &&
                  !(m.blocks[m.blocks.length - 1]?.type === "action" && (m.blocks[m.blocks.length - 1] as ActionBlock).status === "running") && (
                    <div className="ca-bubble ca-bubble-asst ca-typing"><span /><span /><span /></div>
                  )}
              </div>
            </div>
          ),
        )}
        {!busy && messages.length > 0 && messages[messages.length - 1].role === "assistant" && (
          <div className="ca-retry-row">
            <button className="ca-retry" onClick={onRetry} title="Re-run the last request"><RotateCcw size={12} /> Retry</button>
          </div>
        )}
      </div>

      {(attachments.length > 0 || uploading || uploadError) && (
        <div className="ca-att-tray">
          {attachments.map((a, k) => (
            <span key={k} className="ca-chip">
              <FileText size={11} />
              <span className="ca-chip-name">{a.filename}</span>
              <button className="ca-chip-x" onClick={() => setAttachments((prev) => prev.filter((_, j) => j !== k))} aria-label="Remove"><X size={11} /></button>
            </span>
          ))}
          {uploading && <span className="ca-chip ca-chip-loading"><Loader2 size={11} className="ca-spin" /> reading…</span>}
          {uploadError && <span className="ca-att-err">{uploadError}</span>}
        </div>
      )}

      <div className="ca-composer">
        <input ref={fileRef} type="file" accept=".pdf,.txt,.md,text/plain,application/pdf" multiple hidden onChange={(e) => onFiles(e.target.files)} />
        <button className="ca-attach" onClick={() => fileRef.current?.click()} disabled={uploading} title="Attach a PDF or text file" aria-label="Attach file">
          <Paperclip size={16} />
        </button>
        <textarea
          ref={taRef}
          className="ca-input"
          value={draft}
          placeholder="Message the assistant…"
          rows={1}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); } }}
        />
        {busy ? (
          <button className="ca-send ca-stop" onClick={onStop} title="Stop" aria-label="Stop generating">
            <CircleStop size={18} />
          </button>
        ) : (
          <button className="ca-send" onClick={submit} disabled={!draft.trim()} aria-label="Send">
            <ArrowUp size={16} />
          </button>
        )}
      </div>

      {dragOver && (
        <div className="ca-drop">
          <Paperclip size={22} />
          <span>Drop to attach</span>
        </div>
      )}
      </>
      )}
    </div>
  );
}
