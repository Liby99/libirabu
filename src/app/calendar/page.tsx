import CalendarCanvas from "./CalendarCanvas";
import "./calendar.css";

// Animated semantic-zoom calendar prototype (mock data). Year ⇄ Month ⇄ Week.
export default function CalendarPage() {
  return (
    <>
      <main className="app-main">
        <CalendarCanvas />
      </main>
    </>
  );
}
