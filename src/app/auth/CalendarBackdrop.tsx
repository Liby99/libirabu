"use client";

// A purely decorative calendar grid for the sign-in page background. It reuses the real
// scene builder (buildScene) and item renderer (ItemView), so it looks exactly like the
// live calendar and themes correctly — but with NO events, NO stores, NO data fetches and
// NO interactivity. The whole layer is pointer-events:none and dimmed via CSS (.auth-backdrop).
//
// Deliberately hookless: it never touches useCalendarInteractions / useEvents / useSession,
// so it renders on the logged-out /auth route without hitting /api/calendar or needing auth.

import { useEffect, useMemo, useState } from "react";
import { buildScene } from "../calendar/geometry/scene";
import type { Vp, Hover } from "../calendar/geometry/types";
import ItemView from "../calendar/view/events/Item";
// Grid primitive styling (.cc-item, .cc-gridline, .cc-row, .cc-today, labels…) and the
// .cc-wrap colour variables the items read. Normally only the calendar route loads these.
import "../calendar/styles/01-base.css";
import "../calendar/styles/02-grid.css";

// Empty hover — mirrors NO_HOVER in useCalendarInteractions (nothing is highlighted).
const NO_HOVER: Hover = { month: null, dom: null, week: null, hour: null, hourFrac: null, nameMonth: null, nearLeft: null };

// Decorative view position: month view (z=1) of the current month. z levels: 0 year · 1 month
// · 2 week · 3 daily. Month view reads as an unmistakable calendar while staying robust as a
// static, unscrolled frame. Tune z/focus here to taste.
const VIEW_Z = 1;

export default function CalendarBackdrop() {
  // Measure the viewport ourselves (no ResizeObserver plumbing needed for a static frame).
  // {w:0,h:0} until mounted → render nothing, matching CalendarCanvas's `vp.w === 0` guard.
  const [vp, setVp] = useState<Vp>({ w: 0, h: 0 });
  useEffect(() => {
    const measure = () => setVp({ w: window.innerWidth, h: window.innerHeight });
    measure();
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, []);

  // Freeze `now`/`year` at mount — the backdrop is decorative, so no per-minute tick.
  const { now, year, focus } = useMemo(() => {
    const d = new Date();
    return { now: d.getTime(), year: d.getFullYear(), focus: d.getMonth() };
  }, []);

  const items = useMemo(() => {
    if (vp.w === 0) return null;
    // buildScene(z, focus, week, vp, scrollY, hover, now, year, altDeltaHours, altLabel, tlScroll)
    const scene = buildScene(VIEW_Z, focus, 0, vp, 0, NO_HOVER, now, year, null, null, 0);
    // Drop the month-name label that sits in the far-left gutter — it's calendar chrome, not
    // grid texture, and reads as a stray box behind the card. Everything else stays.
    return scene.items.filter((it) => it.kind !== "monthLabel");
  }, [vp, focus, now, year]);

  if (!items) return null;

  // Structural positioning is set inline so it always beats .cc-wrap's `position: relative`
  // (both are single-class rules; bundle import order between the calendar CSS and dashboard.css
  // isn't guaranteed). Visual tuning (opacity, mask) stays in .auth-backdrop.
  return (
    <div
      className="cc-wrap auth-backdrop"
      aria-hidden="true"
      style={{ position: "fixed", inset: 0, zIndex: 0, pointerEvents: "none" }}
    >
      {items.map((it) => (
        <ItemView key={it.key} it={it} />
      ))}
    </div>
  );
}
