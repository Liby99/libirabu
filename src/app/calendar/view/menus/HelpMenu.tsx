"use client";

// "Help" dropdown in the top bar. Both entries open the same Help center modal
// (view/help/HelpModal); they just pick which section it lands on.

import { useEffect, useRef, useState } from "react";
import MenuBackdrop from "./MenuBackdrop";
import HelpModal from "../help/HelpModal";
import type { HelpSectionId } from "../help/content";

export default function HelpMenu() {
  const [open, setOpen] = useState(false);
  const [modal, setModal] = useState<HelpSectionId | null>(null);
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open]);

  const openModal = (m: HelpSectionId) => { setModal(m); setOpen(false); };

  return (
    <div className="cc-year-wrap" ref={wrapRef}>
      <button className="cc-action cc-action-sm cc-action-plain" onClick={() => setOpen((o) => !o)}>Help<span className="cc-caret">▾</span></button>
      {open && (
        <>
          <MenuBackdrop onClose={() => setOpen(false)} />
          <div className="cc-menu" role="menu">
            <button className="cc-menu-item" onClick={() => openModal("overview")}>Docs Help</button>
            <button className="cc-menu-item" onClick={() => openModal("keys")}>Keyboard Shortcuts</button>
          </div>
        </>
      )}
      {modal && <HelpModal initial={modal} onClose={() => setModal(null)} />}
    </div>
  );
}
