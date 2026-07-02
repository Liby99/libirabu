"use client";

// Help modal: docs + keyboard-shortcut tabs.

import { useEffect, useRef, useState } from "react";
import MenuBackdrop from "./MenuBackdrop";
import { Dialog } from "@/app/components/ui/Dialog";

type Which = "docs" | "keys";

// Placeholder help content — wired up later.
const CONTENT: Record<Which, { title: string; body: React.ReactNode }> = {
  docs: {
    title: "Docs Help",
    body: (
      <>
        <p>Documentation lives here.</p>
        <p>This is a placeholder — guides for the calendar, events, recurrence, tags, and the daily view will go here.</p>
      </>
    ),
  },
  keys: {
    title: "Keyboard Shortcuts",
    body: (
      <>
        <p>Keyboard shortcuts will be listed here.</p>
        <p>Placeholder — e.g. ⌘Z undo, ⌘C / ⌘V copy &amp; paste, Esc to zoom out, Delete to remove the selected event.</p>
      </>
    ),
  },
};

function HelpModal({ which, onClose }: { which: Which; onClose: () => void }) {
  const { title, body } = CONTENT[which];
  return (
    <Dialog open onClose={onClose} title={title} showClose>
      {body}
    </Dialog>
  );
}

// "Help" dropdown in the top bar: Docs Help + Keyboard Shortcuts, each opening a small modal.
export default function HelpMenu() {
  const [open, setOpen] = useState(false);
  const [modal, setModal] = useState<Which | null>(null);
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open]);

  const openModal = (m: Which) => { setModal(m); setOpen(false); };

  return (
    <div className="cc-year-wrap" ref={wrapRef}>
      <button className="cc-action cc-action-sm cc-action-plain" onClick={() => setOpen((o) => !o)}>Help<span className="cc-caret">▾</span></button>
      {open && (
        <>
          <MenuBackdrop onClose={() => setOpen(false)} />
          <div className="cc-menu" role="menu">
            <button className="cc-menu-item" onClick={() => openModal("docs")}>Docs Help</button>
            <button className="cc-menu-item" onClick={() => openModal("keys")}>Keyboard Shortcuts</button>
          </div>
        </>
      )}
      {modal && <HelpModal which={modal} onClose={() => setModal(null)} />}
    </div>
  );
}
