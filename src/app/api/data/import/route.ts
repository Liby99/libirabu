// POST /api/data/import — restore from a backup .zip. DESTRUCTIVE: wipes every table and rebuilds
// it from the file. Body is multipart/form-data with a single `file` field.
import { NextRequest, NextResponse } from "next/server";
import { requireUser, badRequest, serverError } from "@/app/api/calendar/_helpers";
import { restoreFromZip, BackupError } from "@/lib/backup";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;

    const form = await req.formData().catch(() => null);
    const file = form?.get("file");
    if (!(file instanceof File)) return badRequest("a .zip file is required (field 'file')");
    const bytes = new Uint8Array(await file.arrayBuffer());

    try {
      return NextResponse.json(await restoreFromZip(bytes));
    } catch (e) {
      if (e instanceof BackupError) return badRequest(e.message);
      throw e;
    }
  } catch (e) {
    return serverError(e);
  }
}
