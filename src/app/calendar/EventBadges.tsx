import { RotateCw, Sparkles, ChevronsUp } from "lucide-react";

// Small corner badges shown on an event: an AI-provenance spark, a recurrence mark, and/or a
// "promoted to band" mark. Sized to sit side-by-side (see .cc-badges / .cc-badge in
// calendar.css). The AI spark reuses the assistant FAB's icon so "the AI did this" reads
// consistently across the app.
export default function EventBadges({ ai, recurring, promoted }: { ai?: boolean; recurring?: boolean; promoted?: boolean }) {
  if (!ai && !recurring && !promoted) return null;
  return (
    <span className="cc-badges" aria-hidden>
      {ai && <Sparkles className="cc-badge" size={9} strokeWidth={2.5} />}
      {recurring && <RotateCw className="cc-badge" size={9} strokeWidth={2.5} />}
      {promoted && <ChevronsUp className="cc-badge" size={10} strokeWidth={2.5} />}
    </span>
  );
}
