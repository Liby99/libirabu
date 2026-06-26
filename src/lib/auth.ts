import { getServerSession } from "next-auth/next";
import { redirect } from "next/navigation";
import { authOptions } from "@/app/utils/AuthOptions";

/** Returns the signed-in user's id, or null. Server-side only. */
export async function getCurrentUserId(): Promise<string | null> {
  const session = await getServerSession(authOptions);
  return session?.user?.id ?? null;
}

/** Returns the signed-in user's id, or redirects to the sign-in page. */
export async function requireUserId(): Promise<string> {
  const id = await getCurrentUserId();
  if (!id) redirect("/auth/signin");
  return id;
}
