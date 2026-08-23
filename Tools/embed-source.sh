#!/bin/bash
#
# embed-source.sh — regenerate Sources/RadialMenuSource.swift
#
# The "standalone" export hands a colleague ONE file: the component verbatim
# plus the tuning. For the app to emit the component at runtime it has to carry
# a copy of its own source, which is what this generates.
#
# RUN IT BEFORE EVERY BUILD. The build command in README.md does exactly that,
# so the embedded copy cannot drift from the real RadialMenu.swift.
#
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Sources/RadialMenu.swift"
OUT="Sources/RadialMenuSource.swift"

[ -f "$SRC" ] || { echo "embed-source: $SRC not found" >&2; exit 1; }

# The raw-string delimiter must not occur in the payload, or the literal ends early.
if grep -q '"""#' "$SRC"; then
  echo "embed-source: $SRC contains the closing delimiter '\"\"\"#' — cannot embed" >&2
  exit 1
fi

VERSION="$(grep -m1 'EMBED-VERSION:' "$SRC" | sed 's/.*EMBED-VERSION: *//' | tr -d '[:space:]')"
VERSION="${VERSION:-0}"
LINES="$(wc -l < "$SRC" | tr -d '[:space:]')"

{
  echo "//"
  echo "//  RadialMenuSource.swift — GENERATED, DO NOT EDIT"
  echo "//"
  echo "//  A verbatim copy of RadialMenu.swift so the app can emit a self-contained"
  echo "//  export at runtime. Regenerate with Tools/embed-source.sh."
  echo "//"
  echo "//  Source: $SRC  ($LINES lines, EMBED-VERSION $VERSION)"
  echo "//"
  echo ""
  echo "enum RadialMenuSource {"
  echo "    /// Which revision of the component this copy was taken from."
  echo "    static let version = $VERSION"
  echo ""
  echo "    static let component = #\"\"\""
  cat "$SRC"
  echo "\"\"\"#"
  echo "}"
} > "$OUT"

echo "embed-source: wrote $OUT from $SRC ($LINES lines, v$VERSION)"
