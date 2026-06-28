"use client";

import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import "katex/dist/katex.min.css";

// Read-only render of an event's notes: GitHub-flavored markdown (tables, task lists,
// strikethrough, autolinks) + LaTeX math via KaTeX ($inline$ and $$block$$). No raw HTML
// (react-markdown's safe default). Styled by .cc-dw-md; links open in a new tab.
export default function NotesPreview({ value }: { value: string }) {
  return (
    <div className="cc-dw-md">
      <ReactMarkdown
        remarkPlugins={[remarkGfm, remarkMath]}
        rehypePlugins={[rehypeKatex]}
        components={{
          a: ({ href, children }) => (
            <a href={href} target="_blank" rel="noopener noreferrer">{children}</a>
          ),
        }}
      >
        {value}
      </ReactMarkdown>
    </div>
  );
}
