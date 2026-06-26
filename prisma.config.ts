import "dotenv/config";
import path from "node:path";
import { defineConfig } from "prisma/config";

// Prisma 7 moved the connection URL out of schema.prisma. This config is used
// by the Prisma CLI (migrate / introspect). The runtime client connects via the
// Neon driver adapter in src/lib/prisma.ts instead.
//
// We read process.env directly (rather than prisma's env() helper) so that
// commands which don't need a DB — e.g. `prisma generate` during `next build` —
// don't fail when DATABASE_URL is absent.
export default defineConfig({
  schema: path.join("prisma", "schema.prisma"),
  datasource: {
    url: process.env.DATABASE_URL,
  },
});
