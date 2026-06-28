"use client";

import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Search, Globe, CalendarDays, CalendarPlus, Pencil, Trash2, Eye, Loader2, Check, X, ArrowUp, Ban, Compass, Brain, Paperclip, FileText, History, Undo2, CircleStop, RotateCcw, MessagesSquare, SquarePen, Settings } from "lucide-react";

interface HistoryItem { id: string; kind: string; status: string; createdAt: string; title: string; occurrenceDate: string | null }
const histVerb = (it: HistoryItem) =>
  it.kind === "create" ? "Created" : it.kind === "update" ? "Edited" : it.occurrenceDate ? "Skipped an occurrence of" : "Deleted";
const HIST_ICON: Record<string, React.ComponentType<{ size?: number }>> = { create: CalendarPlus, update: Pencil, delete: Trash2 };
import type { ActionBlock, Message, UploadedAttachment, ConversationMeta, AssistantSettings } from "./useAssistant";

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
};

function ActionCard({ b, onResolve }: { b: ActionBlock; onResolve: (id: string, confirmed: boolean) => void }) {
  const Icon = ACTION_ICON[b.kind] ?? CalendarDays;
  return (
    <div className={`ca-action ca-action-${b.status}`}>
      <span className="ca-action-icon"><Icon size={13} /></span>
      <span className="ca-action-text">{b.summary}</span>
      {b.status === "confirm" ? (
        <span className="ca-confirm-btns">
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
  );
}

export default function AssistantPanel({ messages, busy, send, onStop, onRetry, onClear, onClose, onResolveDelete, onListConversations, onLoadConversation, onDeleteConversation, onGetSettings, onSetModel }: {
  messages: Message[];
  busy: boolean;
  send: (t: string, attachments?: UploadedAttachment[]) => void;
  onStop: () => void;
  onRetry: () => void;
  onClear: () => void;
  onClose: () => void;
  onResolveDelete: (id: string, confirmed: boolean) => void;
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
  const [settings, setSettings] = useState<AssistantSettings | null>(null);
  const loadSettings = async () => { setSettings(await onGetSettings()); };
  const pickModel = async (id: string) => { setSettings((s) => (s ? { ...s, model: id } : s)); await onSetModel(id); };
  const toggleHistory = () => { setShowConvos(false); setShowSettings(false); setShowHistory((v) => { const nv = !v; if (nv) loadHistory(); return nv; }); };
  const toggleConvos = () => { setShowHistory(false); setShowSettings(false); setShowConvos((v) => { const nv = !v; if (nv) loadConvos(); return nv; }); };
  const toggleSettings = () => { setShowHistory(false); setShowConvos(false); setShowSettings((v) => { const nv = !v; if (nv) loadSettings(); return nv; }); };
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
          <button className={`ca-close${showSettings ? " ca-head-active" : ""}`} onClick={toggleSettings} title="Settings" aria-label="Settings"><Settings size={15} /></button>
          <button className={`ca-close${showConvos ? " ca-head-active" : ""}`} onClick={toggleConvos} title="Past conversations" aria-label="Past conversations"><MessagesSquare size={15} /></button>
          <button className={`ca-close${showHistory ? " ca-head-active" : ""}`} onClick={toggleHistory} title="AI change history" aria-label="AI change history"><History size={15} /></button>
          <button className="ca-close" onClick={onClear} disabled={messages.length === 0} title="New chat" aria-label="New chat"><SquarePen size={15} /></button>
          <button className="ca-close" onClick={onClose} title="Close" aria-label="Close"><X size={15} /></button>
        </div>
      </div>

      {showSettings ? (
        <div className="ca-scroll ca-settings">
          <div className="ca-settings-label">Model</div>
          {!settings && <div className="ca-empty">Loading…</div>}
          {settings?.models.map((m) => {
            const active = settings.model === m.id;
            return (
              <button key={m.id} className={`ca-model${active ? " ca-model-active" : ""}`} onClick={() => pickModel(m.id)}>
                <span className="ca-model-radio">{active && <Check size={12} />}</span>
                <span className="ca-model-text">
                  <span className="ca-model-name">{m.label}</span>
                  {m.note && <span className={`ca-model-note${m.needsCredits ? " ca-model-warn" : ""}`}>{m.note}</span>}
                </span>
              </button>
            );
          })}
          <div className="ca-settings-hint">Changing the model affects new messages. Open-weights models vary a lot at multi-step tasks; GPT-5.2 / Claude need the gateway’s credits funded.</div>
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
                    <ActionCard key={b.id || j} b={b} onResolve={onResolveDelete} />
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
