import { requireUserId } from "@/lib/auth";
import CalendarCanvas from "./view/CalendarCanvas";
import AssistantFab from "./assistant/AssistantFab";
import "./calendar.css";

// Animated semantic-zoom calendar. Year ⇄ Month ⇄ Week. Gated like every other page: a
// logged-out visitor is redirected to /auth/signin before render, so the client-side
// calendar hooks never fire an unauthenticated (401) request.
export default async function CalendarPage() {
  await requireUserId();
  return (
    <>
      <main className="app-main">
        <CalendarCanvas />
      </main>
      <AssistantFab />
    </>
  );
}
