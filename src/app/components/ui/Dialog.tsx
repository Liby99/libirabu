"use client";

// The one dialog/modal primitive for the whole app: a centered, backdropped card portaled
// to <body>. Escape and backdrop-click close it. Compose it directly for content modals
// (see Help), or use ConfirmDialog / useConfirm for the common confirm case.

import { useEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { X } from "lucide-react";
import "./dialog.css";

export type BtnVariant = "primary" | "ghost" | "danger";

// How many dialogs are currently open. While > 0, <body> carries `ui-dialog-open` so host
// pages (e.g. the calendar) can freeze their own global key/wheel shortcuts. Ref-counted so
// stacked dialogs don't clear the flag prematurely.
let openDialogCount = 0;

// The canonical dialog action button. Use for every dialog footer button so they match.
export function DialogButton({
  variant = "ghost",
  className,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: BtnVariant }) {
  return <button className={`ui-btn ui-btn--${variant}${className ? " " + className : ""}`} {...props} />;
}

interface DialogProps {
  open: boolean;
  onClose: () => void;
  title?: ReactNode;
  children?: ReactNode; // body content
  actions?: ReactNode; // footer buttons (typically <DialogButton>s)
  actionsClassName?: string;
  cardClassName?: string;
  showClose?: boolean; // top-right × button
  closeOnBackdrop?: boolean; // default true
  labelId?: string;
}

export function Dialog({
  open,
  onClose,
  title,
  children,
  actions,
  actionsClassName,
  cardClassName,
  showClose,
  closeOnBackdrop = true,
  labelId,
}: DialogProps) {
  const cardRef = useRef<HTMLDivElement>(null);

  // Escape closes. Capture phase + stopPropagation so host pages (e.g. the calendar's global
  // key handlers) don't also react to the same Escape.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { e.stopPropagation(); onClose(); }
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [open, onClose]);

  // Focus the card on open so keyboard users land inside the dialog.
  useEffect(() => { if (open) cardRef.current?.focus(); }, [open]);

  // Mark the document modal while open so the page underneath can go inert (the backdrop
  // already swallows pointer events; this covers window-level key/wheel shortcuts).
  useEffect(() => {
    if (!open) return;
    openDialogCount++;
    document.body.classList.add("ui-dialog-open");
    return () => {
      openDialogCount = Math.max(0, openDialogCount - 1);
      if (openDialogCount === 0) document.body.classList.remove("ui-dialog-open");
    };
  }, [open]);

  if (!open || typeof document === "undefined") return null;

  return createPortal(
    // Stop mouse events here so they don't bubble to ancestor React handlers. The portal
    // renders into <body>, but React still routes synthetic events up the React tree (the
    // host that rendered this Dialog) — without this, hovering/clicking the backdrop would
    // still drive the calendar canvas underneath.
    <div
      className="ui-dlg-backdrop"
      onMouseDown={(e) => { e.stopPropagation(); if (closeOnBackdrop) onClose(); }}
      onMouseMove={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      <div
        ref={cardRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelId}
        tabIndex={-1}
        className={`ui-dlg-card${cardClassName ? " " + cardClassName : ""}`}
        onMouseDown={(e) => e.stopPropagation()}
      >
        {showClose && (
          <button className="ui-dlg-close" onClick={onClose} title="Close" aria-label="Close">
            <X size={15} />
          </button>
        )}
        {title != null && <div className="ui-dlg-title" id={labelId}>{title}</div>}
        {children != null && <div className="ui-dlg-body">{children}</div>}
        {actions != null && <div className={`ui-dlg-actions${actionsClassName ? " " + actionsClassName : ""}`}>{actions}</div>}
      </div>
    </div>,
    document.body,
  );
}
