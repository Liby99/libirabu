// The drawer's notes editor: a thin entry that wires the shared CodeMirror note editor
// (noteEditor.ts) to this WKWebView's Swift bridge.
//
// Bridge: Swift → window.CK.{setValue,setMode,setTheme,focus,setCursorLine}; JS → posts to
// window.webkit.messageHandlers.ck ({type:'change'|'preview'|'openLink'|'editAt'|'ready', ...}).

import { createNoteEditor } from "./noteEditor";

function post(msg: any) { (window as any).webkit?.messageHandlers?.ck?.postMessage(msg); }

const ed = createNoteEditor({
  editorEl: document.getElementById("editor")!,
  previewEl: document.getElementById("preview")!,
  placeholder: "Something to note about this event?",
  onChange: (value) => post({ type: "change", value }),
  onPreview: () => post({ type: "preview" }),
  onOpenLink: (url) => post({ type: "openLink", url }),
  onEditAt: (line) => post({ type: "editAt", line }),
});

(window as any).CK = {
  setValue: ed.setValue,
  setMode: ed.setMode,
  focus: ed.focus,
  setCursorLine: ed.setCursorLine,
  setTheme(vars: Record<string, string>) {
    const root = document.documentElement.style;
    for (const k in vars) root.setProperty(k, vars[k]);
  },
};

post({ type: "ready" });
