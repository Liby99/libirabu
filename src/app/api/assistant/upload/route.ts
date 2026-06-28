// POST /api/assistant/upload — accept a PDF / .txt / .md file, extract its text server-side, and
// return { filename, bytes, text }. The client carries the text into the next chat message as
// context (design §10). We don't persist the file in P2.
import { NextRequest, NextResponse } from "next/server";
import { extractText, getDocumentProxy } from "unpdf";
import { requireUser, badRequest, serverError } from "@/app/api/calendar/_helpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BYTES = 20 * 1024 * 1024; // 20 MB
const MAX_TEXT = 16000; // chars of extracted text returned to the model

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;

    const form = await req.formData().catch(() => null);
    const file = form?.get("file");
    if (!(file instanceof File)) return badRequest("no file uploaded");
    if (file.size > MAX_BYTES) return badRequest("file too large (max 20 MB)");

    const name = file.name || "attachment";
    const lower = name.toLowerCase();
    let text = "";
    if (lower.endsWith(".pdf") || file.type === "application/pdf") {
      const pdf = await getDocumentProxy(new Uint8Array(await file.arrayBuffer()));
      const out = await extractText(pdf, { mergePages: true });
      text = Array.isArray(out.text) ? out.text.join("\n") : out.text;
    } else if (lower.endsWith(".txt") || lower.endsWith(".md") || file.type.startsWith("text/")) {
      text = await file.text();
    } else {
      return badRequest("unsupported file type — PDF, .txt, or .md only");
    }

    text = text.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim().slice(0, MAX_TEXT);
    if (!text) return badRequest("no extractable text found in the file");
    return NextResponse.json({ filename: name, bytes: file.size, text });
  } catch (e) {
    return serverError(e);
  }
}
