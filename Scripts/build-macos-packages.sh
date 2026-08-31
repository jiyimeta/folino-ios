#!/usr/bin/env bash
# Builds every folino package that is expected to compile for macOS, in dependency order.
#
# Features/Library joined this gate in sub-project IIIb of
# docs/superpowers/specs/2026-08-31-macos-app-design.md: its `EditMode`-driven bulk-selection chrome
# (the Select/Cancel toolbar button, the BulkActionBar safe-area inset, row-tap-toggles-selection) was
# forked behind `#if os(iOS)` and rebuilt on a platform-neutral `isSelecting: Bool`, so there is now a
# signature to gate behind. `List(selection:)` already multi-selects natively on macOS via ⌘/⇧-click.
#
# Library's `.macOS(.v15)` platform declaration also serves double duty as the build floor for
# FolinoLibraryJNI's Android cross-compile graph, whose host tests build on macOS — do not remove it
# even though the package now belongs in this gate for its own sake too.
#
# Reader compiles for macOS (sub-project IIIa) but adds no Mac reading UI yet — its UIKit scroll
# host, PencilKit canvas, and layout-mode screens are gated behind `#if os(iOS)`. A native macOS
# reading surface is sub-project Ⅳ.
set -euo pipefail

cd "$(dirname "$0")/.."

PACKAGES=(
  Packages/Utility
  Packages/Domain
  Packages/ScoreUI
  Packages/Features/Library
  Packages/Infrastructure
  Packages/Features/ImportExport
  Packages/Features/Settings
  Packages/Features/Editor
  Packages/Features/Reader
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
