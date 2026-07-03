// GET /api/data/export — download a full backup .zip (database + files + manifest), named
// <app>-<username>-<date>.zip. Single-user app: exports everything.
import { NextResponse } from "next/server";
import { requireUser, serverError } from "@/app/api/calendar/_helpers";
import { buildExportZip } from "@/lib/backup";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const { filename, body } = await buildExportZip();
    return new Response(new Uint8Array(body), {
      headers: {
        "Content-Type": "application/zip",
        "Content-Disposition": `attachment; filename="${filename}"`,
        "Content-Length": String(body.byteLength),
        "Cache-Control": "no-store",
      },
    });
  } catch (e) {
    return serverError(e);
  }
}
