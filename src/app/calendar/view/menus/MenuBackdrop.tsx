"use client";

// Transparent full-screen mask rendered under an OPEN top-bar menu. A click anywhere off the
// menu closes it and is swallowed — the calendar below never navigates. It lives inside .cc-bar,
// so the canvas hover/click handlers (which bail on .cc-bar) treat it as part of the bar.
export default function MenuBackdrop({ onClose }: { onClose: () => void }) {
  return (
    <div
      className="cc-bar-mask"
      onMouseDown={(e) => e.stopPropagation()}
      onClick={(e) => { e.stopPropagation(); onClose(); }}
    />
  );
}
