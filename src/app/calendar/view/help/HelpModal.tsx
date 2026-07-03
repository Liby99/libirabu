"use client";

// Calendar Help center: a wide two-pane modal — a section rail on the left, the selected
// section's content scrolling on the right. Rendered through the app's unified <Dialog>
// primitive (Escape / backdrop-click / × all close it); the .cc-help-card class widens the
// card and drops the default body padding so the two-pane layout owns the whole surface.

import { useState } from "react";
import { Dialog } from "@/app/components/ui/Dialog";
import { HELP_SECTIONS, type HelpSectionId } from "../help/content";

export default function HelpModal({
  initial = "overview",
  onClose,
}: {
  initial?: HelpSectionId;
  onClose: () => void;
}) {
  const [active, setActive] = useState<HelpSectionId>(initial);
  const section = HELP_SECTIONS.find((s) => s.id === active) ?? HELP_SECTIONS[0];

  return (
    <Dialog open onClose={onClose} cardClassName="cc-help-card" showClose labelId="cc-help-title">
      <div className="cc-help">
        <nav className="cc-help-rail" aria-label="Help sections">
          <div className="cc-help-brand">Calendar Help</div>
          {HELP_SECTIONS.map((s) => (
            <button
              key={s.id}
              className={`cc-help-navitem${s.id === active ? " active" : ""}`}
              onClick={() => setActive(s.id)}
              aria-current={s.id === active ? "page" : undefined}
            >
              {s.label}
            </button>
          ))}
        </nav>
        {/* key={active} restarts the enter animation + resets scroll on section switch */}
        <section className="cc-help-content" key={active}>
          <h2 className="cc-help-h" id="cc-help-title">{section.label}</h2>
          {section.body}
        </section>
      </div>
    </Dialog>
  );
}
