"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";

// A reusable hover submenu for the top-bar menus. It opens to the LEFT of its row (the menus hug
// the bar's right edge) and renders a "›" affordance.
//
// The panel is PORTALED to <body> rather than nested inside .cc-menu on purpose: a
// backdrop-filtered ancestor (.cc-menu) turns a descendant's backdrop-filter into a no-op, so a
// nested flyout can never blur. At the top level the panel forms its own backdrop and frosts the
// calendar behind it, matching the other top-bar menus. Its position is measured from the row so it
// stays flush; because the row and the portaled panel are now separate DOM nodes, a short
// schedule-close on leaving EITHER (cancelled on entering EITHER) bridges the gap without flicker.
//
// The panel is tagged data-cc-flyout so a host menu's outside-click handler can treat clicks inside
// it as in-menu even though it lives outside the menu's wrapper — hosts should exempt
// `[data-cc-flyout]` in their close-on-mousedown check (see EditMenu / ViewMenu).
//
// Composition: pass any content as children (a list of `.cc-menu-item` buttons, a richer panel like
// the tag filter, …). `panelClassName` adds panel modifiers (e.g. "cc-tag-submenu"). Selection /
// closing the host menu is the children's job — this component only owns hover + placement + blur.
export default function MenuFlyout({
  label,
  hint,
  panelClassName,
  children,
}: {
  label: ReactNode;
  hint?: ReactNode; // compact summary shown before the "›" (e.g. the current value, or "Filtered")
  panelClassName?: string;
  children: ReactNode;
}) {
  const rowRef = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState<{ top: number; right: number } | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const cancelClose = () => { if (timer.current) { clearTimeout(timer.current); timer.current = null; } };
  const openNow = () => {
    cancelClose();
    const r = rowRef.current?.getBoundingClientRect();
    if (r) setPos({ top: r.top - 5, right: Math.round(window.innerWidth - r.left) }); // right edge flush to the row's left
    setOpen(true);
  };
  const scheduleClose = () => { cancelClose(); timer.current = setTimeout(() => setOpen(false), 90); };
  useEffect(() => () => cancelClose(), []);

  return (
    <div className="cc-menu-sub" ref={rowRef} onMouseEnter={openNow} onMouseLeave={scheduleClose}>
      <button className="cc-menu-item">{label}<span className="cc-menu-sc">{hint}{hint ? " " : ""}›</span></button>
      {open && pos && typeof document !== "undefined" && createPortal(
        <div
          className={`cc-submenu${panelClassName ? " " + panelClassName : ""}`}
          role="menu"
          data-cc-flyout=""
          style={{ position: "fixed", top: pos.top, right: pos.right, zIndex: 40 }}
          onMouseEnter={cancelClose}
          onMouseLeave={scheduleClose}
        >
          {children}
        </div>,
        document.body,
      )}
    </div>
  );
}
