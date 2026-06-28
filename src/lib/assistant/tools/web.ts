// Web tools for the assistant (P0): web_search (Tavily, if configured) + web_open
// (fetch + readable-text extraction). Both degrade gracefully when unavailable.

import type { AssistantTool } from "../types";

const MAX_TEXT = 8000; // chars of extracted page text returned to the model

const webSearch: AssistantTool = {
  readOnly: true,
  actionKind: "web_search",
  summarize: (a) => `Searched the web for "${String(a.query ?? "")}"`,
  def: {
    name: "web_search",
    description:
      "Search the web and return a list of result {title, url, snippet}. Use this to find pages (e.g. a conference CFP, an institutional academic calendar) before opening them with web_open.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "The search query." },
        max_results: { type: "integer", description: "How many results (default 5)." },
      },
      required: ["query"],
      additionalProperties: false,
    },
  },
  async run(args) {
    const key = process.env.TAVILY_API_KEY;
    const query = String(args.query ?? "").trim();
    if (!query) throw new Error("query is required");
    if (!key) {
      // Graceful degradation — no search provider configured yet (design §16.1).
      return { available: false, note: "Web search is not configured (set TAVILY_API_KEY)." };
    }
    const max = Number.isInteger(args.max_results) ? (args.max_results as number) : 5;
    const res = await fetch("https://api.tavily.com/search", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ api_key: key, query, max_results: max, search_depth: "basic" }),
    });
    if (!res.ok) throw new Error(`web_search failed (${res.status})`);
    const data = await res.json();
    const results = (data.results ?? []).map((r: { title?: string; url?: string; content?: string }) => ({
      title: r.title ?? "",
      url: r.url ?? "",
      snippet: r.content ?? "",
    }));
    return { results };
  },
};

const webOpen: AssistantTool = {
  readOnly: true,
  actionKind: "web_open",
  summarize: (a) => `Read ${String(a.url ?? "")}`,
  def: {
    name: "web_open",
    description:
      "Fetch a URL and return its readable text {url, title, text}. Use after web_search to read a page's content (truncated).",
    parameters: {
      type: "object",
      properties: { url: { type: "string", description: "The http(s) URL to open." } },
      required: ["url"],
      additionalProperties: false,
    },
  },
  async run(args) {
    const url = String(args.url ?? "").trim();
    if (!/^https?:\/\//i.test(url)) throw new Error("url must be an http(s) URL");
    const res = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; libirabu-assistant/0.1)" },
      redirect: "follow",
    });
    if (!res.ok) throw new Error(`web_open failed (${res.status})`);
    const html = await res.text();
    const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.trim() ?? "";
    const text = htmlToText(html).slice(0, MAX_TEXT);
    return { url: res.url || url, title, text };
  },
};

/** Minimal, dependency-free HTML → text: drop scripts/styles/tags, decode a few entities. */
function htmlToText(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<\/(p|div|section|article|li|tr|h[1-6]|br)>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&quot;/gi, '"')
    .replace(/[ \t\f\v]+/g, " ")
    .replace(/\n\s*\n\s*\n+/g, "\n\n")
    .trim();
}

export const webTools: AssistantTool[] = [webSearch, webOpen];
