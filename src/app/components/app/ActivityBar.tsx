"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { signOut } from "next-auth/react";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  CalendarDays,
  User as UserIcon,
  LogOut,
  Settings,
  ShieldCheck,
  KeyRound,
  Palette,
  type LucideIcon,
} from "lucide-react";
import AccountModal, { type AccountProfile } from "./AccountModal";

const ITEMS: { href: string; label: string; Icon: LucideIcon }[] = [
  { href: "/calendar", label: "Calendar", Icon: CalendarDays },
];

export default function ActivityBar() {
  const pathname = usePathname();
  const onAuth = pathname.startsWith("/auth");

  const [profile, setProfile] = useState<AccountProfile | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [modal, setModal] = useState<null | "account" | "security" | "keys" | "theme">(null);
  const wrapRef = useRef<HTMLDivElement>(null);

  const loadProfile = useCallback(async () => {
    try {
      const res = await fetch("/api/account");
      if (res.ok) setProfile(await res.json());
    } catch { /* offline / not signed in — leave as null */ }
  }, []);

  useEffect(() => { if (!onAuth) void loadProfile(); }, [onAuth, loadProfile]);

  // No chrome on the auth pages.
  if (onAuth) return null;

  const openModal = (tab: "account" | "security" | "keys" | "theme") => { setMenuOpen(false); setModal(tab); };
  const avatarInitial = (profile?.name || profile?.email || "?").trim().slice(0, 1).toUpperCase();

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

      <div className="activity-bar-account" ref={wrapRef}>
        <button
          type="button"
          title="Account"
          aria-label="Account"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          className={`activity-bar-item${menuOpen ? " active" : ""}`}
          onClick={() => setMenuOpen((o) => !o)}
        >
          {profile?.image
            // eslint-disable-next-line @next/next/no-img-element -- data-URL avatar; next/image can't optimize it
            ? <img className="activity-bar-avatar" src={profile.image} alt="" />
            : profile
              ? <span className="activity-bar-avatar-fallback">{avatarInitial}</span>
              : <UserIcon size={22} strokeWidth={1.75} aria-hidden />}
        </button>

        {menuOpen && (
          <>
            <div className="activity-bar-menu-backdrop" onClick={() => setMenuOpen(false)} />
            <div className="activity-bar-menu" role="menu">
              <button role="menuitem" className="activity-bar-menu-item" onClick={() => openModal("account")}><Settings size={15} /> Account</button>
              <button role="menuitem" className="activity-bar-menu-item" onClick={() => openModal("security")}><ShieldCheck size={15} /> Security</button>
              <button role="menuitem" className="activity-bar-menu-item" onClick={() => openModal("keys")}><KeyRound size={15} /> API Keys</button>
              <button role="menuitem" className="activity-bar-menu-item" onClick={() => openModal("theme")}><Palette size={15} /> Theme</button>
              <div className="activity-bar-menu-sep" />
              <button role="menuitem" className="activity-bar-menu-item" onClick={() => signOut({ callbackUrl: "/auth/signin" })}><LogOut size={15} /> Logout</button>
            </div>
          </>
        )}
      </div>

      {profile && (
        <AccountModal
          open={modal !== null}
          onClose={() => setModal(null)}
          initialTab={modal ?? "account"}
          profile={profile}
          onSaved={setProfile}
        />
      )}
    </div>
  );
}
