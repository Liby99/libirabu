"use client"

import { useEffect } from "react"
import { SessionProvider } from "next-auth/react"
import { ConfirmProvider } from "./components/ui/confirm"
import { applyTheme, getThemeMode } from "./components/app/theme"

// Re-resolve the theme when the OS appearance changes while in Auto mode (the inline script in
// layout.tsx only runs once, at load). Also re-applies once on mount as a safety net.
function ThemeSync() {
  useEffect(() => {
    applyTheme();
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => { if (getThemeMode() === "auto") applyTheme(); };
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);
  return null;
}

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <SessionProvider>
      <ThemeSync />
      <ConfirmProvider>{children}</ConfirmProvider>
    </SessionProvider>
  )
}
