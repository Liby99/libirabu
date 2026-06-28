"use client";

import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Search, Globe, CalendarDays, CalendarPlus, Eye, Loader2, Check, X, ArrowUp, Eraser, Ban, Compass, Brain, Paperclip, FileText } from "lucide-react";
import type { ActionBlock, Message, UploadedAttachment } from "./useAssistant";

const ACTION_ICON: Record<string, React.ComponentType<{ size?: number }>> = {
  web_search: Search,
  web_open: Globe,
  read_calendar: CalendarDays,
  get_screen_state: Eye,
  create_event: CalendarPlus,
  set_view: Compass,
  remember: Brain,
};

function ActionCard({ b }: { b: ActionBlock }) {
  const Icon = ACTION_ICON[b.kind] ?? CalendarDays;
  return (
    <div className={`ca-action ca-action-${b.status}`}>
      <span className="ca-action-icon"><Icon size={13} /></span>
      <span className="ca-action-text">{b.summary}</span>
      <span className="ca-action-status">
        {b.status === "running" && <Loader2 size={12} className="ca-spin" />}
        {b.status === "done" && <Check size={12} />}
        {b.status === "error" && <X size={12} />}
        {b.status === "blocked" && <Ban size={12} />}
      </span>
    </div>
  );
}

export default function AssistantPanel({ messages, busy, send, onClear, onClose }: {
  messages: Message[];
  busy: boolean;
  send: (t: string, attachments?: UploadedAttachment[]) => void;
  onClear: () => void;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState("");
  const [attachments, setAttachments] = useState<UploadedAttachment[]>([]);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const taRef = useRef<HTMLTextAreaElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages]);
  useEffect(() => { taRef.current?.focus(); }, []);

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

  return (
    <div className="ca-panel" onMouseDown={(e) => e.stopPropagation()}>
      <div className="ca-head">
        <span className="ca-title">Assistant</span>
        <div className="ca-head-actions">
          <button className="ca-close" onClick={onClear} disabled={messages.length === 0} title="Clear conversation" aria-label="Clear conversation"><Eraser size={15} /></button>
          <button className="ca-close" onClick={onClose} title="Close" aria-label="Close"><X size={15} /></button>
        </div>
      </div>

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
                    <ActionCard key={b.id || j} b={b} />
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
        <button className="ca-send" onClick={submit} disabled={busy || !draft.trim()} aria-label="Send">
          <ArrowUp size={16} />
        </button>
      </div>
    </div>
  );
}
