// Reusable CodeMirror note editor + remark/KaTeX preview — the building block shared by the drawer
// (editor.ts) and the daily-dashboard NOTE tab (dashboard.ts). Same theme + markdown highlighting as
// the web's NotesEditor, same remark pipeline (remark-gfm + remark-math + remarkTodoTokens +
// rehype-katex) as NotesPreview. Host wires the callbacks to its own Swift bridge.

import { EditorView, keymap, placeholder as cmPlaceholder, drawSelection } from "@codemirror/view";
import { EditorState, Prec } from "@codemirror/state";
import { history, defaultKeymap, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting, syntaxTree } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkRehype from "remark-rehype";
import rehypeKatex from "rehype-katex";
import rehypeStringify from "rehype-stringify";
import remarkTodoTokens from "../../../src/app/calendar/view/notes/remarkTodoTokens";
import { splitNote, parseManaged } from "../../../src/lib/import/managedNote";

const MONO = "var(--font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace)";

const cmTheme = EditorView.theme({
  "&": { backgroundColor: "transparent", color: "var(--accent-dark)", height: "100%", fontSize: "12px" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: MONO, lineHeight: "1.55" },
  ".cm-content": { padding: "1px 0 12px", caretColor: "var(--accent-dark)" },
  ".cm-line": { padding: "0 2px 0 0" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--accent-dark)" },
  ".cm-gutters": { display: "none" },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {
    backgroundColor: "color-mix(in srgb, var(--highlight) 24%, transparent) !important",
  },
  ".cm-activeLine": { backgroundColor: "transparent" },
  ".cm-md-link": { textDecoration: "underline", textUnderlineOffset: "2px" },
});

const mdHighlight = Prec.highest(syntaxHighlighting(HighlightStyle.define([
  { tag: t.heading, fontWeight: "700", color: "var(--accent-dark)" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: [t.link, t.url], color: "var(--highlight)", class: "cm-md-link" },
  { tag: t.monospace, fontFamily: MONO, color: "var(--accent-dark)" },
  { tag: t.quote, color: "var(--accent-grey)", fontStyle: "italic" },
  { tag: [t.processingInstruction, t.contentSeparator], color: "var(--accent-grey)" },
])));

function linkAt(view: EditorView, pos: number): string | null {
  const tree = syntaxTree(view.state);
  for (let n: any = tree.resolveInner(pos, -1); n; n = n.parent) {
    if (n.name === "URL") return view.state.sliceDoc(n.from, n.to);
    if (n.name === "Link") { const u = n.getChild("URL"); if (u) return view.state.sliceDoc(u.from, u.to); }
  }
  return null;
}

function rehypeSourceLines() {
  const BLOCK = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "li", "ul", "ol", "table", "hr"]);
  const walk = (node: any) => {
    if (node.type === "element" && BLOCK.has(node.tagName) && node.position?.start?.line) {
      node.properties = node.properties || {};
      node.properties.dataSrcline = node.position.start.line;
    }
    (node.children || []).forEach(walk);
  };
  return (tree: any) => walk(tree);
}

const md = unified()
  .use(remarkParse).use(remarkGfm).use(remarkMath).use(remarkTodoTokens)
  .use(remarkRehype).use(rehypeKatex).use(rehypeSourceLines).use(rehypeStringify);

function mdHtml(src: string): string { try { return String(md.processSync(src)); } catch { return ""; } }
const escHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escAttr = (s: string) => escHtml(s).replace(/"/g, "&quot;");

/** Render a note → HTML. An imported "managed block" (§7) renders as a read-only key:value table
 *  (provenance, location, meeting link, organizer, attendees) + description, matching the web drawer;
 *  the user's own text below it renders as normal markdown. Plain notes render straight through. */
export function renderMarkdown(src: string): string {
  const { managed, user } = splitNote(src);
  if (!managed) return mdHtml(src);
  const { fields, description } = parseManaged(managed);
  const rows = fields.map((f) =>
    `<div class="cc-dw-mi-row"><span class="cc-dw-mi-key">${escHtml(f.label)}</span>` +
    `<span class="cc-dw-mi-val">${f.href
      ? `<a href="${escAttr(f.href)}" target="_blank" rel="noopener noreferrer">${escHtml(f.value)}</a>`
      : escHtml(f.value)}</span></div>`).join("");
  const desc = description ? `<div class="cc-dw-mi-desc">${mdHtml(description)}</div>` : "";
  return `<div class="cc-dw-mi">${rows}${desc}</div>${mdHtml(user)}`;
}

export const TASK_RE = /^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\](.*)$/;

export interface NoteEditorHandle {
  setValue(v: string): void;
  setMode(mode: "edit" | "preview"): void;
  focus(): void;
  setCursorLine(line: number): void;
}
export interface NoteEditorOpts {
  editorEl: HTMLElement;
  previewEl: HTMLElement;
  placeholder?: string;
  onChange: (value: string) => void;
  onPreview: () => void;                 // ⌘S in the editor
  onOpenLink: (url: string) => void;     // ⌘-click a link
  onEditAt: (line: number) => void;      // ⌘-click a preview block → edit at that line
  onExit?: () => void;                   // Escape in the editor → hand focus back to the host
}

export function createNoteEditor(o: NoteEditorOpts): NoteEditorHandle {
  const { editorEl, previewEl } = o;
  let applyingRemote = false;   // suppress the change echo while the host sets the value

  const openLinks = EditorView.domEventHandlers({
    mousedown(e, view) {
      if (!(e.metaKey || e.ctrlKey) || (e as MouseEvent).button !== 0) return false;
      const pos = view.posAtCoords({ x: (e as MouseEvent).clientX, y: (e as MouseEvent).clientY });
      if (pos == null) return false;
      const raw = linkAt(view, pos);
      if (!raw) return false;
      e.preventDefault();
      o.onOpenLink(/^[a-z][a-z0-9+.-]*:/i.test(raw) ? raw : `https://${raw}`);
      return true;
    },
  });

  const view = new EditorView({
    parent: editorEl,
    state: EditorState.create({
      doc: "",
      extensions: [
        history(),
        keymap.of([...defaultKeymap, ...historyKeymap]),
        drawSelection(),
        EditorView.lineWrapping,
        markdown(),
        cmTheme,
        mdHighlight,
        openLinks,
        Prec.highest(keymap.of([
          { key: "Mod-s", preventDefault: true, stopPropagation: true, run: () => { o.onPreview(); return true; } },
          { key: "Escape", preventDefault: true, stopPropagation: true, run: () => { o.onExit?.(); return true; } },
        ])),
        cmPlaceholder(o.placeholder ?? "Something to note…"),
        EditorView.updateListener.of((u) => {
          if (u.docChanged && !applyingRemote) o.onChange(u.state.doc.toString());
        }),
      ],
    }),
  });

  function renderPreview() {
    const src = view.state.doc.toString();
    try { previewEl.innerHTML = renderMarkdown(src); }   // managed block → key:value table (§7)
    catch { previewEl.textContent = src; return; }
    const taskLines: number[] = [];
    src.split("\n").forEach((ln, i) => { if (TASK_RE.test(ln)) taskLines.push(i); });
    previewEl.querySelectorAll<HTMLInputElement>('input[type="checkbox"]').forEach((box, i) => {
      box.disabled = false;
      const lineIdx = taskLines[i];
      if (lineIdx == null) return;
      box.addEventListener("change", () => toggleTask(lineIdx));
    });
  }

  function toggleTask(lineIdx: number) {
    const lines = view.state.doc.toString().split("\n");
    const m = lines[lineIdx]?.match(TASK_RE);
    if (!m) return;
    const checked = m[2].toLowerCase() === "x";
    lines[lineIdx] = `${m[1]}[${checked ? " " : "x"}]${m[3]}`;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: lines.join("\n") } });
    renderPreview();
  }

  previewEl.addEventListener("click", (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    const target = e.target as HTMLElement;
    if (target.closest("a, input")) return;
    const el = target.closest("[data-srcline]");
    const line = el ? Number(el.getAttribute("data-srcline")) : 0;
    if (line) { e.preventDefault(); o.onEditAt(line); }
  });

  return {
    setValue(v: string) {
      if (v === view.state.doc.toString()) return;
      applyingRemote = true;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: v } });
      applyingRemote = false;
      if (previewEl.style.display !== "none") renderPreview();
    },
    setMode(mode: "edit" | "preview") {
      const edit = mode === "edit";
      editorEl.style.display = edit ? "" : "none";
      previewEl.style.display = edit ? "none" : "";
      if (!edit) renderPreview();
      // CodeMirror measures its scroll geometry lazily; if it was built while the tab was hidden
      // (display:none) it has stale/zero metrics and won't scroll. Re-measure whenever it's shown.
      else queueMicrotask(() => { view.requestMeasure(); view.focus(); });
    },
    focus() { view.focus(); },
    setCursorLine(line: number) {
      const ln = Math.max(1, Math.min(view.state.doc.lines, Math.round(line)));
      const pos = view.state.doc.line(ln).from;
      view.dispatch({ selection: { anchor: pos }, scrollIntoView: true });
      view.focus();
    },
  };
}
