// Corner badges on an event (AI spark, recurrence, promoted chevrons).

import { RotateCw, Sparkles, ChevronsUp, CalendarSync } from "lucide-react";

// Small corner badges shown on an event: an AI-provenance spark, an "imported from an external
// calendar" mark, a recurrence mark, and/or a "promoted to band" mark. Sized to sit side-by-side
// (see .cc-badges / .cc-badge in calendar.css). The AI spark reuses the assistant FAB's icon so
// "the AI did this" reads consistently across the app.
export default function EventBadges({ ai, recurring, imported, promoted }: { ai?: boolean; recurring?: boolean; imported?: boolean; promoted?: boolean }) {
  if (!ai && !recurring && !imported && !promoted) return null;
  return (
    <span className="cc-badges" aria-hidden>
      {ai && <Sparkles className="cc-badge" size={9} strokeWidth={2.5} />}
      {imported && <CalendarSync className="cc-badge" size={9} strokeWidth={2.5} />}
      {recurring && <RotateCw className="cc-badge" size={9} strokeWidth={2.5} />}
      {promoted && <ChevronsUp className="cc-badge" size={10} strokeWidth={2.5} />}
    </span>
  );
}
