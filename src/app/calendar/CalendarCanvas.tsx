"use client";

import { buildScene } from "./scene";
import { LABEL_W } from "./constants";
import { MONTH_LONG } from "./dates";
import { useCalendarInteractions } from "./useCalendarInteractions";
import { useTrackNames } from "./useTrackNames";
import ItemView from "./Item";
import TrackEditor from "./TrackEditor";

export default function CalendarCanvas() {
  const { wrapRef, vp, z, focus, week, scrollY, hoverMonth, hoverWeek, tweenTo, onMove, onClick, clearHover } =
    useCalendarInteractions();
  const { trackNames, editTrack } = useTrackNames();

  if (vp.w === 0) return <div ref={wrapRef} className="cc-wrap" />;

  const scene = buildScene(z, focus, week, vp, scrollY);
  const level = z < 0.5 ? 0 : z < 1.5 ? 1 : 2;
  const hint =
    level === 0 ? (hoverMonth != null ? "click the month name to open it · or pinch" : "pinch to zoom in")
    : level === 1 ? (hoverWeek != null ? "click to open week · or pinch to zoom" : "hover a week · pinch to zoom")
    : "scroll sideways to change week · pinch to zoom out";

  return (
    <div ref={wrapRef} className="cc-wrap" onMouseMove={onMove} onMouseLeave={clearHover} onClick={onClick}>
      <div className="cc-bar">
        <nav className="cc-crumbs" onClick={(e) => e.stopPropagation()}>
          <button className={`cc-crumb${level === 0 ? " current" : ""}`} onClick={() => tweenTo(0)}>Year 2026</button>
          {level >= 1 && (
            <>
              <span className="cc-sep">›</span>
              <button className={`cc-crumb${level === 1 ? " current" : ""}`} onClick={() => tweenTo(1)}>{MONTH_LONG[focus]}</button>
            </>
          )}
          {level >= 2 && (
            <>
              <span className="cc-sep">›</span>
              <button className="cc-crumb current" onClick={() => tweenTo(2)}>Week {Math.round(week) + 1}</button>
            </>
          )}
        </nav>
        <span className="cc-hint">{hint}</span>
      </div>

      {/* solid left gutter — occludes lane content that slides under it (week view) */}
      <div className="cc-gutter" style={{ width: LABEL_W }} />

      <div className="cc-layer">
        {scene.items.map((it) => <ItemView key={it.key} it={it} />)}
        <TrackEditor trackNames={trackNames} editTrack={editTrack} vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} />
      </div>
    </div>
  );
}
