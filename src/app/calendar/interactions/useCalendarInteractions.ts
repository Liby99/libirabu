// ─────────────────────────────────────────────────────────────────────────────
// useCalendarInteractions — the calendar's gesture + view-state engine.
//
// Owns ALL view state (zoom scalar z, focused month/week/day, scroll offsets, hover)
// and the gesture machinery that drives it. The exported hook is the single source of
// truth that CalendarCanvas reads from; the geometry layer turns this state into pixels.
//
// Layout of this (large) file, top to bottom:
//   • tuning constants (paging fractions, overscroll thresholds, animation durations)
//   • URL state parsing + hook setup (refs, ResizeObserver, initial scroll)
//   • tween/snap helpers (cancelTween, snapMonth, snapDayPage, tweenWeek, tweenTo…)
//   • cross-month / cross-year choreographies (jumpMonth, jumpYear, jumpYearFlat)
//   • pinch-zoom handlers (Safari gesture events)
//   • the onWheel handler — 5 parallel gesture subsystems (year scroll, month paging,
//     week paging, daily paging, timeline scroll), each with its own threshold + lockout
//   • hover tracking (mousemove) and click handling
//   • the returned state + methods
//
// Most of the magic numbers here are interaction TUNING and deliberately live beside the
// code they tune; shared LAYOUT numbers come from ../geometry/constants instead.
// ─────────────────────────────────────────────────────────────────────────────
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Vp, Hover } from "../geometry/types";
import { easeInOut, TOP_PAD, TRACK_H, LABEL_W, BAR_H } from "../geometry/constants";
import { yearMaxScroll, yearFrame, frameFor, getDailyFrac, MonthAnim, DayAnim } from "../geometry/frames";
import { hourMetrics, clampHourH, setWeekHourH as syncWeekHourH } from "../geometry/eventGeom";
import { weeksInMonth, weekStartDOM, weekOfDate, resolveDate } from "../util/dates";
import {
  monthAtPoint, monthNameAtPoint, monthRowAtPoint, weekAtPointInMonth,
  domInMonthBand, domInFocus, cellInWeek,
} from "../geometry/hittest";

// Vertical month paging (gesture-tracked). The drag distance that equals one full page is
// `viewportHeight * MONTH_PAGE_FRAC` (floored at MONTH_PAGE_MIN px); releasing past
// MONTH_COMMIT_P of a page (or with momentum carrying it there) turns the month, else it snaps back.
const MONTH_PAGE_FRAC = 0.62;
const MONTH_PAGE_MIN = 280;
const MONTH_COMMIT_P = 0.4;

// Daily view: the day timeline's width as a fraction of the content area (rest = dashboard).
// Min = the weekly day width (content / 7); max ≈ 60% of the content. Persisted across sessions.
const DAILY_FRAC_MIN = 1 / 7;
const DAILY_FRAC_MAX = 0.6;
const DAILY_FRAC_KEY = "cc-daily-frac";
const clampDailyFrac = (f: number) => Math.max(DAILY_FRAC_MIN, Math.min(DAILY_FRAC_MAX, f));
function readDailyFrac(): number {
  if (typeof window === "undefined") return 0.45;
  const v = parseFloat(window.localStorage.getItem(DAILY_FRAC_KEY) ?? "");
  return Number.isFinite(v) ? clampDailyFrac(v) : 0.45;
}

const NO_HOVER: Hover = { month: null, dom: null, week: null, hour: null, hourFrac: null, nameMonth: null, nearLeft: null };
const sameHover = (a: Hover, b: Hover) =>
  a.month === b.month && a.dom === b.dom && a.week === b.week && a.hour === b.hour &&
  a.hourFrac === b.hourFrac && a.nameMonth === b.nameMonth && a.nearLeft === b.nearLeft;

// Safari's GestureEvent isn't in the standard DOM lib types.
type GestureLikeEvent = { scale: number; clientX: number; clientY: number; preventDefault: () => void };

// True while an event drawer is open (CalendarCanvas toggles this class on <body>). The
// canvas freezes its scroll/zoom gestures then, so the masked calendar can't move underneath.
const drawerOpen = () => typeof document !== "undefined" && document.body.classList.contains("cc-drawer-open");
// A unified <Dialog> (confirm / Help / …) is open → the canvas must be inert (no zoom/scroll/keys).
const dialogOpen = () => typeof document !== "undefined" && document.body.classList.contains("ui-dialog-open");

// ── URL state (year / view level / month / week) ───────────────────────────
// The calendar position is mirrored in the query string so a refresh restores it:
//   year view → ?y=2026 · month view → ?y=2026&m=7 · week view → ?y=2026&m=7&w=2
// `m` is 1–12 and `w` is 1-based (matching the breadcrumb labels); the level is inferred
// from which params are present (w → week, m → month, else year).
interface UrlState { year: number; focus: number; week: number; z: number; dailyDom: number }
function readUrlState(): UrlState {
  const now = new Date();
  const def: UrlState = { year: now.getFullYear(), focus: now.getMonth(), week: 0, z: 0, dailyDom: 1 };
  if (typeof window === "undefined") return def;
  const p = new URLSearchParams(window.location.search);
  const y = parseInt(p.get("y") ?? "", 10);
  const m = parseInt(p.get("m") ?? "", 10);
  const w = parseInt(p.get("w") ?? "", 10);
  const d = parseInt(p.get("d") ?? "", 10); // day offset 0–6 within the week (the window slides per-day)
  const da = parseInt(p.get("da") ?? "", 10); // daily view: the chosen day-of-month
  const hasM = Number.isFinite(m) && m >= 1 && m <= 12;
  const hasW = hasM && Number.isFinite(w) && w >= 1;
  const hasDa = hasW && Number.isFinite(da);
  const dayOff = Number.isFinite(d) ? Math.min(6, Math.max(0, d)) : 0;
  return {
    year: Number.isFinite(y) ? y : def.year,
    focus: hasM ? m - 1 : def.focus,
    week: hasW ? Math.min(5, w - 1) + dayOff / 7 : 0, // a month spans ≤6 week-rows (index 0–5) + day offset
    z: hasDa ? 3 : hasW ? 2 : hasM ? 1 : 0,
    dailyDom: hasDa ? da : 1,
  };
}

// Owns all zoom/pan/scroll state and the gesture handling: pinch-zoom (Safari
// gesture events), iPhone-style horizontal week paging, vertical year scroll,
// click-to-open, and the tween/snap animations.
export function useCalendarInteractions() {
  const wrapRef = useRef<HTMLDivElement>(null);
  // Parse the URL once, on mount, for the initial view position.
  const initRef = useRef<UrlState | null>(null);
  if (initRef.current === null) initRef.current = readUrlState();
  const init = initRef.current;
  const [vp, setVp] = useState<Vp>({ w: 0, h: 0 });
  const [z, setZ] = useState(init.z);
  const [focus, setFocus] = useState(init.focus);
  const [week, setWeek] = useState(init.week);
  const [scrollY, setScrollY] = useState(0);
  const [tlScroll, setTlScroll] = useState(0); // week-view timeline vertical scroll
  const [weekHourH, setWeekHourHState] = useState(60); // week-view per-hour height (slider)
  syncWeekHourH(weekHourH); // keep the module value (read by hourMetrics) in sync
  const setWeekHourH = useCallback((h: number) => setWeekHourHState(clampHourH(h)), []);
  const [hoverMonth, setHoverMonth] = useState<number | null>(null);
  const [hoverWeek, setHoverWeek] = useState<number | null>(null);
  const [hover, setHover] = useState<Hover>(NO_HOVER);
  const [now, setNow] = useState(() => Date.now());
  const [year, setYearState] = useState(init.year);
  const currentYear = new Date().getFullYear();
  // Vertical month↕month paging (month view): the active slide, + a 0–1 timeline-opacity
  // multiplier (1 idle; fades to 0 mid-slide; fades back to 1 as the new month's timeline appears).
  const [monthAnim, setMonthAnim] = useState<MonthAnim | null>(null);
  const [detailMul, setDetailMul] = useState(1);
  // Daily view (z=3): the chosen day (focus-relative day-of-month) + the fraction of the content
  // area its timeline occupies (rest is the daily-dashboard; later user-resizable).
  const [dailyDom, setDailyDom] = useState(init.dailyDom);
  const [dayAnim, setDayAnim] = useState<DayAnim | null>(null); // daily↔daily slide in flight
  // Overscroll at a month boundary (daily/week view): {dir, t} where t 0→1 is how hard you're
  // pushing past the edge; at t≥1 a release jumps to the next/prev month. Drives the edge prompt.
  const [monthEdge, setMonthEdge] = useState<{ dir: 1 | -1; t: number } | null>(null);
  // Yearly view (z≈0) year-jump crossfade: the whole grid's opacity (1 idle; fades to 0, swaps the
  // year + scroll, fades back to 1). Distinct from the month-view jump's zoom-out/in choreography.
  const [yearFade, setYearFade] = useState(1);
  const yearFadeRef = useRef<number | null>(null);
  const [dailyFrac, setDailyFracState] = useState(readDailyFrac);
  const setDailyFrac = useCallback((f: number) => {
    const c = clampDailyFrac(f);
    setDailyFracState(c);
    try { window.localStorage.setItem(DAILY_FRAC_KEY, String(c)); } catch { /* storage unavailable */ }
  }, []);
  const dailyDomRef = useRef(dailyDom); dailyDomRef.current = dailyDom;
  const pinchDayRef = useRef<number | null>(null); // day under the cursor when a week→day pinch starts (locked so the morph can't drift it)

  const zRef = useRef(z); zRef.current = z;
  const yearRef = useRef(year); yearRef.current = year;
  const focusRef = useRef(focus); focusRef.current = focus;
  const weekRef = useRef(week); weekRef.current = week;
  const scrollYRef = useRef(scrollY); scrollYRef.current = scrollY;
  const tlScrollRef = useRef(tlScroll); tlScrollRef.current = tlScroll;
  const hoverMonthRef = useRef(hoverMonth); hoverMonthRef.current = hoverMonth;
  const hoverWeekRef = useRef(hoverWeek); hoverWeekRef.current = hoverWeek;
  const hoverRef = useRef(hover); hoverRef.current = hover;
  const lastPtRef = useRef<{ x: number; y: number } | null>(null);
  const tweenRef = useRef<number | null>(null);
  const weekTweenRef = useRef<number | null>(null);
  const snapRef = useRef<number | null>(null);
  const monthTweenRef = useRef<number | null>(null);
  const monthAnimRef = useRef(monthAnim); monthAnimRef.current = monthAnim;
  const monthSnapRef = useRef(false); // true while a release-snap tween (and its timeline fade) is running
  const dayTweenRef = useRef<number | null>(null); // daily↔daily release-snap tween in flight
  const dayAnimRef = useRef(dayAnim); dayAnimRef.current = dayAnim;
  const daySnapRef = useRef(false); // true while a daily release-snap is running

  // measure the viewport
  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setVp({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    setVp({ w: el.clientWidth, h: el.clientHeight });
    return () => ro.disconnect();
  }, []);

  // On launch in a month/week/day view, set the year scroll so a zoom-out shows the focused month
  // (not the top). Runs once, after the viewport is measured. (Invisible until you zoom out — the
  // month-view band positions don't depend on scrollY.)
  const didInitScrollRef = useRef(false);
  useEffect(() => {
    if (didInitScrollRef.current || vp.h === 0) return;
    didInitScrollRef.current = true;
    if (init.z > 0) {
      const off = yearFrame(init.focus, vp, 0).bandY - TOP_PAD; // the focus month's year-view offset
      const max = yearMaxScroll(vp);
      setScrollY(Math.max(0, Math.min(max, off - (vp.h - TOP_PAD) * 0.3))); // place it ~30% down with context above
    }
  }, [vp.h, init.z, init.focus]);

  const clearSnap = () => { if (snapRef.current != null) { clearTimeout(snapRef.current); snapRef.current = null; } };
  const cancelTween = () => { if (tweenRef.current != null) cancelAnimationFrame(tweenRef.current); tweenRef.current = null; };
  const cancelWeekTween = () => { if (weekTweenRef.current != null) cancelAnimationFrame(weekTweenRef.current); weekTweenRef.current = null; };
  const cancelMonthTween = () => {
    if (monthTweenRef.current != null) cancelAnimationFrame(monthTweenRef.current);
    monthTweenRef.current = null;
    monthSnapRef.current = false;
    setMonthAnim(null);
    setDetailMul(1);
  };

  // Vertical month paging is GESTURE-TRACKED: the wheel handler drives monthAnim.p directly so
  // the bands follow the scroll (iPhone-homescreen feel). On release, snapMonth eases p to its
  // resting state — → 1 commits to focus+dir, → 0 cancels back to focus. `fromP` is the live drag
  // progress at release; `dur` is velocity-matched by the caller (a slow drag snaps slowly). Uses
  // ease-OUT (start at the release speed, decelerate to rest) so there's no acceleration on release.
  // The incoming month's detail has already cross-faded in during the drag/snap (see the layers),
  // so commit just lands focus at full detail — no post-settle fade-in delay.
  const snapMonth = useCallback((dir: 1 | -1, fromP: number, commit: boolean, dur: number, onComplete?: () => void) => {
    if (monthTweenRef.current != null) cancelAnimationFrame(monthTweenRef.current);
    const to = focusRef.current + dir;
    const canCommit = commit && to >= 0 && to <= 11;
    const target = canCommit ? 1 : 0;
    const finalize = () => {
      setMonthAnim(null);
      monthAnimRef.current = null;
      monthTweenRef.current = null;
      monthSnapRef.current = false;
      if (canCommit) { focusRef.current = to; setFocus(to); setDetailMul(1); } // land at full detail (already faded in)
      else setDetailMul(1); // cancelled → restore the original month's detail
      onComplete?.();
    };
    // Already at the target (e.g. a strong swipe that dragged the band fully to the edge) → commit
    // synchronously so focus/hover come alive at once instead of waiting out an empty tween.
    if (Math.abs(target - fromP) < 0.005) { finalize(); return; }
    monthSnapRef.current = true;
    const DUR = Math.max(80, dur);
    const easeOut = (k: number) => 1 - Math.pow(1 - k, 3);
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const k = DUR > 0 ? Math.min(1, (ts - t0) / DUR) : 1;
      const p = fromP + (target - fromP) * easeOut(k);
      setMonthAnim({ dir, p });
      setDetailMul(1 - Math.min(1, p / 0.35));
      if (k < 1) { monthTweenRef.current = requestAnimationFrame(step); return; }
      finalize();
    };
    monthTweenRef.current = requestAnimationFrame(step);
  }, []);

  // Daily↔daily paging is GESTURE-TRACKED: the wheel handler drives dayAnim.p directly (the day
  // column slides 1:1 with the swipe). On release, snapDay eases p to its resting state — → 1 commits
  // to the next/prev day, → 0 cancels back. The current day slides + fades out while the next slides
  // + fades in (timed events/deadlines cross-fade, all-day band events just slide); the dashboard
  // dip-fades. Committing across a month re-bases focus/week + the year scroll (correct on zoom-out).
  // Clamped at Jan 1 / Dec 31. `fromP` is the live progress at release; `dur` is velocity-matched.
  const snapDayPage = useCallback((dir: 1 | -1, fromP: number, commit: boolean, dur: number) => {
    if (dayTweenRef.current != null) cancelAnimationFrame(dayTweenRef.current);
    const dom = dailyDomRef.current + dir;
    const dimOf = (m: number) => new Date(yearRef.current, m + 1, 0).getDate();
    // Clamp at the MONTH boundary — crossing into the next/prev month is the month-jump choreography
    // (overscroll → zoom out → page month → zoom into first/last day), not a plain day slide.
    const canCommit = commit && dom >= 1 && dom <= dimOf(focusRef.current);
    const target = canCommit ? 1 : 0;
    const finalize = () => {
      daySnapRef.current = false;
      dayTweenRef.current = null;
      if (canCommit) {
        dailyDomRef.current = dom; setDailyDom(dom);
        const wk = weekOfDate(focusRef.current, dom); // keep the week-level focus on the day's week (so a zoom-out lands right)
        weekRef.current = wk; setWeek(wk);
      }
      setDayAnim(null); // settle: incoming day is now the focused day (or cancelled back)
    };
    if (Math.abs(target - fromP) < 0.005) { finalize(); return; }
    daySnapRef.current = true;
    const DUR = Math.max(80, dur);
    const easeOut = (k: number) => 1 - Math.pow(1 - k, 3);
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const k = DUR > 0 ? Math.min(1, (ts - t0) / DUR) : 1;
      setDayAnim({ dir, p: fromP + (target - fromP) * easeOut(k) });
      if (k < 1) { dayTweenRef.current = requestAnimationFrame(step); return; }
      finalize();
    };
    dayTweenRef.current = requestAnimationFrame(step);
  }, []);

  const tweenWeek = useCallback((target: number, dur = 240) => {
    cancelWeekTween();
    const start = weekRef.current;
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const p = Math.min(1, (ts - t0) / dur);
      setWeek(start + (target - start) * easeInOut(p));
      if (p < 1) weekTweenRef.current = requestAnimationFrame(step);
      else weekTweenRef.current = null;
    };
    weekTweenRef.current = requestAnimationFrame(step);
  }, []);

  const tweenTo = useCallback((targetZ: number, dur = 520, onComplete?: () => void) => {
    cancelTween(); clearSnap(); cancelMonthTween();
    const startZ = zRef.current;
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const p = Math.min(1, (ts - t0) / dur);
      setZ(startZ + (targetZ - startZ) * easeInOut(p));
      if (p < 1) tweenRef.current = requestAnimationFrame(step);
      else { tweenRef.current = null; onComplete?.(); }
    };
    tweenRef.current = requestAnimationFrame(step);
  }, []);

  // Navigate to a month (month view) — used by the drawer's "Go to first event".
  const goToMonth = useCallback((m: number) => { setFocus(m); tweenTo(1); }, [tweenTo]);

  // Cross-month jump (from daily or week view, on an overscroll commit at the month boundary): a
  // 3-stage choreography — zoom out to month → vertical month-page slide → zoom back in, landing on
  // the first day/week of the next month (or the last of the prev). Clamped at the year boundary.
  const jumpMonth = useCallback((dir: 1 | -1) => {
    const tMonth = focusRef.current + dir;
    if (tMonth < 0 || tMonth > 11) return; // year boundary — no jump
    const lvl = zRef.current >= 2.5 ? 3 : 2; // return to daily (3) or week (2)
    const tDay = dir > 0 ? 1 : new Date(yearRef.current, tMonth + 1, 0).getDate(); // first / last day
    const tWeek = dir > 0 ? 0 : weeksInMonth(tMonth) - 1;                            // first / last week
    setMonthEdge(null);
    setDayAnim(null);
    // Deliberately gradual + layered: zoom out, (pause) page the month, (pause) zoom back in.
    tweenTo(1, 760, () => {                 // Stage 1: zoom out to month view (daily → week → month)
      window.setTimeout(() => {
        snapMonth(dir, 0, true, 880, () => { // Stage 2: page (slide) to the target month
          window.setTimeout(() => {
            // Stage 3: set BOTH the target week and day BEFORE zooming in — the zoom passes through the
            // week layer (z 1→2) then the day layer (z 2→3), so the week must point at the target day's
            // week or the zoom-in starts at the stale (last) week and snaps over to the target day.
            weekRef.current = tWeek; setWeek(tWeek);
            if (lvl === 3) { dailyDomRef.current = tDay; setDailyDom(tDay); }
            tweenTo(lvl, 820);
          }, 170);
        });
      }, 140);
    });
  }, [tweenTo, snapMonth]);

  // Cross-year jump (month view, on an overscroll commit at Dec/Jan): zoom out to the yearly view,
  // hold ~0.5s, swap the year + land on the target month (Jan for next, Dec for prev) with the year
  // scrolled to show it, hold ~0.5s, then zoom back into that month.
  const jumpYear = useCallback((dir: 1 | -1) => {
    setMonthEdge(null);
    setMonthAnim(null); setDetailMul(1);
    const tMonth = dir > 0 ? 0 : 11; // next year → January · prev year → December
    tweenTo(0, 620, () => {                       // 1. zoom out to yearly view
      window.setTimeout(() => {                   // 2. hold ~0.5s
        setYearState(yearRef.current + dir); yearRef.current += dir; // 3. swap year
        focusRef.current = tMonth; setFocus(tMonth);
        const el = wrapRef.current;
        if (el) { // scroll the new year so the target month is in view (for the zoom-in)
          const vpNow = { w: el.clientWidth, h: el.clientHeight };
          const off = yearFrame(tMonth, vpNow, 0).bandY - TOP_PAD;
          const max = yearMaxScroll(vpNow);
          const sy = Math.max(0, Math.min(max, off - (vpNow.h - TOP_PAD) * 0.3));
          scrollYRef.current = sy; setScrollY(sy);
        }
        window.setTimeout(() => tweenTo(1, 640), 500); // 4. hold ~0.5s → 5. zoom into the month
      }, 500);
    });
  }, [tweenTo]);

  // Cross-year jump while already in the yearly view (z≈0): no zoom to spend, so cross-fade instead —
  // fade the grid out, swap the year + scroll to the far edge (top for next, bottom for prev), hold,
  // fade back in. Same overscroll trigger as the month-view jump, different (flat) animation.
  const jumpYearFlat = useCallback((dir: 1 | -1) => {
    setMonthEdge(null);
    if (yearFadeRef.current != null) cancelAnimationFrame(yearFadeRef.current);
    const fade = (from: number, to: number, dur: number, done?: () => void) => {
      let t0 = 0;
      const step = (ts: number) => {
        if (!t0) t0 = ts;
        const p = Math.min(1, (ts - t0) / dur);
        setYearFade(from + (to - from) * easeInOut(p));
        if (p < 1) yearFadeRef.current = requestAnimationFrame(step);
        else { yearFadeRef.current = null; done?.(); }
      };
      yearFadeRef.current = requestAnimationFrame(step);
    };
    fade(1, 0, 360, () => {                       // 1. fade the grid out
      setYearState(yearRef.current + dir); yearRef.current += dir; // 2. swap year
      const el = wrapRef.current;
      if (el) {                                   //    land at the edge the jump arrives from
        const max = yearMaxScroll({ w: el.clientWidth, h: el.clientHeight });
        const sy = dir > 0 ? 0 : max;             // next → top (January) · prev → bottom (December)
        scrollYRef.current = sy; setScrollY(sy);
      }
      window.setTimeout(() => fade(0, 1, 420), 220); // 3. brief hold → 4. fade back in
    });
  }, []);

  // Snap z to the nearest level and (at week level) the week to the nearest DAY (the 7-day
  // window slides per-day; 1 week = 7 days, clamped to the first/last week's spillover edges).
  const snapNow = useCallback(() => {
    clearSnap();
    const zt = Math.max(0, Math.min(3, Math.round(zRef.current)));
    if (Math.abs(zt - zRef.current) > 0.004) tweenTo(zt, 260);
    if (Math.round(zRef.current) === 2) {
      const lastWeek = weeksInMonth(focusRef.current) - 1;
      const wt = Math.max(0, Math.min(lastWeek, Math.round(weekRef.current * 7) / 7));
      if (Math.abs(wt - weekRef.current) > 0.004) tweenWeek(wt, 260);
    }
  }, [tweenTo, tweenWeek]);

  // Safari trackpad PINCH → zoom (native gesture events; e.scale is cumulative).
  // Snap only on gestureend, with an idle fallback in case Safari drops it.
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    let startZ = 0, cx = 0, cy = 0, idle = 0;
    const arm = () => { clearTimeout(idle); idle = window.setTimeout(() => { idle = 0; snapNow(); }, 240); };
    const onStart = (e: GestureLikeEvent) => {
      e.preventDefault();
      if (drawerOpen() || dialogOpen()) return; // a drawer or modal dialog is open → freeze the canvas (zoom disabled)
      cancelTween(); cancelWeekTween(); clearSnap();
      startZ = zRef.current;
      const rect = el.getBoundingClientRect();
      cx = e.clientX - rect.left; cy = e.clientY - rect.top;
      pinchDayRef.current = hoverRef.current.dom; // lock the day under the cursor now (week→day pinch)
      arm();
    };
    const onChange = (e: GestureLikeEvent) => {
      e.preventDefault();
      if (drawerOpen() || dialogOpen()) return;
      const vpNow = { w: el.clientWidth, h: el.clientHeight };
      const nz = Math.max(0, Math.min(3, startZ + Math.log2(e.scale) * 0.6)); // lower = slower
      // Lock focus/week/day once, based on the level we STARTED at + the gesture origin.
      if (nz > startZ && startZ < 0.15) {
        const m = monthAtPoint(cx, cy, vpNow, scrollYRef.current);
        if (m != null) setFocus(m);
      } else if (nz > startZ && startZ >= 0.85 && startZ < 1.15) {
        const w = weekAtPointInMonth(cx, focusRef.current, vpNow);
        if (w != null) setWeek(w);
      } else if (nz > startZ && startZ >= 1.85 && startZ < 2.15) {
        // zooming week → day: lock onto the day captured at gesturestart (fixed — the morph must not
        // drift the target, or the zoom stutters). Fall back to the middle of the week. Spillover days
        // (in the prev/next month) are NOT zoomable — clamp the target into the focused month's range.
        const dim = new Date(yearRef.current, focusRef.current + 1, 0).getDate();
        const raw = pinchDayRef.current ?? weekStartDOM(focusRef.current, Math.round(weekRef.current)) + 3;
        setDailyDom(Math.max(1, Math.min(dim, raw)));
      }
      setZ(nz);
      arm();
    };
    const onEnd = (e: GestureLikeEvent) => { e.preventDefault(); clearTimeout(idle); idle = 0; snapNow(); };
    const a = el as unknown as {
      addEventListener: (t: string, h: (e: GestureLikeEvent) => void) => void;
      removeEventListener: (t: string, h: (e: GestureLikeEvent) => void) => void;
    };
    a.addEventListener("gesturestart", onStart);
    a.addEventListener("gesturechange", onChange);
    a.addEventListener("gestureend", onEnd);
    return () => {
      clearTimeout(idle);
      a.removeEventListener("gesturestart", onStart);
      a.removeEventListener("gesturechange", onChange);
      a.removeEventListener("gestureend", onEnd);
    };
  }, [snapNow]);

  // Wheel: vertical scroll in year view; horizontal day-sliding in week view (the 7-day
  // window follows the swipe freely and snaps to the nearest DAY on settle, so a small swipe
  // shifts by a day rather than snapping back to the week).
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    let session = false, pos = 0; // pos = live (fractional) week index during a swipe
    let idleTimer = 0;
    // week-view month-boundary overscroll (mirrors the daily one): push past the first/last week →
    // ring fills (wOverPx vs threshold), hold, then jump to the prev/next month's first/last week.
    let wOver = false, wOverDir: 1 | -1 = 1, wOverPx = 0, wHold = 0, wLock = false, wLastWheelT = 0;
    let wStartEdge: 0 | 1 | -1 = 0; // edge the CURRENT swipe began at (1 last week · -1 first week · 0 mid-month) — only an at-edge start may overscroll
    // month-view vertical drag: signed pixels accumulated this gesture (>0 → next month, <0 → prev),
    // plus a smoothed velocity (px/ms) so the release snap can match the drag speed. `mLockout`
    // swallows the trackpad's momentum tail after a gesture ends (so it neither re-pages nor holds
    // the turn open — hover comes back at once); `mLastWheelT` detects the pause that ends lockout.
    let mDragging = false, mDrag = 0, mIdle = 0, mVel = 0, mLastT = 0, mLockout = false, mLastWheelT = 0, mDecay = 0;
    let yOver = false, yOverDir: 1 | -1 = 1, yOverPx = 0, yHold = 0; // year-boundary overscroll (Dec↓ / Jan↑) → year-jump
    let yIdle = 0, yLock = false, yLastWheelT = 0; // yearly-view overscroll: release timer + post-commit momentum lockout
    let yStartEdge: 0 | 1 | -1 = 0; // edge the CURRENT gesture began at (1 bottom · -1 top · 0 middle) — only an at-edge start may overscroll
    // daily↔daily horizontal paging: GESTURE-TRACKED like month paging but horizontal. `dDrag` is
    // signed px this gesture; one full page = one day-column width, so the slide tracks the swipe 1:1.
    let dDragging = false, dDrag = 0, dIdle = 0, dVel = 0, dLastT = 0, dLockout = false, dDecay = 0, dLastWheelT = 0;
    let dOver = false, dOverDir: 1 | -1 = 1, dOverT = 0, dHold = 0; // overscroll at a month boundary → month-jump
    const dayPageDist = () => Math.max(80, getDailyFrac() * (el.clientWidth - LABEL_W)); // = the day column width
    const dimOfYear = (m: number) => new Date(yearRef.current, m + 1, 0).getDate();
    const DAY_OVER_THRESH = 320; // px of sustained push past the month edge to commit a month-jump
    const MONTH_HOLD = 320;      // ms the ring stays full after reaching the threshold before it commits
    const commitMonthJump = () => { const dir = dOverDir; dHold = 0; dOver = false; dOverT = 0; dDrag = 0; dVel = 0; clearTimeout(dIdle); jumpMonth(dir); };
    // Reaching the threshold arms a brief hold (a beat at full ring) before committing; pulling back
    // below the threshold cancels it.
    const armHold = () => {
      if (dOverT >= 1) { if (!dHold) dHold = window.setTimeout(commitMonthJump, MONTH_HOLD); }
      else if (dHold) { clearTimeout(dHold); dHold = 0; }
    };
    // Gesture released (wheel idle): snap the live drag to commit (past 40%) or cancel.
    const endDayDrag = () => {
      if (!dDragging) return;
      dDragging = false;
      dLockout = true; dDecay = Infinity; // swallow the momentum tail until the wheel goes quiet
      if (dOver) { // released while overscrolling the month boundary
        if (dHold) return; // threshold reached → the hold timer will commit shortly; leave the ring up
        const dir = dOverDir, from = dOverT;
        dOver = false; dOverT = 0; dDrag = 0; dVel = 0;
        // spring the overscroll (ring + page bounce) back to rest
        if (dayTweenRef.current != null) cancelAnimationFrame(dayTweenRef.current);
        let t0 = 0;
        const spring = (ts: number) => {
          if (!t0) t0 = ts;
          const k = Math.min(1, (ts - t0) / 180);
          if (k < 1) { setMonthEdge({ dir, t: from * Math.pow(1 - k, 3) }); dayTweenRef.current = requestAnimationFrame(spring); }
          else { setMonthEdge(null); dayTweenRef.current = null; }
        };
        dayTweenRef.current = requestAnimationFrame(spring);
        return;
      }
      const PAGE = dayPageDist();
      const norm = dDrag / PAGE;
      dDrag = 0;
      const p = Math.min(1, Math.abs(norm));
      if (p < 0.001) { setDayAnim(null); dVel = 0; return; }
      const commit = p >= 0.4;
      const remPx = Math.abs((commit ? 1 : 0) - p) * PAGE;
      const speed = Math.abs(dVel);
      const dur = speed > 0.02 ? Math.max(150, Math.min(520, remPx / speed)) : 360;
      dVel = 0;
      snapDayPage(norm >= 0 ? 1 : -1, p, commit, dur);
    };
    const lastIdx = () => weeksInMonth(focusRef.current) - 1;
    // Nearest day boundary (1 week = 7 days), clamped to the first/last week (incl. spillover).
    const snapDay = (w: number) => Math.max(0, Math.min(lastIdx(), Math.round(w * 7) / 7));
    // Week overscroll: commit the month-jump after the hold; arm/cancel the hold by the threshold.
    const WEEK_OVER_THRESH = 560; // px of sustained push past the week edge to commit (less sensitive than daily)
    const commitWeekJump = () => { const dir = wOverDir; wHold = 0; wOver = false; wOverPx = 0; session = false; wLock = true; clearTimeout(idleTimer); jumpMonth(dir); };
    const armWeekHold = () => {
      const t = Math.min(1, Math.abs(wOverPx) / WEEK_OVER_THRESH);
      if (t >= 1) { if (!wHold) wHold = window.setTimeout(commitWeekJump, MONTH_HOLD); }
      else if (wHold) { clearTimeout(wHold); wHold = 0; }
    };
    const endSession = () => {
      if (wOver) { // released while overscrolling a month boundary
        if (wHold) { session = false; return; } // threshold reached → the hold timer will commit; leave the ring
        const target = wOverDir > 0 ? lastIdx() : 0;
        wOver = false; wOverPx = 0; session = false; setMonthEdge(null);
        tweenWeek(target, 200); // spring the week window back to the boundary
        return;
      }
      if (!session) return;
      session = false;
      const target = snapDay(pos);
      if (Math.abs(target - pos) > 0.0005) tweenWeek(target, 200); else setWeek(target);
    };
    const pageDist = () => Math.max(MONTH_PAGE_MIN, el.clientHeight * MONTH_PAGE_FRAC);
    // Year-boundary overscroll (month view): commit the year-jump after the hold; arm/cancel by threshold.
    const YEAR_OVER_THRESH = 320;
    const commitYearJump = () => {
      const dir = yOverDir; yHold = 0; yOver = false; yOverPx = 0;
      mDragging = false; mLockout = true; clearTimeout(mIdle);
      yLock = true; clearTimeout(yIdle); // swallow the wheel's momentum tail after the jump
      if (zRef.current < 0.5) jumpYearFlat(dir); else jumpYear(dir); // yearly: crossfade · month: zoom
    };
    const armYearHold = () => {
      const t = Math.min(1, Math.abs(yOverPx) / YEAR_OVER_THRESH);
      if (t >= 1) { if (!yHold) yHold = window.setTimeout(commitYearJump, MONTH_HOLD); }
      else if (yHold) { clearTimeout(yHold); yHold = 0; }
    };
    // Yearly-view overscroll released (wheel idle): commit if the hold armed, else spring back.
    const endYearDrag = () => {
      if (!yOver) return;
      if (yHold) return; // threshold held → the hold timer commits
      yOver = false; yOverPx = 0; setMonthEdge(null);
    };
    // Gesture released (wheel idle): snap the live drag to commit or cancel.
    const endMonthDrag = () => {
      if (!mDragging) return;
      mDragging = false;
      mLockout = true; mDecay = Infinity; // arm: ignore the trailing momentum until the wheel goes quiet
      if (yOver) { // released while overscrolling a year boundary
        if (yHold) return; // threshold reached → the hold timer will commit; leave the ring up
        yOver = false; yOverPx = 0; setMonthEdge(null); // spring back (no band moved → just clear)
        return;
      }
      const PAGE = pageDist();
      const norm = mDrag / PAGE;
      mDrag = 0;
      const p = Math.min(1, Math.abs(norm));
      if (p < 0.001) { setMonthAnim(null); setDetailMul(1); mVel = 0; return; } // never really moved
      const commit = p >= MONTH_COMMIT_P;
      const dir: 1 | -1 = norm >= 0 ? 1 : -1;
      const to = focusRef.current + dir;
      // On a real page-turn, shift the YEAR scroll by the year-view distance between the months, so
      // zooming back out lands on the month we paged TO — not the one we zoomed in from. (Invisible
      // in month view, where band positions don't depend on scrollY.)
      if (commit && to >= 0 && to <= 11) {
        const vpNow = { w: el.clientWidth, h: el.clientHeight };
        const delta = yearFrame(to, vpNow, 0).bandY - yearFrame(focusRef.current, vpNow, 0).bandY;
        const max = yearMaxScroll(vpNow);
        setScrollY((s) => Math.max(0, Math.min(max, s + delta)));
      }
      // Match the snap speed to the release velocity (slow drag → slow snap), capped to a sane range.
      const remPx = Math.abs((commit ? 1 : 0) - p) * PAGE;
      const speed = Math.abs(mVel); // px/ms at release
      const dur = speed > 0.02 ? Math.max(180, Math.min(660, remPx / speed)) : 560;
      mVel = 0;
      snapMonth(dir, p, commit, dur);
    };
    const onWheel = (e: WheelEvent) => {
      if (e.ctrlKey) return; // pinch handled via gesture events
      if (drawerOpen() || dialogOpen()) return; // a drawer or modal dialog is open → freeze the canvas (scroll/zoom disabled)
      if (zRef.current < 0.5 && Math.abs(e.deltaY) >= Math.abs(e.deltaX)) {
        e.preventDefault();
        const gap = yLastWheelT ? e.timeStamp - yLastWheelT : 999;
        yLastWheelT = e.timeStamp;
        if (yLock) { if (gap >= 120) yLock = false; else return; } // swallow momentum tail post-jump
        const max = yearMaxScroll({ w: el.clientWidth, h: el.clientHeight });
        const cur = scrollYRef.current;
        const atBottom = cur >= max - 0.5, atTop = cur <= 0.5;
        // A pause (gap) marks the start of a fresh gesture: remember whether we BEGIN at an edge.
        // Only a gesture that starts already at the edge may overscroll into a year-jump — a scroll
        // that merely runs into the edge mid-gesture just stops there (no jump).
        if (gap >= 180) yStartEdge = atBottom ? 1 : atTop ? -1 : 0;
        const canOver = (yStartEdge === 1 && atBottom && e.deltaY > 0) || (yStartEdge === -1 && atTop && e.deltaY < 0);
        if (canOver) {
          yOver = true; yOverDir = e.deltaY > 0 ? 1 : -1; yOverPx += e.deltaY;
          setMonthEdge({ dir: yOverDir, t: Math.min(1, Math.abs(yOverPx) / 320) });
          armYearHold();
          clearTimeout(yIdle); yIdle = window.setTimeout(endYearDrag, 80);
          return;
        }
        if (yOver) { yOver = false; yOverPx = 0; if (yHold) { clearTimeout(yHold); yHold = 0; } setMonthEdge(null); } // pulled back inside the year
        setScrollY(Math.max(0, Math.min(max, cur + e.deltaY)));
        return;
      }
      // month view: vertical wheel pages months as vertical pages, GESTURE-TRACKED — the bands
      // follow the scroll (scroll down/swipe up → next month, up → prev) and snap on release
      // (wheel idle). Clamped at Jan/Dec (no wrap).
      if (zRef.current >= 0.5 && zRef.current < 1.5 && Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
        e.preventDefault();
        const gap = mLastWheelT ? e.timeStamp - mLastWheelT : 999;
        mLastWheelT = e.timeStamp;
        // Post-gesture momentum tail: a continuous, monotonically-decaying stream → swallow it so it
        // can't re-page or keep the turn open. Release the lockout for a genuine new swipe — detected
        // by a pause (gap) OR a fresh push that spikes above the decaying momentum.
        if (mLockout && !mDragging) {
          if (gap >= 120 || Math.abs(e.deltaY) > mDecay * 1.4) mLockout = false;
          else { mDecay = Math.abs(e.deltaY); return; }
        }
        clearTimeout(mIdle);
        mIdle = window.setTimeout(endMonthDrag, 80);
        // A release-snap is finishing → interrupt it and resume tracking from where it sits.
        if (monthSnapRef.current) {
          if (monthTweenRef.current != null) cancelAnimationFrame(monthTweenRef.current);
          monthTweenRef.current = null;
          monthSnapRef.current = false;
          const cur = monthAnimRef.current;
          mDrag = cur ? cur.dir * cur.p * pageDist() : 0;
          mDragging = true;
          mVel = 0; mLastT = 0;
        }
        if (!mDragging) { mDragging = true; mDrag = 0; mVel = 0; mLastT = 0; }
        // smoothed release velocity (px/ms), from inter-event timing
        const dt = mLastT ? e.timeStamp - mLastT : 0;
        if (dt > 0 && dt < 200) mVel = mVel * 0.5 + (e.deltaY / dt) * 0.5;
        mLastT = e.timeStamp;
        mDrag += e.deltaY;
        const PAGE = pageDist();
        let norm = mDrag / PAGE;
        // Year boundary: pushing past Dec (down) / Jan (up) → overscroll toward the prev/next YEAR
        // (ring + hold → jumpYear), instead of a hard clamp. No band slide here.
        const atDec = focusRef.current >= 11, atJan = focusRef.current <= 0;
        if ((atDec && norm > 0) || (atJan && norm < 0)) {
          yOver = true; yOverDir = atDec ? 1 : -1; yOverPx += e.deltaY;
          setMonthEdge({ dir: yOverDir, t: Math.min(1, Math.abs(yOverPx) / 320) });
          setMonthAnim(null); setDetailMul(1); mDrag = 0;
          armYearHold();
          return;
        }
        if (yOver) { yOver = false; yOverPx = 0; if (yHold) { clearTimeout(yHold); yHold = 0; } setMonthEdge(null); } // pulled back inside the year
        if (focusRef.current >= 11) norm = Math.min(0, norm); // Dec → no next month
        if (focusRef.current <= 0) norm = Math.max(0, norm);  // Jan → no prev month
        norm = Math.max(-1, Math.min(1, norm));
        mDrag = norm * PAGE; // re-clamp so momentum can't run the accumulator past one page
        if (norm === 0) { setMonthAnim(null); setDetailMul(1); }
        else {
          const p = Math.abs(norm);
          setMonthAnim({ dir: norm > 0 ? 1 : -1, p });
          setDetailMul(1 - Math.min(1, p / 0.35)); // timeline fades as the drag progresses
        }
        // Reached a full page → commit now (don't wait out the momentum tail). The lockout then
        // swallows the remaining momentum, so focus/hover come alive immediately.
        if (Math.abs(norm) >= 1) { clearTimeout(mIdle); endMonthDrag(); }
        return;
      }
      // daily view: horizontal wheel pages the day, GESTURE-TRACKED — the day column slides 1:1 with
      // the swipe (current day out, next/prev in), snapping on release. Clamped at Jan 1 / Dec 31.
      if (zRef.current >= 2.5 && Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
        e.preventDefault();
        const gap = dLastWheelT ? e.timeStamp - dLastWheelT : 999;
        dLastWheelT = e.timeStamp;
        if (dLockout && !dDragging) { // swallow the momentum tail; release for a real new swipe
          if (gap >= 120 || Math.abs(e.deltaX) > dDecay * 1.4) dLockout = false;
          else { dDecay = Math.abs(e.deltaX); return; }
        }
        clearTimeout(dIdle);
        dIdle = window.setTimeout(endDayDrag, 80);
        // A release-snap is finishing → interrupt it and resume tracking from where it sits.
        if (daySnapRef.current) {
          if (dayTweenRef.current != null) cancelAnimationFrame(dayTweenRef.current);
          dayTweenRef.current = null; daySnapRef.current = false;
          const cur = dayAnimRef.current;
          dDrag = cur ? cur.dir * cur.p * dayPageDist() : 0;
          dDragging = true; dVel = 0; dLastT = 0;
        }
        if (!dDragging) {
          if (dayTweenRef.current != null) { cancelAnimationFrame(dayTweenRef.current); dayTweenRef.current = null; } // cancel a running overscroll spring
          dDragging = true; dDrag = 0; dVel = 0; dLastT = 0;
        }
        const dt = dLastT ? e.timeStamp - dLastT : 0;
        if (dt > 0 && dt < 200) dVel = dVel * 0.5 + (e.deltaX / dt) * 0.5; // smoothed release velocity
        dLastT = e.timeStamp;
        dDrag += e.deltaX;
        const PAGE = dayPageDist();
        const dimF = dimOfYear(focusRef.current);
        // Pushing PAST the month boundary → overscroll toward a month-jump (if a month exists that way;
        // at the year edge it's a hard stop). Otherwise a normal within-month day slide.
        if (dailyDomRef.current >= dimF && dDrag > 0) {        // past the last day → toward next month
          if (focusRef.current < 11) { dOver = true; dOverDir = 1; dOverT = Math.min(1, dDrag / DAY_OVER_THRESH); setMonthEdge({ dir: 1, t: dOverT }); armHold(); }
          else dDrag = 0; // Dec 31 → hard stop
          setDayAnim(null);
          return;
        }
        if (dailyDomRef.current <= 1 && dDrag < 0) {           // before the first day → toward prev month
          if (focusRef.current > 0) { dOver = true; dOverDir = -1; dOverT = Math.min(1, -dDrag / DAY_OVER_THRESH); setMonthEdge({ dir: -1, t: dOverT }); armHold(); }
          else dDrag = 0; // Jan 1 → hard stop
          setDayAnim(null);
          return;
        }
        if (dOver) { dOver = false; if (dHold) { clearTimeout(dHold); dHold = 0; } setMonthEdge(null); } // pulled back inside the month
        let norm = Math.max(-1, Math.min(1, dDrag / PAGE));
        dDrag = norm * PAGE; // re-clamp so momentum can't run past one page
        if (norm === 0) setDayAnim(null);
        else setDayAnim({ dir: norm > 0 ? 1 : -1, p: Math.abs(norm) });
        if (Math.abs(norm) >= 1) { clearTimeout(dIdle); endDayDrag(); } // reached a full page → commit now
        return;
      }
      // week view: vertical wheel scrolls the hourly timeline (but not when the cursor is over the
      // daily-dashboard — that area scrolls its own content instead).
      if (zRef.current >= 1.5 && Math.abs(e.deltaY) >= Math.abs(e.deltaX)) {
        if ((e.target as HTMLElement)?.closest?.(".cc-daily-dash")) return;
        const tlTop = TOP_PAD + 4 * TRACK_H + 18;
        const { maxScroll } = hourMetrics(tlTop, el.clientHeight - 8, zRef.current, tlScrollRef.current);
        if (maxScroll <= 0) return; // nothing to scroll (tall window)
        e.preventDefault();
        setTlScroll(Math.max(0, Math.min(maxScroll, tlScrollRef.current + e.deltaY)));
        return;
      }
      // horizontal swipe pages the 7-day window — week view only (daily↔daily paging is separate).
      if (zRef.current < 1.5 || zRef.current >= 2.5 || Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
      e.preventDefault();
      const wgap = wLastWheelT ? e.timeStamp - wLastWheelT : 999;
      wLastWheelT = e.timeStamp;
      if (wLock) { if (wgap >= 120) wLock = false; else return; } // swallow the momentum tail after a jump
      clearTimeout(idleTimer);
      idleTimer = window.setTimeout(endSession, 90);
      const fresh = !session;
      if (fresh) { session = true; pos = weekRef.current; }
      cancelWeekTween();
      const li = lastIdx();
      // A fresh swipe (after the previous one settled): remember whether it BEGINS at a week edge.
      // Only a swipe that starts already at the first/last week may overscroll into a month-jump — a
      // swipe that merely runs into the edge mid-gesture just stops there (no jump).
      if (fresh) wStartEdge = pos >= li - 0.001 ? 1 : pos <= 0.001 ? -1 : 0;
      const raw = pos + e.deltaX / el.clientWidth; // proposed window position (1 screen width = 1 week)
      // Pushing PAST the first/last week → overscroll toward a month-jump (if a month exists that way);
      // at the year edge it's a hard clamp. Otherwise a normal within-month window slide.
      if (raw > li && focusRef.current < 11 && wStartEdge === 1) {
        wOver = true; wOverDir = 1; wOverPx += e.deltaX;
        setMonthEdge({ dir: 1, t: Math.min(1, wOverPx / WEEK_OVER_THRESH) });
        pos = li + Math.min(30, wOverPx * 0.4) / el.clientWidth; // capped rubber-band nudge
        setWeek(pos); armWeekHold(); return;
      }
      if (raw < 0 && focusRef.current > 0 && wStartEdge === -1) {
        wOver = true; wOverDir = -1; wOverPx += e.deltaX;
        setMonthEdge({ dir: -1, t: Math.min(1, -wOverPx / WEEK_OVER_THRESH) });
        pos = -Math.min(30, -wOverPx * 0.4) / el.clientWidth;
        setWeek(pos); armWeekHold(); return;
      }
      if (wOver) { wOver = false; wOverPx = 0; if (wHold) { clearTimeout(wHold); wHold = 0; } setMonthEdge(null); } // pulled back inside the month
      pos = Math.max(0, Math.min(li, raw));
      setWeek(pos);
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => { el.removeEventListener("wheel", onWheel); clearTimeout(idleTimer); clearTimeout(mIdle); clearTimeout(dIdle); clearTimeout(dHold); clearTimeout(wHold); clearTimeout(yHold); clearTimeout(yIdle); };
  }, [tweenWeek, snapMonth, snapDayPage, jumpMonth, jumpYear, jumpYearFlat]);

  // Tick once a minute so the current-time line advances while idle.
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(id);
  }, []);

  // Persist the view position (year / level / month / week) in the URL so a refresh lands
  // in the same place. replaceState (no Back-button spam); debounced so a zoom/page tween
  // writes only its settled values. Only the params relevant to the current level are kept.
  useEffect(() => {
    if (typeof window === "undefined") return;
    const id = window.setTimeout(() => {
      const level = z < 0.5 ? 0 : z < 1.5 ? 1 : z < 2.5 ? 2 : 3;
      const p = new URLSearchParams(window.location.search);
      p.set("y", String(year));
      if (level >= 1) p.set("m", String(focus + 1)); else p.delete("m");
      if (level >= 2) {
        // The 7-day window slides per-day: encode the week (1-based) + the day offset 0–6.
        const k = Math.round(week * 7); // total day index from week 0's start
        p.set("w", String(Math.floor(k / 7) + 1));
        const day = ((k % 7) + 7) % 7;
        if (day > 0) p.set("d", String(day)); else p.delete("d");
      } else { p.delete("w"); p.delete("d"); }
      if (level >= 3) p.set("da", String(dailyDom)); else p.delete("da"); // daily view: the chosen day-of-month
      const qs = p.toString();
      window.history.replaceState(window.history.state, "", `${window.location.pathname}${qs ? `?${qs}` : ""}${window.location.hash}`);
    }, 150);
    return () => window.clearTimeout(id);
  }, [z, focus, week, year, dailyDom]);

  // Esc → zoom out ONE level (week→month→year). Stands down when an overlay or field owns
  // the Esc: a drawer (its own Esc closes it), or a focused input/textarea/editor.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (document.body.classList.contains("cc-drawer-open")) return; // drawer handles it
      if (dialogOpen()) return; // a modal dialog handles its own Escape (and stays open otherwise)
      const a = document.activeElement as HTMLElement | null;
      if (a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA" || a.isContentEditable)) return;
      const lvl = zRef.current < 0.5 ? 0 : zRef.current < 1.5 ? 1 : zRef.current < 2.5 ? 2 : 3;
      if (lvl > 0) tweenTo(lvl - 1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [tweenTo]);

  // Resolve the cursor → hover targets for the CURRENT zoom bucket. Drives both the
  // breadcrumb hint (hoverMonth/hoverWeek = click targets) and the hierarchical
  // highlight layers (hover). Called on mouse-move AND whenever the view changes
  // under a stationary cursor (scroll/zoom/focus/week) so highlights stay aligned.
  const recomputeHover = useCallback((px: number, py: number) => {
    const el = wrapRef.current;
    if (!el) return;
    const vpNow = { w: el.clientWidth, h: el.clientHeight };
    const sY = scrollYRef.current;
    const cur = zRef.current;
    let next: Hover;
    if (cur < 0.5) {
      const m = monthRowAtPoint(px, py, vpNow, sY); // includes the left gutter (name + track fields)
      const nm = monthNameAtPoint(px, py, vpNow, sY); // the clickable month-name strip
      next = { month: m, dom: m != null ? domInMonthBand(px, m, vpNow, sY) : null, week: null, hour: null, hourFrac: null, nameMonth: nm, nearLeft: null };
      setHoverMonth(nm);
      if (hoverWeekRef.current != null) setHoverWeek(null);
    } else if (cur < 1.5) {
      const wk = weekAtPointInMonth(px, focusRef.current, vpNow);
      next = { month: focusRef.current, dom: domInFocus(px, focusRef.current, vpNow), week: wk, hour: null, hourFrac: null, nameMonth: null, nearLeft: null };
      setHoverWeek(wk);
      if (hoverMonthRef.current != null) setHoverMonth(null);
    } else if (cur > 2) {
      // Daily view (+ the week→day transition): hover is locked to the chosen day's column. The
      // dashboard area to its right yields NO hover (so other days don't light up — they're gone).
      const f = frameFor(focusRef.current, cur, focusRef.current, weekRef.current, vpNow, sY);
      const dom = dailyDomRef.current;
      const colLeft = f.x0 + (dom - 1) * f.dayW;
      if (px >= colLeft && px < colLeft + f.dayW) {
        const c = cellInWeek(px, py, cur, focusRef.current, weekRef.current, vpNow, sY, tlScrollRef.current);
        next = { month: focusRef.current, dom, week: Math.round(weekRef.current), hour: c.hour, hourFrac: c.hourFrac, nameMonth: null, nearLeft: c.nearLeft };
      } else {
        next = NO_HOVER;
      }
      if (hoverMonthRef.current != null) setHoverMonth(null);
      if (hoverWeekRef.current != null) setHoverWeek(null);
    } else {
      // Use the LIVE fractional week: the 7-day window can start on any day, and the rendered
      // frame (which cellInWeek mirrors via timelineInfo) is positioned with the fractional
      // week. Rounding here is what made the hovered day/cursor drift by the day offset.
      const c = cellInWeek(px, py, zRef.current, focusRef.current, weekRef.current, vpNow, sY, tlScrollRef.current);
      next = { month: focusRef.current, dom: c.dom, week: Math.round(weekRef.current), hour: c.hour, hourFrac: c.hourFrac, nameMonth: null, nearLeft: c.nearLeft };
      if (hoverMonthRef.current != null) setHoverMonth(null);
      if (hoverWeekRef.current != null) setHoverWeek(null);
    }
    if (!sameHover(hoverRef.current, next)) setHover(next);
  }, []);

  const onMove = useCallback((e: React.MouseEvent) => {
    const el = wrapRef.current!;
    const rect = el.getBoundingClientRect();
    const px = e.clientX - rect.left, py = e.clientY - rect.top;
    // Over the top bar → it owns the pointer; drop any lingering canvas hover so the calendar
    // below doesn't highlight or read as clickable. The bar's empty gaps are pointer-events:none
    // (to pass wheel-scroll through), so the event arrives as a plain canvas mousemove with a
    // canvas target — hence the Y check, plus closest(.cc-bar) for the menu dropdowns/mask below.
    if (py < BAR_H || (e.target as HTMLElement).closest(".cc-bar")) {
      lastPtRef.current = null;
      if (hoverMonthRef.current != null) setHoverMonth(null);
      if (hoverWeekRef.current != null) setHoverWeek(null);
      if (hoverRef.current !== NO_HOVER) setHover(NO_HOVER);
      return;
    }
    lastPtRef.current = { x: px, y: py };
    recomputeHover(px, py);
  }, [recomputeHover]);

  // Re-resolve hover when the scene shifts under a still cursor (year scroll, zoom
  // tween, week paging) so the highlight tracks the content it was over.
  useEffect(() => {
    const p = lastPtRef.current;
    if (p) recomputeHover(p.x, p.y);
  }, [z, scrollY, focus, week, tlScroll, recomputeHover]);

  const onClick = useCallback((e: React.MouseEvent) => {
    const el = wrapRef.current!;
    // Top bar / its menus / a menu's mask never navigate the canvas. The bar's empty gaps pass
    // events through (pointer-events:none), so also reject by Y within the bar's band.
    if (e.clientY - el.getBoundingClientRect().top < BAR_H || (e.target as HTMLElement).closest(".cc-bar")) return;
    const cur = zRef.current;
    if (cur < 0.5) {
      // Open the month when clicking its name (gutter) OR anywhere in its day grid.
      const rect = el.getBoundingClientRect();
      const vpNow = { w: el.clientWidth, h: el.clientHeight };
      const m = hoverMonthRef.current ?? monthAtPoint(e.clientX - rect.left, e.clientY - rect.top, vpNow, scrollYRef.current);
      if (m != null) { setFocus(m); tweenTo(1); }
    } else if (cur < 1.5 && hoverWeekRef.current != null) {
      setWeek(hoverWeekRef.current);
      tweenTo(2);
    } else if (cur >= 1.5 && cur < 2.5) {
      // Week view: click a day's empty space → zoom into that DAY (daily view). Works for spillover
      // days too — they re-base focus/week + the year scroll onto the adjacent month first.
      const rect = el.getBoundingClientRect();
      const dom = hoverRef.current.dom ?? cellInWeek(e.clientX - rect.left, e.clientY - rect.top, zRef.current, focusRef.current, weekRef.current, { w: el.clientWidth, h: el.clientHeight }, scrollYRef.current, tlScrollRef.current).dom;
      if (dom == null) return;
      const r = resolveDate(focusRef.current, dom);
      if (!r) return;
      if (r.month !== focusRef.current) { // spillover → move focus + year scroll to the adjacent month
        const vpNow = { w: el.clientWidth, h: el.clientHeight };
        const delta = yearFrame(r.month, vpNow, 0).bandY - yearFrame(focusRef.current, vpNow, 0).bandY;
        const max = yearMaxScroll(vpNow);
        setScrollY((s) => Math.max(0, Math.min(max, s + delta)));
        focusRef.current = r.month; setFocus(r.month);
      }
      weekRef.current = weekOfDate(r.month, r.day); setWeek(weekRef.current);
      dailyDomRef.current = r.day; setDailyDom(r.day);
      tweenTo(3);
    }
  }, [tweenTo]);

  const clearHover = useCallback(() => {
    lastPtRef.current = null;
    setHoverMonth(null); setHoverWeek(null); setHover(NO_HOVER);
  }, []);

  // Select a year (from the breadcrumb dropdown) — reset the year scroll to the top.
  const selectYear = useCallback((y: number) => { setYearState(y); setScrollY(0); }, []);

  // "Back to Current Year": load the current year and show its yearly view.
  const goToCurrentYear = useCallback(() => {
    setYearState(new Date().getFullYear());
    setScrollY(0);
    tweenTo(0);
  }, [tweenTo]);

  // "Current Week": animate to the current week, taking the shortest path from where
  // we are (scroll within a week / zoom in one or two levels / zoom out then in).
  const goToCurrentWeek = useCallback(() => {
    const d = new Date();
    const cy = d.getFullYear(), cm = d.getMonth(), cd = d.getDate();
    const cw = Math.floor((new Date(cy, cm, 1).getDay() + cd - 1) / 7); // current week index
    const sameYear = yearRef.current === cy;
    const lvl = Math.round(zRef.current);
    if (!sameYear) { setYearState(cy); setScrollY(0); }

    if (sameYear && lvl === 2 && focusRef.current === cm) {
      tweenWeek(cw);                       // weekly view, same month → scroll across
    } else if (sameYear && lvl === 1 && focusRef.current === cm) {
      setWeek(cw); tweenTo(2);             // monthly view, same month → zoom into the week
    } else if (lvl === 0) {
      setFocus(cm); setWeek(cw); tweenTo(2); // yearly view → zoom two levels in
    } else {
      // anything else → zoom out to yearly, then into the current week
      tweenTo(0, 600, () => {
        setFocus(cm); setWeek(cw);
        window.setTimeout(() => tweenTo(2, 1050), 180);
      });
    }

    // Center the day timeline on the current time (clamped to top/bottom). Computed with
    // the settled week-view geometry (z=2); tlScroll persists, so it's correct once the
    // timeline reveals regardless of which animation path above we took.
    const el = wrapRef.current;
    if (el) {
      const tlTop = TOP_PAD + 4 * TRACK_H + 18;
      const { hourH, viewH, maxScroll } = hourMetrics(tlTop, el.clientHeight - 8, 2, 0);
      const nowFrac = d.getHours() + d.getMinutes() / 60;
      setTlScroll(maxScroll <= 0 ? 0 : Math.max(0, Math.min(maxScroll, nowFrac * hourH - viewH / 2)));
    }
  }, [tweenTo, tweenWeek]);

  // "Nav" menu: jump to TODAY at a chosen level (0 year · 1 month · 2 week · 3 day), taking the
  // shortest path — slide within the same week, zoom straight in from year/same-month, or zoom out
  // to year then back in when the month/year differs. Generalises goToCurrentWeek across levels.
  const goToNow = useCallback((target: number) => {
    const T = Math.max(0, Math.min(3, Math.round(target)));
    const d = new Date();
    const cy = d.getFullYear(), cm = d.getMonth(), cd = d.getDate();
    const cw = Math.floor((new Date(cy, cm, 1).getDay() + cd - 1) / 7); // week-row of today
    const sameYear = yearRef.current === cy;
    const sameMonth = sameYear && focusRef.current === cm;
    const lvl = Math.round(zRef.current);
    if (!sameYear) { setYearState(cy); setScrollY(0); }

    const setSub = () => { // place focus/week/day for the target level
      setFocus(cm);
      if (T >= 2) { weekRef.current = cw; setWeek(cw); }
      if (T === 3) { dailyDomRef.current = cd; setDailyDom(cd); }
    };

    if (T === 0) {
      tweenTo(0);
    } else if (T === 2 && lvl === 2 && sameMonth) {
      tweenWeek(cw);                                   // already in this month's week view → slide across
    } else if (sameMonth || (lvl === 0 && sameYear)) {
      setSub(); tweenTo(T, 360 + 180 * Math.abs(T - lvl)); // same month, or at year view → set + zoom direct
    } else {
      tweenTo(0, 600, () => { setSub(); window.setTimeout(() => tweenTo(T, 500 + 230 * T), 180); }); // out to year → in
    }

    // Week AND day views centre the timeline on the current time (day = "focus on now").
    if (T >= 2) {
      const el = wrapRef.current;
      if (el) {
        const tlTop = TOP_PAD + 4 * TRACK_H + 18;
        const { hourH, viewH, maxScroll } = hourMetrics(tlTop, el.clientHeight - 8, 2, 0);
        const nowFrac = d.getHours() + d.getMinutes() / 60;
        setTlScroll(maxScroll <= 0 ? 0 : Math.max(0, Math.min(maxScroll, nowFrac * hourH - viewH / 2)));
      }
    }
  }, [tweenTo, tweenWeek]);

  // Animate to a specific date (year/month/week index) and LAND AT `level` (0 year · 1 month ·
  // 2 week), then fire `onArrive`. Like goToCurrentWeek it takes the shortest path: it zooms OUT
  // only as far as the current spot and the target diverge — same week → none, same month →
  // month, else year — then zooms back IN to `level` at the target. Used by the drawer's "back
  // to the first occurrence", so the trajectory length scales with how far apart the two are.
  const goToOccurrence = useCallback((ty: number, tm: number, tw: number, level: number, onArrive?: () => void) => {
    const lvl = Math.max(0, Math.min(2, Math.round(level)));
    const sameYear = yearRef.current === ty;
    const sameMonth = sameYear && focusRef.current === tm;
    const sameWeek = sameMonth && Math.round(weekRef.current) === tw;
    const fire = () => { if (onArrive) requestAnimationFrame(() => requestAnimationFrame(onArrive)); };
    const place = () => {
      if (!sameYear) { setYearState(ty); setScrollY(0); }
      setFocus(tm);
      if (lvl >= 2) setWeek(tw);
    };
    const out = (!sameYear || !sameMonth) ? 0 : (lvl === 2 && !sameWeek) ? 1 : lvl;
    const dist = lvl - out;
    if (dist <= 0) { place(); window.setTimeout(fire, 100); return; } // already at the right level/spot
    const durOut = 300 + 240 * dist;
    const durIn = 360 + 320 * dist;
    tweenTo(out, durOut, () => {
      place();
      window.setTimeout(() => tweenTo(lvl, durIn, fire), 160);
    });
  }, [tweenTo]);

  // Scroll the week-view timeline so a given hour-of-day (0–24, fractional) sits centered in view.
  // Used to reveal a timed event after navigating to its week (the assistant "follow" navigation).
  const revealHour = useCallback((hourFrac: number) => {
    const el = wrapRef.current;
    if (!el) return;
    const tlTop = TOP_PAD + 4 * TRACK_H + 18;
    const { hourH, viewH, maxScroll } = hourMetrics(tlTop, el.clientHeight - 8, 2, 0);
    setTlScroll(maxScroll <= 0 ? 0 : Math.max(0, Math.min(maxScroll, hourFrac * hourH - viewH / 2)));
  }, []);

  // Breadcrumb "Today" button: always an ANIMATED jump to today's daily view (never an instant
  // set). Zooms out to a pivot — month (nearby, same month) or year (far) so the day/week/month
  // swap isn't jarring — sets today's spot there, then zooms back into the day, centered on now.
  const goToToday = useCallback(() => {
    const d = new Date();
    const cy = d.getFullYear(), cm = d.getMonth(), cd = d.getDate();
    const cw = Math.floor((new Date(cy, cm, 1).getDay() + cd - 1) / 7); // today's week-row
    const lvl = zRef.current;
    const sameMonth = yearRef.current === cy && focusRef.current === cm;
    const pivot = sameMonth ? 1 : 0; // zoom out only this far before swapping to today
    const place = () => {
      if (yearRef.current !== cy) { setYearState(cy); setScrollY(0); }
      setFocus(cm);
      weekRef.current = cw; setWeek(cw);
      dailyDomRef.current = cd; setDailyDom(cd);
      // Centre the day timeline on the current time (z≥2 metrics are exact for the daily view).
      const el = wrapRef.current;
      if (el) {
        const tlTop = TOP_PAD + 4 * TRACK_H + 18;
        const { hourH, viewH, maxScroll } = hourMetrics(tlTop, el.clientHeight - 8, 2, 0);
        const nowFrac = d.getHours() + d.getMinutes() / 60;
        setTlScroll(maxScroll <= 0 ? 0 : Math.max(0, Math.min(maxScroll, nowFrac * hourH - viewH / 2)));
      }
    };
    const zoomIn = () => tweenTo(3, 520 + 200 * (3 - pivot));
    if (lvl <= pivot + 0.01) {
      place();                                   // already at/above the pivot → single zoom-in
      window.setTimeout(zoomIn, 20);
    } else {
      tweenTo(pivot, 300 + 220 * (lvl - pivot), () => { place(); window.setTimeout(zoomIn, 160); }); // out → swap → in
    }
  }, [tweenTo]);

  // The month the breadcrumb should show: flips to the page-turn target as soon as the gesture
  // passes the commit threshold (during drag AND snap), so the label updates the moment the new
  // month is committed-to — not after the animation settles. Reverts if the drag is pulled back.
  const displayFocus = monthAnim && monthAnim.p >= MONTH_COMMIT_P
    ? Math.max(0, Math.min(11, focus + monthAnim.dir))
    : focus;

  return { wrapRef, vp, z, focus, displayFocus, week, scrollY, tlScroll, setTlScroll, weekHourH, setWeekHourH, hoverMonth, hoverWeek, hover, now, year, currentYear, monthAnim, detailMul, dailyDom, dayAnim, monthEdge, dailyFrac, setDailyFrac, yearFade, selectYear, goToCurrentYear, goToCurrentWeek, goToNow, goToToday, goToMonth, goToOccurrence, revealHour, tweenTo, onMove, onClick, clearHover };
}
