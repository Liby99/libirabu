// remark plugin: render the §17.1 TODO token DSL as inline badges in the notes preview.
//
// This is a thin RENDERING adapter — it reuses the token regexes from the tokenizer
// (`src/lib/assistant/tools/todos.ts`) so the preview and the TODO index can never disagree about
// what a token means. It does NOT re-implement the grammar.
//
// Scope (locked with the user):
//   - todo-semantic tokens (priority/due/start/tz/done/color) render as badges ONLY inside
//     `- [ ]` task-list items — they belong to a checkbox and would be noise in prose.
//   - `#tag`, `@person`, `@type:slug` chip ANYWHERE in a note (they read fine in prose too).
//   - links are left to native markdown rendering (they're already `link` nodes).
//
// Mechanism: `mdast-util-find-and-replace` walks `text` nodes only, skips `link`/`code` subtrees,
// and swaps each token match for a custom node carrying `data.hName:"span"` so mdast→hast renders
// it as `<span class="cc-todo-tok …" data-tok="…">`. CSS in calendar.css styles the chips.

import { visit } from "unist-util-visit";
import { findAndReplace, type ReplaceFunction } from "mdast-util-find-and-replace";
import type { Root, ListItem, PhrasingContent } from "mdast";
import {
  PRIORITY_RE, DUE_RE, START_RE, TZ_RE, COLOR_RE, DONE_RE, CREATED_RE, FOLLOWUP_RE, TAG_RE, ENTITY_RE, MAX_PRIORITY,
} from "@/lib/assistant/tools/todos";

// find-and-replace needs global regexes (it iterates via lastIndex). Clone the tokenizer's
// patterns with the /g flag so the source of truth stays a single definition.
const g = (re: RegExp) => new RegExp(re.source, "g");

// Build a badge node. `boundary` is the leading whitespace/line-start the token regex consumed —
// we re-emit it as text so spacing survives. The badge itself is a custom node that mdast→hast
// turns into a <span> via data.hName.
function badge(
  type: string,
  label: string,
  boundary: string,
  opts?: { extra?: Record<string, string>; classes?: string[] },
): PhrasingContent[] {
  const span = {
    type: "todoToken",
    children: [{ type: "text", value: label }],
    data: {
      hName: "span",
      hProperties: {
        className: ["cc-todo-tok", `cc-todo-tok-${type}`, ...(opts?.classes ?? [])],
        "data-tok": type,
        ...opts?.extra,
      },
    },
  } as unknown as PhrasingContent;
  return boundary ? [{ type: "text", value: boundary } as PhrasingContent, span] : [span];
}

// Priority/due/etc — only meaningful on a checkbox line.
const todoReplacers: Array<[RegExp, ReplaceFunction]> = [
  [g(PRIORITY_RE), (_m, b: string, bangs: string) => {
    const level = Math.min(MAX_PRIORITY, bangs.length);
    return badge("priority", "!".repeat(level), b, { extra: { "data-level": String(level) } });
  }],
  [g(DUE_RE), (_m, b: string, v: string) => badge("due", v, b, { extra: { "data-val": v } })],
  [g(START_RE), (_m, b: string, v: string) => badge("start", v, b, { extra: { "data-val": v } })],
  [g(TZ_RE), (_m, b: string, v: string) => badge("tz", v, b, { extra: { "data-val": v } })],
  // the color swatch reuses the calendar palette: `cc-ev-<key>` exposes `--ev-color`.
  [g(COLOR_RE), (_m, b: string, v: string) => badge("color", v, b, { extra: { "data-val": v }, classes: [`cc-ev-${v}`] })],
  [g(DONE_RE), (_m, b: string, v: string) => badge("done", v, b, { extra: { "data-val": v } })],
  [g(CREATED_RE), (_m, b: string, v: string) => badge("created", v, b, { extra: { "data-val": v } })],
  [g(FOLLOWUP_RE), (_m, b: string, v: string) => badge("followup", v, b, { extra: { "data-val": v } })],
];

// Tags + entities — render anywhere.
const refReplacers: Array<[RegExp, ReplaceFunction]> = [
  [g(TAG_RE), (_m, b: string, slug: string) => badge("tag", `#${slug}`, b)],
  [g(ENTITY_RE), (_m, b: string, type: string | undefined, slug: string) => {
    const t = (type ?? "person").toLowerCase();
    const label = t === "person" ? `@${slug}` : `@${t}:${slug}`;
    return badge("entity", label, b, { extra: { "data-entity": t } });
  }],
];

// Don't descend into links (their label text isn't a token) or our own badges (avoid re-nesting).
const IGNORE = ["link", "linkReference", "todoToken"];

export default function remarkTodoTokens() {
  return (tree: Root) => {
    // 1) Inside task-list items: the full token set.
    visit(tree, "listItem", (node: ListItem) => {
      if (node.checked === null || node.checked === undefined) return; // not a checkbox item
      findAndReplace(node, [...todoReplacers, ...refReplacers], { ignore: IGNORE });
    });
    // 2) Everywhere else: tags + entities only. Task-item refs are already badges (ignored), so
    //    this pass just catches #/@ in prose, headings, non-task lists, etc.
    findAndReplace(tree, refReplacers, { ignore: IGNORE });
  };
}
