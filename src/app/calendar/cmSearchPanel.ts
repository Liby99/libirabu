// A compact, VSCode-style find/replace panel for CodeMirror, docked bottom-right. Replaces
// the library's dated default panel via search({ createPanel }). The replace row is collapsed
// by default and expands via the left chevron (or ⌘⌥F). Built as plain DOM (the createPanel
// contract) and styled by .cc-cm-* rules in calendar.css.

import { EditorView, Panel, ViewUpdate, keymap } from "@codemirror/view";
import { Prec } from "@codemirror/state";
import {
  search, SearchQuery, getSearchQuery, setSearchQuery, openSearchPanel,
  findNext, findPrevious, replaceNext, replaceAll, closeSearchPanel,
} from "@codemirror/search";

// Set by the keymap just before the panel opens: ⌘F → find only, ⌘⌥F → expanded with replace.
let openReplace = false;

const svg = (inner: string) =>
  `<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;
const ICON_CHEVRON = svg(`<path d="m9 6 6 6-6 6"/>`); // points right; CSS rotates it down when expanded
const ICON_UP = svg(`<path d="m6 14 6-6 6 6"/>`);
const ICON_DOWN = svg(`<path d="m6 10 6 6 6-6"/>`);
const ICON_X = svg(`<path d="M6 6 18 18M18 6 6 18"/>`);
const ICON_REPLACE = svg(`<polyline points="15 10 20 15 15 20"/><path d="M4 4v7a4 4 0 0 0 4 4h12"/>`);
const ICON_REPLACE_ALL = svg(`<path d="m6 7 5 5-5 5M13 7l5 5-5 5"/>`);

function iconBtn(cls: string, title: string, inner: string, onClick: () => void): HTMLButtonElement {
  const b = document.createElement("button");
  b.type = "button"; b.className = cls; b.title = title; b.setAttribute("aria-label", title);
  b.innerHTML = inner;
  b.addEventListener("click", (e) => { e.preventDefault(); onClick(); });
  return b;
}
function toggle(label: string, title: string): HTMLButtonElement {
  const b = document.createElement("button");
  b.type = "button"; b.className = "cc-cm-tog"; b.title = title; b.setAttribute("aria-label", title);
  b.textContent = label;
  return b;
}

function createSearchPanel(view: EditorView): Panel {
  const dom = document.createElement("div");
  dom.className = "cc-cm-search";
  dom.addEventListener("mousedown", (e) => e.stopPropagation()); // keep the drawer's listeners out

  const findField = document.createElement("input");
  findField.className = "cc-cm-input"; findField.placeholder = "Find";
  findField.setAttribute("main-field", "true"); // openSearchPanel focuses this

  const replaceField = document.createElement("input");
  replaceField.className = "cc-cm-input"; replaceField.placeholder = "Replace";

  const caseTog = toggle("Aa", "Match Case");
  const wordTog = toggle("\\b", "Match Whole Word");
  const reTog = toggle(".*", "Use Regular Expression");

  const buildQuery = () => new SearchQuery({
    search: findField.value,
    replace: replaceField.value,
    caseSensitive: caseTog.classList.contains("on"),
    wholeWord: wordTog.classList.contains("on"),
    regexp: reTog.classList.contains("on"),
  });
  const commit = () => view.dispatch({ effects: setSearchQuery.of(buildQuery()) });

  findField.addEventListener("input", commit);
  replaceField.addEventListener("input", commit);
  for (const tg of [caseTog, wordTog, reTog]) {
    tg.addEventListener("click", () => { tg.classList.toggle("on"); commit(); findField.focus(); });
  }

  const count = document.createElement("span");
  count.className = "cc-cm-count";

  // left chevron — collapse/expand the replace row
  const expand = iconBtn("cc-cm-expand", "Toggle Replace", ICON_CHEVRON, () => {
    const on = dom.classList.toggle("expanded");
    (on ? replaceField : findField).focus();
  });

  const prev = iconBtn("cc-cm-btn", "Previous match (⇧⏎)", ICON_UP, () => findPrevious(view));
  const next = iconBtn("cc-cm-btn", "Next match (⏎)", ICON_DOWN, () => findNext(view));
  const close = iconBtn("cc-cm-btn", "Close (Esc)", ICON_X, () => { closeSearchPanel(view); view.focus(); });
  const repOne = iconBtn("cc-cm-btn", "Replace", ICON_REPLACE, () => replaceNext(view));
  const repAll = iconBtn("cc-cm-btn", "Replace all", ICON_REPLACE_ALL, () => replaceAll(view));

  // find field: input full-width, with the count + toggles overlaid on the right (VSCode-style)
  const findWrap = document.createElement("div"); findWrap.className = "cc-cm-field cc-cm-find-field";
  const overlay = document.createElement("div"); overlay.className = "cc-cm-overlay";
  const togs = document.createElement("div"); togs.className = "cc-cm-toggles";
  togs.append(caseTog, wordTog, reTog);
  overlay.append(count, togs);
  findWrap.append(findField, overlay);

  const repWrap = document.createElement("div"); repWrap.className = "cc-cm-field cc-cm-rep-field";
  repWrap.append(replaceField);

  const findActions = document.createElement("div"); findActions.className = "cc-cm-actions";
  findActions.append(prev, next, close);
  const repActions = document.createElement("div"); repActions.className = "cc-cm-rep-actions";
  repActions.append(repOne, repAll);

  dom.append(expand, findWrap, findActions, repWrap, repActions);

  dom.addEventListener("keydown", (e) => {
    // stopPropagation so Esc closes only the search bar — without it, closing the panel
    // detaches it from .cm-editor before the drawer's window-level Esc guard runs, so that
    // guard fails to match and the whole drawer closes.
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); closeSearchPanel(view); view.focus(); }
    else if (e.key === "Enter") {
      e.preventDefault();
      if (e.target === replaceField) { if (e.shiftKey) replaceAll(view); else replaceNext(view); }
      else if (e.shiftKey) findPrevious(view); else findNext(view);
    }
  });

  // "cur/total" match counter, refreshed on doc/selection/query change.
  const refresh = () => {
    const q = getSearchQuery(view.state);
    if (!q.search || !q.valid) { count.textContent = ""; return; }
    try {
      const cursor = q.getCursor(view.state) as Iterator<{ from: number; to: number }>;
      const sel = view.state.selection.main;
      let total = 0, cur = 0;
      for (let r = cursor.next(); !r.done; r = cursor.next()) {
        total++;
        if (r.value.from === sel.from && r.value.to === sel.to) cur = total;
      }
      count.textContent = `${cur}/${total}`;
    } catch { count.textContent = ""; }
  };

  return {
    dom,
    top: false, // dock at the bottom
    mount() {
      if (openReplace) dom.classList.add("expanded");
      const q = getSearchQuery(view.state);
      if (q.search) findField.value = q.search;
      if (q.replace) replaceField.value = q.replace;
      caseTog.classList.toggle("on", q.caseSensitive);
      wordTog.classList.toggle("on", q.wholeWord);
      reTog.classList.toggle("on", q.regexp);
      refresh();
      findField.focus(); findField.select();
    },
    update(u: ViewUpdate) {
      if (u.docChanged || u.selectionSet || u.transactions.some((tr) => tr.effects.some((e) => e.is(setSearchQuery)))) refresh();
    },
  };
}

// ⌘F → find only; ⌘⌥F → open with the replace row expanded.
const searchKeys = Prec.highest(keymap.of([
  { key: "Mod-f", run: (v) => { openReplace = false; return openSearchPanel(v); } },
  { key: "Mod-Alt-f", run: (v) => { openReplace = true; return openSearchPanel(v); } },
]));

export const cmSearch = [searchKeys, Prec.highest(search({ createPanel: createSearchPanel, top: false }))];
