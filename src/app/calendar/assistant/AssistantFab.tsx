"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Sparkles } from "lucide-react";
import AssistantPanel from "./AssistantPanel";
import { useAssistant } from "./useAssistant";
import "./assistant.css";

const SIZE = 42; // FAB diameter (px)
const INSET = 20; // distance from the viewport edge
const ACTIVITY_W = 52; // left activity bar — keep the FAB clear of it (it spans the full height)
const STORE_KEY = "assistant.fab.pos";
const F = [0, 1 / 3, 1 / 2, 2 / 3, 1]; // fractional positions along an edge

interface Pos { x: number; y: number }
// Edge-relative anchor (0..1). fx/fy of 0 or 1 sit exactly INSET from the edge; middle values
// scale with the viewport — so the button keeps its place (and stays on-screen) as it resizes.
interface Anchor { fx: number; fy: number }

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));
const easeOut = (t: number) => 1 - Math.pow(1 - t, 3); // easeOutCubic

// `drawerW` is the width of an open event drawer (0 when none) — the usable horizontal space is the
// viewport MINUS the drawer, so the FAB (and its panel) never collide with it. The button's edge-
// relative anchor is unchanged; only the pixel mapping shrinks, so it glides left as the drawer opens.
function anchorPixel(a: Anchor, W: number, H: number, drawerW = 0): Pos {
  const left = ACTIVITY_W + INSET; // leftmost x — just to the right of the activity bar
  const rightEnd = Math.max(left, W - drawerW - SIZE - INSET); // right end of the usable range (left of the drawer)
  return {
    x: clamp(left + a.fx * (rightEnd - left), ACTIVITY_W, Math.max(0, W - SIZE)),
    y: clamp(INSET + a.fy * (H - SIZE - 2 * INSET), 0, Math.max(0, H - SIZE)),
  };
}
// Snap targets: thirds / halves / insets along the top, bottom, and right edges (design §4.1).
const ANCHORS: Anchor[] = [
  ...F.flatMap((fx) => [{ fx, fy: 0 }, { fx, fy: 1 }]),
  ...F.map((fy) => ({ fx: 1, fy })),
];
function nearestAnchor(p: Pos, W: number, H: number, drawerW = 0): Anchor {
  let best = ANCHORS[0], bestD = Infinity;
  for (const a of ANCHORS) {
    const q = anchorPixel(a, W, H, drawerW);
    const d = (q.x - p.x) ** 2 + (q.y - p.y) ** 2;
    if (d < bestD) { bestD = d; best = a; }
  }
  return best;
}

export default function AssistantFab() {
  const [mounted, setMounted] = useState(false);
  const [pos, setPos] = useState<Pos>({ x: 0, y: 0 });
  const posRef = useRef(pos);
  posRef.current = pos;
  const [open, setOpen] = useState(false);
  const [drawerDocked, setDrawerDocked] = useState(false); // an event drawer is open → dock the panel left
  const [drawerW, setDrawerW] = useState(0); // open drawer's width in px (0 = none) — shrinks the FAB's usable space
  const drawerWRef = useRef(0);
  drawerWRef.current = drawerW;
  const anchorRef = useRef<Anchor>({ fx: 1, fy: 1 }); // current snapped anchor (default: bottom-right)
  const draggingRef = useRef(false);
  const animRef = useRef<number | null>(null);
  const { messages, busy, send, stop, retry, extend, clear, resolveDelete, allowAction, listConversations, loadConversation, deleteConversation, getSettings, setModel } = useAssistant();

  const cancelAnim = useCallback(() => {
    if (animRef.current != null) { cancelAnimationFrame(animRef.current); animRef.current = null; }
  }, []);

  // Ease-out glide from the current position to `to` (used when releasing a drag onto a snap).
  const animateTo = useCallback((to: Pos, dur = 280) => {
    cancelAnim();
    const from = posRef.current;
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const p = Math.min(1, (ts - t0) / dur);
      const k = easeOut(p);
      setPos({ x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k });
      if (p < 1) animRef.current = requestAnimationFrame(step);
      else animRef.current = null;
    };
    animRef.current = requestAnimationFrame(step);
  }, [cancelAnim]);

  // Initial placement: restore the saved anchor (migrating a legacy pixel position), else
  // default to the bottom-right.
  useEffect(() => {
    setMounted(true);
    const W = window.innerWidth, H = window.innerHeight;
    let a: Anchor = { fx: 1, fy: 1 };
    try {
      const raw = localStorage.getItem(STORE_KEY);
      if (raw) {
        const o = JSON.parse(raw);
        if (typeof o?.fx === "number" && typeof o?.fy === "number") a = { fx: clamp(o.fx, 0, 1), fy: clamp(o.fy, 0, 1) };
        else if (typeof o?.x === "number" && typeof o?.y === "number") a = nearestAnchor({ x: clamp(o.x, 0, W - SIZE), y: clamp(o.y, 0, H - SIZE) }, W, H);
      }
    } catch { /* ignore */ }
    anchorRef.current = a;
    setPos(anchorPixel(a, W, H));
  }, []);

  // Follow the viewport on resize so the button stays put (and never drifts off-screen).
  useEffect(() => {
    const onResize = () => {
      if (draggingRef.current) return; // the user is actively dragging it
      cancelAnim();
      setPos(anchorPixel(anchorRef.current, window.innerWidth, window.innerHeight, drawerWRef.current));
    };
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, [cancelAnim]);

  useEffect(() => () => cancelAnim(), [cancelAnim]); // stop any glide on unmount

  // Track the open drawer's width (body.cc-drawer-open + the --cc-drawer-w var, which also changes
  // when the drawer is resized) so the FAB's usable space excludes it.
  useEffect(() => {
    const read = () => {
      if (!document.body.classList.contains("cc-drawer-open")) return 0;
      const raw = getComputedStyle(document.documentElement).getPropertyValue("--cc-drawer-w").trim();
      const w = parseFloat(raw);
      return Number.isFinite(w) ? w : 372;
    };
    const update = () => { const w = read(); setDrawerW(w); setDrawerDocked(w > 0); };
    update();
    const obs = new MutationObserver(update);
    obs.observe(document.body, { attributes: true, attributeFilter: ["class"] });          // open / close
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["style"] }); // --cc-drawer-w resize
    return () => obs.disconnect();
  }, []);

  // When the drawer opens/closes/resizes, glide the FAB to its drawer-constrained anchor position —
  // so a right-edge button slides left as the drawer animates in, and back when it closes.
  useEffect(() => {
    if (draggingRef.current) return;
    animateTo(anchorPixel(anchorRef.current, window.innerWidth, window.innerHeight, drawerW), 300);
  }, [drawerW, animateTo]);

  const onMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    cancelAnim();
    const start = posRef.current;
    const dx = e.clientX - start.x, dy = e.clientY - start.y;
    let moved = false;
    const onMove = (me: MouseEvent) => {
      if (Math.abs(me.movementX) + Math.abs(me.movementY) > 0) { moved = true; draggingRef.current = true; }
      setPos({ x: clamp(me.clientX - dx, ACTIVITY_W, window.innerWidth - drawerWRef.current - SIZE), y: clamp(me.clientY - dy, 0, window.innerHeight - SIZE) });
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      draggingRef.current = false;
      if (!moved) { setOpen((o) => !o); return; } // a click, not a drag
      const W = window.innerWidth, H = window.innerHeight;
      const a = nearestAnchor(posRef.current, W, H, drawerWRef.current);
      anchorRef.current = a;
      try { localStorage.setItem(STORE_KEY, JSON.stringify(a)); } catch { /* ignore */ }
      animateTo(anchorPixel(a, W, H, drawerWRef.current)); // glide to the snap, don't teleport
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  }, [cancelAnim, animateTo]);

  if (!mounted) return null;

  // Panel placement: open it on the roomier side of the FAB, clamped to the viewport.
  const W = window.innerWidth, H = window.innerHeight;
  const cx = pos.x + SIZE / 2, cy = pos.y + SIZE / 2;
  const panelStyle: React.CSSProperties = { position: "fixed", transition: "left 0.22s ease, right 0.22s ease" };
  if (cx > W / 2) panelStyle.right = clamp(W - (pos.x + SIZE), INSET, W - INSET);
  else panelStyle.left = clamp(pos.x, INSET, W - INSET);
  if (cy > H / 2) panelStyle.bottom = clamp(H - pos.y + 10, INSET, H - INSET);
  else panelStyle.top = clamp(pos.y + SIZE + 10, INSET, H - INSET);
  // A drawer opens on the RIGHT: anchor the panel's right edge just left of it (the FAB has moved
  // there too), so the panel opens into the free space and never overlaps the drawer.
  if (drawerDocked) { panelStyle.right = drawerW + INSET; delete panelStyle.left; }

  return createPortal(
    <>
      <button
        className={`ca-fab${open ? " ca-fab-open" : ""}${busy ? " ca-fab-busy" : ""}`}
        style={{ left: pos.x, top: pos.y, width: SIZE, height: SIZE }}
        onMouseDown={onMouseDown}
        title="AI assistant"
        aria-label="AI assistant"
      >
        <Sparkles size={17} />
      </button>
      {open && (
        <div style={panelStyle} className="ca-panel-wrap">
          <AssistantPanel messages={messages} busy={busy} send={send} onStop={stop} onRetry={retry} onExtend={extend} onClear={clear} onClose={() => setOpen(false)} onResolveDelete={resolveDelete} onAllow={allowAction} onListConversations={listConversations} onLoadConversation={loadConversation} onDeleteConversation={deleteConversation} onGetSettings={getSettings} onSetModel={setModel} />
        </div>
      )}
    </>,
    document.body,
  );
}
