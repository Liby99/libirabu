"use client";

import CodeMirror, { EditorView } from "@uiw/react-codemirror";
import { markdown } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting, syntaxTree } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
import { Prec } from "@codemirror/state";
import { cmSearch } from "./cmSearchPanel";

interface Props {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
}

const MONO = "var(--font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace)";

// CodeMirror 6 markdown notepad — a lightweight VSCode-ish editor. Comes with a search/replace
// panel (⌘F / ⌘⌥F), line-move (Alt+↑/↓), copy-line (Shift+Alt+↑/↓), multi-cursor, and its own
// undo history. Chrome is themed off the app's CSS variables so it blends into the drawer.
const theme = EditorView.theme({
  "&": { backgroundColor: "transparent", color: "var(--accent-dark)", height: "100%", fontSize: "0.74rem" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: MONO, lineHeight: "1.55" },
  ".cm-content": { padding: "12px 0 40px", caretColor: "var(--accent-dark)" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--accent-dark)" },
  ".cm-gutters": { display: "none" },
  // a translucent tint so selected text stays readable. !important is required: CodeMirror's
  // built-in focused-selection rule (.cm-focused > .cm-scroller > .cm-selectionLayer …) is more
  // specific than a plain theme selector and otherwise wins with its bright default.
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": { backgroundColor: "color-mix(in srgb, var(--highlight) 22%, transparent) !important" },
  ".cm-activeLine": { backgroundColor: "transparent" },
  // a link URL is clickable with ⌘/Ctrl (see openLinks) → underline as the affordance
  ".cm-md-link": { textDecoration: "underline", textUnderlineOffset: "2px" },
  // search/replace panel (custom widget — see cmSearchPanel + .cc-cm-* in calendar.css)
  ".cm-panels, .cm-panels.cm-panels-bottom": { backgroundColor: "transparent", border: "none" },
  ".cm-searchMatch": { backgroundColor: "color-mix(in srgb, var(--highlight) 28%, transparent)" },
  ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: "color-mix(in srgb, var(--highlight) 50%, transparent)" },
});

// Calmer markdown highlighting (the default paints URLs a harsh dark blue). Driven by the
// app's CSS variables so it reads well in both light and dark. Prec.highest so it wins over
// the default highlight style basicSetup installs.
const mdHighlight = Prec.highest(syntaxHighlighting(HighlightStyle.define([
  { tag: t.heading, fontWeight: "700", color: "var(--accent-dark)" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: [t.link, t.url], color: "var(--highlight)", class: "cm-md-link" },
  { tag: t.monospace, fontFamily: MONO, color: "var(--accent-dark)" },
  { tag: t.quote, color: "var(--accent-grey)", fontStyle: "italic" },
  { tag: [t.processingInstruction, t.contentSeparator], color: "var(--accent-grey)" }, // # * - [ ] ( ) marks
])));

// Resolve a clickable URL at a document position: the URL node itself, or the URL child of
// the enclosing markdown Link. Returns the raw href text (sans scheme guard).
function linkAt(view: EditorView, pos: number): string | null {
  const tree = syntaxTree(view.state);
  for (let n: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(pos, -1); n; n = n.parent) {
    if (n.name === "URL") return view.state.sliceDoc(n.from, n.to);
    if (n.name === "Link") {
      const url = n.getChild("URL");
      if (url) return view.state.sliceDoc(url.from, url.to);
    }
  }
  return null;
}

// ⌘/Ctrl-click a markdown link → open it in a new tab (don't move the cursor).
const openLinks = EditorView.domEventHandlers({
  mousedown(e, view) {
    if (!(e.metaKey || e.ctrlKey) || e.button !== 0) return false;
    const pos = view.posAtCoords({ x: e.clientX, y: e.clientY });
    if (pos == null) return false;
    const raw = linkAt(view, pos);
    if (!raw) return false;
    e.preventDefault();
    const href = /^[a-z][a-z0-9+.-]*:/i.test(raw) ? raw : `https://${raw}`;
    window.open(href, "_blank", "noopener,noreferrer");
    return true;
  },
});

export default function NotesEditor({ value, onChange, placeholder }: Props) {
  return (
    <CodeMirror
      className="cc-dw-cm"
      value={value}
      onChange={onChange}
      placeholder={placeholder}
      height="100%"
      theme={theme}
      extensions={[markdown(), EditorView.lineWrapping, mdHighlight, openLinks, cmSearch]}
      basicSetup={{
        // Clean notepad chrome: drop line numbers / fold / active-line / bracket noise, but
        // keep history, the default keymap (line-move etc.) and the search keymap.
        lineNumbers: false,
        foldGutter: false,
        highlightActiveLine: false,
        highlightActiveLineGutter: false,
        autocompletion: false,
        bracketMatching: false,
        closeBrackets: false,
      }}
    />
  );
}
