"use client";

// Declarative confirm/alert built on Dialog. Drive it from existing component state (the
// calendar confirms do this). For one-off "are you sure?" prompts, prefer the imperative
// useConfirm() hook instead — it's a one-liner.

import { useEffect, useRef, type ReactNode } from "react";
import { Dialog, DialogButton, type BtnVariant } from "./Dialog";

export interface ConfirmChoice {
  label: ReactNode;
  variant?: BtnVariant; // defaults to "primary"
  onClick: () => void;
}

interface ConfirmDialogProps {
  open: boolean;
  onCancel: () => void;
  title: ReactNode;
  message?: ReactNode;
  choices: ConfirmChoice[]; // the affirmative action(s), shown after Cancel
  cancelLabel?: string; // default "Cancel"; ignored when `closeAsX` is set
  closeAsX?: boolean; // show a top-right × instead of a Cancel button (for multi-choice cards)
  spread?: boolean; // stretch choices to share the row evenly (multi-choice)
  compact?: boolean;
}

export function ConfirmDialog({
  open,
  onCancel,
  title,
  message,
  choices,
  cancelLabel = "Cancel",
  closeAsX,
  spread,
  compact,
}: ConfirmDialogProps) {
  // Enter confirms — but only for a single-affirmative confirm (a binary yes/no). Multi-choice
  // dialogs (e.g. recurring-delete scope) have no safe default, so Enter does nothing there.
  // (Escape/backdrop-cancel are handled by <Dialog>.)
  const choicesRef = useRef(choices);
  choicesRef.current = choices;
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Enter") return;
      const cs = choicesRef.current;
      if (cs.length !== 1) return;
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "BUTTON" || t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      e.preventDefault();
      cs[0].onClick();
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [open]);

  const actions = (
    <>
      {!closeAsX && <DialogButton variant="ghost" onClick={onCancel}>{cancelLabel}</DialogButton>}
      {choices.map((c, i) => (
        <DialogButton key={i} variant={c.variant ?? "primary"} onClick={c.onClick}>{c.label}</DialogButton>
      ))}
    </>
  );
  return (
    <Dialog
      open={open}
      onClose={onCancel}
      title={title}
      actions={actions}
      actionsClassName={spread ? "ui-dlg-actions--spread" : undefined}
      cardClassName={compact ? "ui-dlg--compact" : undefined}
      showClose={closeAsX}
    >
      {message != null && <p className="ui-dlg-msg">{message}</p>}
    </Dialog>
  );
}
