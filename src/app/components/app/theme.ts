"use client";

// Theme system. globals.css keys off <html data-theme="<id>">, where the id names a concrete
// theme = a block of CSS-variable overrides. JS always resolves to a concrete id — from the mode
// (light/dark/auto), the per-variant selection, and the OS preference — and sets data-theme, so
// it's never absent once the app runs. A tiny inline script in app/layout.tsx does the same
// before first paint (no flash), and <ThemeSync> (app/providers.tsx) keeps Auto reacting to live
// OS changes.

export type Variant = "light" | "dark";

export interface Theme {
  id: string;   // data-theme value + the [data-theme="id"] CSS block
  name: string; // shown in Settings → Theme
  variant: Variant;
}

// The registry. Add a theme by adding an entry here AND a matching [data-theme="id"] block in
// globals.css (the preview swatch is driven from that block via [data-theme-id="id"] CSS).
export const THEMES: Theme[] = [
  { id: "light", name: "Default Light", variant: "light" },
  { id: "unicorn", name: "Unicorn", variant: "light" },
  { id: "dark", name: "Default Dark", variant: "dark" },
  { id: "matrix", name: "Matrix", variant: "dark" },
];

export const themesFor = (v: Variant): Theme[] => THEMES.filter((t) => t.variant === v);
export const themeById = (id: string): Theme | undefined => THEMES.find((t) => t.id === id);

// Fallback id per variant (the built-in default theme for each).
const DEFAULT_ID: Record<Variant, string> = { light: "light", dark: "dark" };

export type ThemeMode = "light" | "dark" | "auto";
const MODE_KEY = "theme-mode";
const SELECT_KEY: Record<Variant, string> = { light: "theme-light", dark: "theme-dark" };

export function getThemeMode(): ThemeMode {
  try { const v = localStorage.getItem(MODE_KEY); if (v === "light" || v === "dark") return v; } catch {}
  return "auto";
}

// The chosen theme id for a variant — validated against the registry, default if unset/unknown.
export function getSelectedTheme(variant: Variant): string {
  try {
    const id = localStorage.getItem(SELECT_KEY[variant]);
    const t = id ? themeById(id) : undefined;
    if (t && t.variant === variant) return t.id;
  } catch {}
  return DEFAULT_ID[variant];
}

export function systemPrefersDark(): boolean {
  return typeof matchMedia !== "undefined" && matchMedia("(prefers-color-scheme: dark)").matches;
}

// The variant in effect right now (auto resolves to the OS setting).
export function effectiveVariant(mode: ThemeMode = getThemeMode()): Variant {
  return mode === "auto" ? (systemPrefersDark() ? "dark" : "light") : mode;
}

// The concrete theme id in effect: the selection for the effective variant.
export function resolveThemeId(): string {
  return getSelectedTheme(effectiveVariant());
}

export function applyTheme(): void {
  document.documentElement.dataset.theme = resolveThemeId();
}

export function setThemeMode(mode: ThemeMode): void {
  try { localStorage.setItem(MODE_KEY, mode); } catch {}
  applyTheme();
}

export function setSelectedTheme(variant: Variant, id: string): void {
  try { localStorage.setItem(SELECT_KEY[variant], id); } catch {}
  applyTheme();
}
