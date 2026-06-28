import { RotateCw, Sparkles } from "lucide-react";

// Small corner badges shown on an event: an AI-provenance spark and/or a recurrence mark.
// Sized to sit side-by-side (see .cc-badges / .cc-badge in calendar.css). The AI spark reuses
// the assistant FAB's icon so "the AI did this" reads consistently across the app.
export default function EventBadges({ ai, recurring }: { ai?: boolean; recurring?: boolean }) {
  if (!ai && !recurring) return null;
  return (
    <span className="cc-badges" aria-hidden>
      {ai && <Sparkles className="cc-badge" size={9} strokeWidth={2.5} />}
      {recurring && <RotateCw className="cc-badge" size={9} strokeWidth={2.5} />}
    </span>
  );
}
