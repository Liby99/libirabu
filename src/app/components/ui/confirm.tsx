"use client";

// Imperative confirm — a promise-based replacement for window.confirm(), so a call site is
// a one-liner: `if (await confirm({ title: "Delete trip?", confirmLabel: "Delete",
// variant: "danger" })) …`. Mounted once via <ConfirmProvider> (see app/providers.tsx).

import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import { ConfirmDialog } from "./ConfirmDialog";

export interface ConfirmOptions {
  title: string;
  message?: ReactNode;
  confirmLabel?: string; // default "OK"
  cancelLabel?: string; // default "Cancel"
  variant?: "primary" | "danger"; // affirmative button style; default "primary"
}

type ConfirmFn = (opts: ConfirmOptions) => Promise<boolean>;

const ConfirmContext = createContext<ConfirmFn | null>(null);

export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<{ opts: ConfirmOptions; resolve: (v: boolean) => void } | null>(null);

  const confirm = useCallback<ConfirmFn>(
    (opts) => new Promise<boolean>((resolve) => setState({ opts, resolve })),
    [],
  );

  const finish = (v: boolean) => {
    setState((s) => { s?.resolve(v); return null; });
  };

  return (
    <ConfirmContext.Provider value={confirm}>
      {children}
      {state && (
        <ConfirmDialog
          open
          title={state.opts.title}
          message={state.opts.message}
          cancelLabel={state.opts.cancelLabel}
          onCancel={() => finish(false)}
          choices={[{
            label: state.opts.confirmLabel ?? "OK",
            variant: state.opts.variant ?? "primary",
            onClick: () => finish(true),
          }]}
        />
      )}
    </ConfirmContext.Provider>
  );
}

// Returns the imperative confirm(). Throws if used outside <ConfirmProvider>.
export function useConfirm(): ConfirmFn {
  const ctx = useContext(ConfirmContext);
  if (!ctx) throw new Error("useConfirm must be used within <ConfirmProvider>");
  return ctx;
}
