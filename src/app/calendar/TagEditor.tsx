"use client";

import { useEffect, useRef, useState } from "react";
import { X } from "lucide-react";

// #tag editor: each tag is a capsule (× appears on hover to remove); a dashed "+ Tag"
// capsule turns into an input on click — Enter adds, Esc/blur cancels.
export default function TagEditor({ tags, onChange }: { tags: string[]; onChange: (tags: string[]) => void }) {
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => { if (adding) inputRef.current?.focus(); }, [adding]);

  const add = () => {
    const t = draft.trim().replace(/^#+/, "").trim();
    if (t && !tags.includes(t)) onChange([...tags, t]);
    setDraft("");
    setAdding(false);
  };

  return (
    <div className="cc-tags">
      {tags.map((t) => (
        <span key={t} className="cc-tag">
          #{t}
          <button className="cc-tag-x" onMouseDown={(e) => e.preventDefault()} onClick={() => onChange(tags.filter((x) => x !== t))} aria-label={`Remove ${t}`}>
            <X size={11} strokeWidth={2.5} />
          </button>
        </span>
      ))}
      {adding ? (
        <input
          ref={inputRef}
          className="cc-tag-input"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") { e.preventDefault(); add(); }
            else if (e.key === "Escape") { setDraft(""); setAdding(false); }
          }}
          onBlur={add}
          placeholder="tag"
        />
      ) : (
        <button className="cc-tag-add" onClick={() => setAdding(true)}>+ Tag</button>
      )}
    </div>
  );
}
