#!/bin/bash
# Bundle the notes editor into the CalendarUI resources (loaded by the drawer's WKWebView).
# Resolves @codemirror/*, remark-*, katex from the repo-root node_modules (walked up from here),
# and rehype-stringify from webeditor/node_modules. Run: ./build.sh
set -e
cd "$(dirname "$0")"
OUT=../Sources/CalendarUI/Resources/editor

echo "› bundling editor.js + dashboard.js …"
for entry in editor dashboard; do
  npx --yes esbuild "$entry.ts" \
    --bundle --format=iife --platform=browser --target=safari17 \
    --loader:.ts=ts \
    --outfile="$OUT/$entry.js" \
    --log-level=warning
done

echo "› copying html/css + KaTeX assets …"
cp editor.html editor.css dashboard.html dashboard.css "$OUT/"
# KaTeX stylesheet + its fonts (css references ./fonts/*)
cp ../../../node_modules/katex/dist/katex.min.css "$OUT/"
rm -rf "$OUT/fonts" && cp -R ../../../node_modules/katex/dist/fonts "$OUT/fonts"

echo "✓ built → $OUT"
ls -1 "$OUT"
