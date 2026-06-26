import nextCoreWebVitals from "eslint-config-next/core-web-vitals";
import nextTypescript from "eslint-config-next/typescript";

const eslintConfig = [
  {
    // electron.js is the Electron main process (CommonJS, Node) — not part of
    // the Next app; generated/build output is not ours to lint.
    ignores: [
      ".next/**",
      "node_modules/**",
      "src/generated/**",
      "out/**",
      "electron.js",
    ],
  },
  ...nextCoreWebVitals,
  ...nextTypescript,
  {
    // eslint-config-next 16 enabled the React Compiler-aware react-hooks rules.
    // They surface pre-existing patterns worth revisiting, but are advisory for
    // now and must not block linting. Downgrade to warnings.
    rules: {
      "react-hooks/set-state-in-effect": "warn",
      "react-hooks/refs": "warn",
      "react-hooks/preserve-manual-memoization": "warn",
    },
  },
];

export default eslintConfig;
