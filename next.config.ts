import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // node-ical pulls in rrule-temporal → @js-temporal/polyfill, whose global setup breaks when the
  // bundler mangles it (TypeError: e.BigInt is not a function). Keep it external so it's required
  // from node_modules at runtime instead of bundled. (Server-only; used by the .ics import route.)
  serverExternalPackages: ["node-ical"],
};

export default nextConfig;
