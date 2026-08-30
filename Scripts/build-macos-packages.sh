#!/usr/bin/env bash
# Builds every folino package that is expected to compile for macOS, in dependency order.
# Reader is deliberately absent: its UIKit scroll host and PencilKit canvas have no macOS
# implementation yet, and Features/Library, whose EditMode-driven selection is woven into view
# signatures rather than call sites (sub-project IIIb of
# docs/superpowers/specs/2026-08-31-macos-app-design.md).
set -euo pipefail

cd "$(dirname "$0")/.."

PACKAGES=(
  Packages/Utility
  Packages/Domain
  Packages/ScoreUI
  Packages/Infrastructure
  Packages/Features/ImportExport
  Packages/Features/Settings
  Packages/Features/Editor
)

failed=()
for pkg in "${PACKAGES[@]}"; do
  echo "==> $pkg"
  if ! swift build --package-path "$pkg"; then
    failed+=("$pkg")
  fi
done

if [ ${#failed[@]} -ne 0 ]; then
  echo "macOS build FAILED for: ${failed[*]}" >&2
  exit 1
fi
echo "All macOS packages built."
