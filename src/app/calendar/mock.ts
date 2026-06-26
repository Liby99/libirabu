// Mock data for the animated calendar prototype. Deterministic (no RNG) so SSR is stable.
// Year keyframe mirrors GridCal: 4 fixed tracks per month, events painted across days.

export const YEAR = 2026;

export interface Track {
  id: number;
  name: string;
  color: string;
}

export const TRACKS: Track[] = [
  { id: 0, name: "Teaching", color: "#df8548" }, // warm orange
  { id: 1, name: "Research", color: "#58a996" }, // teal
  { id: 2, name: "Service", color: "#dfb656" }, // gold
  { id: 3, name: "Travel", color: "#b0616a" }, // muted red
];

export interface Ev {
  id: string;
  track: number; // 0..3
  month: number; // 0..11
  start: number; // day-of-month (1-based)
  end: number; // inclusive
  title: string;
}

export function daysInMonth(month: number): number {
  return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month];
}

// A deterministic spread of events per month/track.
export const EVENTS: Ev[] = (() => {
  const out: Ev[] = [];
  const titlesByTrack = [
    ["Lectures", "Office hours", "Grading", "Final exam"],
    ["Experiments", "Paper draft", "Rebuttal", "Reading group"],
    ["PC review", "Committee", "Panel", "Seminar"],
    ["NeurIPS", "Site visit", "Keynote", "Workshop"],
  ];
  for (let m = 0; m < 12; m++) {
    const dim = daysInMonth(m);
    for (let t = 0; t < 4; t++) {
      // 1–2 events per track per month, placed deterministically
      const a1 = ((m * 7 + t * 3) % (dim - 6)) + 1;
      out.push({ id: `e-${m}-${t}-a`, track: t, month: m, start: a1, end: Math.min(dim, a1 + 3 + (t % 3)), title: titlesByTrack[t][m % 4] });
      if ((m + t) % 2 === 0) {
        const a2 = ((m * 5 + t * 11) % (dim - 3)) + 1;
        if (Math.abs(a2 - a1) > 5) {
          out.push({ id: `e-${m}-${t}-b`, track: t, month: m, start: a2, end: Math.min(dim, a2 + 1), title: titlesByTrack[t][(m + 1) % 4] });
        }
      }
    }
  }
  return out;
})();

// Timed (intraday) events — shown only in the day-detail timeline (0:00–24:00),
// NOT in the top track band. Deterministic. track is used only for color.
export interface Timed {
  id: string;
  month: number; // 0..11
  day: number; // 1-based
  startHour: number; // 0..24 (decimal allowed)
  endHour: number;
  title: string;
  track: number;
}

const TIMED_TITLES = [
  "Standup", "1:1 w/ student", "Lecture", "Lab meeting",
  "Reading group", "Advising", "Sponsor call", "Seminar",
];

export const TIMED: Timed[] = (() => {
  const out: Timed[] = [];
  for (let m = 0; m < 12; m++) {
    const dim = daysInMonth(m);
    for (let d = 1; d <= dim; d++) {
      const seed = m * 31 + d;
      if (seed % 2 === 0) {
        out.push({ id: `t-${m}-${d}-1`, month: m, day: d, startHour: 9, endHour: 10, title: TIMED_TITLES[seed % 8], track: seed % 4 });
      }
      if (seed % 3 === 0) {
        const s = 13 + (seed % 3);
        out.push({ id: `t-${m}-${d}-2`, month: m, day: d, startHour: s, endHour: s + 1.5, title: TIMED_TITLES[(seed + 3) % 8], track: (seed + 1) % 4 });
      }
      if (seed % 5 === 0) {
        out.push({ id: `t-${m}-${d}-3`, month: m, day: d, startHour: 16, endHour: 17, title: TIMED_TITLES[(seed + 5) % 8], track: (seed + 2) % 4 });
      }
    }
  }
  return out;
})();
