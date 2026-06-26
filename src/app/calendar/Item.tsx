import { memo } from "react";
import { Item } from "./types";

// Renders one calendar primitive. Structural styling lives in CSS classes
// (calendar.css); only per-item geometry, opacity, and dynamic values (day width,
// event color key) are inline — so each element is inspectable. 2D translate (not
// translate3d) avoids forcing a GPU layer per element.
const ItemView = memo(function ItemView({ it }: { it: Item }) {
  const style = {
    transform: `translate(${it.x}px, ${it.y}px)`,
    width: it.w,
    height: it.h,
    opacity: it.opacity,
    zIndex: it.z,
  } as React.CSSProperties;

  if (it.kind === "row") {
    return <div className={`cc-item cc-row${it.inner ? " cc-row-inner" : ""}`} style={{ ...style, ["--dayw"]: `${it.cols ? it.w / it.cols : it.w}px` } as React.CSSProperties} />;
  }

  if (it.kind === "gridline") {
    const ls = it.lineStyle ? ` cc-${it.lineStyle}-${it.h >= it.w ? "v" : "h"}` : "";
    return <div className={`cc-item cc-gridline${ls}`} style={style} />;
  }

  if (it.kind === "dim") {
    return <div className="cc-item cc-dim" style={style} />;
  }

  if (it.kind === "event") {
    return (
      <div className={`cc-item cc-event cc-ev-${it.color}`} style={style}>
        {it.text && <span style={{ fontSize: it.fontSize }}>{it.text}</span>}
      </div>
    );
  }

  // monthLabel / dayLabel
  const cls = it.kind === "monthLabel" ? "cc-monthlabel" : `cc-daylabel ${it.align === "center" ? "cc-center" : "cc-left"}`;
  return <div className={`cc-item ${cls}`} style={{ ...style, fontSize: it.fontSize } as React.CSSProperties}>{it.text}</div>;
}, (p, n) => {
  // Skip re-render when this item's values are unchanged (e.g. a render triggered
  // only by editing a track name shouldn't re-render every calendar item).
  const a = p.it, b = n.it;
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h && a.opacity === b.opacity &&
    a.z === b.z && a.color === b.color && a.text === b.text && a.fontSize === b.fontSize &&
    a.lineStyle === b.lineStyle && a.cols === b.cols && a.align === b.align && a.kind === b.kind && a.inner === b.inner;
});

export default ItemView;
