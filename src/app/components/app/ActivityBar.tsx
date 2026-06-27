"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { signOut } from "next-auth/react";
import {
  CalendarDays,
  FolderKanban,
  ListChecks,
  Users,
  FileText,
  AlarmClock,
  ScrollText,
  KeyRound,
  Banknote,
  Plane,
  LogOut,
  type LucideIcon,
} from "lucide-react";

const ITEMS: { href: string; label: string; Icon: LucideIcon }[] = [
  { href: "/calendar", label: "Calendar", Icon: CalendarDays },
  { href: "/projects", label: "Projects", Icon: FolderKanban },
  { href: "/tasks", label: "Tasks", Icon: ListChecks },
  { href: "/people", label: "People", Icon: Users },
  { href: "/papers", label: "Papers", Icon: FileText },
  { href: "/deadlines", label: "Deadlines", Icon: AlarmClock },
  { href: "/proposals", label: "Proposals", Icon: ScrollText },
  { href: "/keys", label: "Keys", Icon: KeyRound },
  { href: "/funding", label: "Funding", Icon: Banknote },
  { href: "/travel", label: "Travel", Icon: Plane },
];

export default function ActivityBar() {
  const pathname = usePathname();

  // No chrome on the auth pages.
  if (pathname.startsWith("/auth")) return null;

  return (
    <div className="activity-bar" role="navigation" aria-label="Primary">
      {ITEMS.map(({ href, label, Icon }) => {
        const active = pathname.startsWith(href);
        return (
          <Link
            key={href}
            href={href}
            title={label}
            aria-label={label}
            aria-current={active ? "page" : undefined}
            className={`activity-bar-item${active ? " active" : ""}`}
          >
            <Icon size={22} strokeWidth={1.75} aria-hidden />
          </Link>
        );
      })}
      <span className="activity-bar-spacer" />
      <button
        type="button"
        title="Sign out"
        aria-label="Sign out"
        className="activity-bar-item"
        onClick={() => signOut({ callbackUrl: "/auth/signin" })}
      >
        <LogOut size={22} strokeWidth={1.75} aria-hidden />
      </button>
    </div>
  );
}
