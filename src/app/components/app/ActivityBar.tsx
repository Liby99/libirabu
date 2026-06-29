"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { signOut } from "next-auth/react";
import {
  CalendarDays,
  LogOut,
  type LucideIcon,
} from "lucide-react";

const ITEMS: { href: string; label: string; Icon: LucideIcon }[] = [
  { href: "/calendar", label: "Calendar", Icon: CalendarDays },
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
