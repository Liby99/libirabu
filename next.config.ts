import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Self-contained production server for the desktop bundle: `next build` emits .next/standalone/server.js
  // + a traced minimal node_modules, which the packaged app runs directly (no `next start`, no full deps).
  output: "standalone",
  // node-ical pulls in rrule-temporal → @js-temporal/polyfill, whose global setup breaks when the
  // bundler mangles it (TypeError: e.BigInt is not a function). Keep it external so it's required
  // from node_modules at runtime instead of bundled. (Server-only; used by the .ics import route.)
  serverExternalPackages: ["node-ical"],
  // Standalone tracing doesn't follow the FULL transitive tree of an external package, so node-ical's
  // temporal deps go missing and the server 500s at startup. Force its closure into the bundle.
  // (The desktop build script also copies these, as belt-and-suspenders.)
  outputFileTracingIncludes: {
    "/**": [
      "node_modules/node-ical/**",
      "node_modules/rrule-temporal/**",
      "node_modules/temporal-polyfill/**",
      "node_modules/temporal-spec/**",
      "node_modules/@js-temporal/polyfill/**",
      "node_modules/jsbi/**",
    ],
  },
};

export default nextConfig;
