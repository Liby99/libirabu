"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { signOut } from "next-auth/react";

const LINKS: { href: string; label: string }[] = [
  { href: "/", label: "Year" },
  { href: "/week", label: "Week" },
  { href: "/day", label: "Day" },
  { href: "/projects", label: "Projects" },
  { href: "/tasks", label: "Tasks" },
  { href: "/people", label: "People" },
  { href: "/papers", label: "Papers" },
  { href: "/proposals", label: "Proposals" },
  { href: "/keys", label: "Keys" },
  { href: "/funding", label: "Funding" },
  { href: "/travel", label: "Travel" },
];

export default function AppNav() {
  const pathname = usePathname();
  return (
    <nav className="app-nav">
      <span className="app-brand">libirabu</span>
      <div className="app-nav-links">
        {LINKS.map((l) => {
          const active =
            l.href === "/" ? pathname === "/" : pathname.startsWith(l.href);
          return (
            <Link
              key={l.href}
              href={l.href}
              className={`app-nav-link${active ? " active" : ""}`}
            >
              {l.label}
            </Link>
          );
        })}
      </div>
      <span style={{ flex: 1 }} />
      <button className="app-nav-signout" onClick={() => signOut({ callbackUrl: "/auth/signin" })}>
        Sign out
      </button>
    </nav>
  );
}
