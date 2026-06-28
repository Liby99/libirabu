"use client";

// "Promote" a timed/deadline event to a ghost band: a No | Yes toggle; when Yes, a lane
// picker (T1–T4) appears to its right. `null` = not promoted; 0–3 = the promoted lane.
export default function PromoteEditor({ promoteTrack, onChange }: { promoteTrack: number | null | undefined; onChange: (t: number | null) => void }) {
  const on = promoteTrack != null;
  return (
    <div className="cc-dw-row cc-dw-when cc-dw-promote">
      <span className="cc-dw-label">Promote</span>
      <div className="cc-seg" role="group" aria-label="Promote to band">
        <button type="button" className={`cc-seg-btn${!on ? " sel" : ""}`} onClick={() => onChange(null)}>No</button>
        <button type="button" className={`cc-seg-btn${on ? " sel" : ""}`} onClick={() => { if (!on) onChange(0); }}>Yes</button>
      </div>
      {on && (
        <div className="cc-seg" role="group" aria-label="Track">
          {[0, 1, 2, 3].map((t) => (
            <button key={t} type="button" className={`cc-seg-btn${promoteTrack === t ? " sel" : ""}`} onClick={() => onChange(t)}>T{t + 1}</button>
          ))}
        </div>
      )}
    </div>
  );
}
