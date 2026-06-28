"use client";

import { Children, cloneElement, createElement, isValidElement, type ReactNode, type ReactElement } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import "katex/dist/katex.min.css";

// A GFM task-list line: capture the marker, the [ ]/[x] state, and the rest of the line.
const TASK_RE = /^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\](.*)$/;

interface Props {
  value: string;
  onChange?: (v: string) => void;
  onEditAt?: (line: number) => void; // ⌘/Ctrl-click a block → jump into the editor at its source line
}

const srcLine = (node: unknown) => (node as { position?: { start?: { line?: number } } } | undefined)?.position?.start?.line;

// Render of an event's notes: GFM markdown + LaTeX (KaTeX). No raw HTML. Task checkboxes are
// interactive (each rewrites exactly its own source line, via the list item's AST position).
// ⌘/Ctrl-click any block jumps into the editor at that line (blocks carry data-srcline).
export default function NotesPreview({ value, onChange, onEditAt }: Props) {
  const toggleLine = (line: number) => {
    if (!onChange) return;
    const lines = value.split("\n");
    const m = lines[line - 1]?.match(TASK_RE);
    if (!m) return;
    const checked = m[2].toLowerCase() === "x";
    lines[line - 1] = `${m[1]}[${checked ? " " : "x"}]${m[3]}`;
    onChange(lines.join("\n"));
  };

  // Replace the default disabled task checkbox (at any depth) with an interactive one.
  const patchCheckbox = (children: ReactNode, line: number): ReactNode =>
    Children.map(children, (child) => {
      if (!isValidElement(child)) return child;
      const el = child as ReactElement<{ type?: string; checked?: boolean; children?: ReactNode }>;
      if (child.type === "input" && el.props.type === "checkbox") {
        return <input type="checkbox" className="cc-md-check" checked={!!el.props.checked} disabled={!onChange} onChange={() => toggleLine(line)} />;
      }
      if (el.props.children) return cloneElement(child, {}, patchCheckbox(el.props.children, line));
      return child;
    });

  // Tag a block element with its 1-based source line (so ⌘-click can resolve where to edit).
  const block = (Tag: string) => {
    const C = ({ node, children, className }: { node?: unknown; children?: ReactNode; className?: string }) =>
      createElement(Tag, { className, "data-srcline": srcLine(node) }, children);
    C.displayName = `MdBlock(${Tag})`;
    return C;
  };

  const onContainerClick = (e: React.MouseEvent) => {
    if (!onEditAt || !(e.metaKey || e.ctrlKey)) return;
    const target = e.target as HTMLElement;
    if (target.closest("a, input")) return; // let links / checkboxes do their own thing
    const el = target.closest("[data-srcline]");
    const line = el && Number(el.getAttribute("data-srcline"));
    if (line) { e.preventDefault(); onEditAt(line); }
  };

  return (
    <div className="cc-dw-md" onClick={onContainerClick}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm, remarkMath]}
        rehypePlugins={[rehypeKatex]}
        components={{
          a: ({ href, children }) => (
            <a href={href} target="_blank" rel="noopener noreferrer">{children}</a>
          ),
          li: ({ node, children, className }) => {
            const line = srcLine(node);
            const isTask = typeof className === "string" && className.includes("task-list-item");
            return <li className={className} data-srcline={line}>{isTask && line != null ? patchCheckbox(children, line) : children}</li>;
          },
          p: block("p"),
          h1: block("h1"), h2: block("h2"), h3: block("h3"), h4: block("h4"), h5: block("h5"), h6: block("h6"),
          blockquote: block("blockquote"),
          pre: block("pre"),
        }}
      >
        {value}
      </ReactMarkdown>
    </div>
  );
}
