#!/usr/bin/env bash
# Builds every folino package that is expected to compile for macOS, in dependency order.
#
# Reader and Features/Library are both deliberately absent, for the same reason: neither compiles
# as a macOS product yet, and both are deferred to sub-project IIIb of
# docs/superpowers/specs/2026-08-31-macos-app-design.md. Reader's UIKit scroll host and PencilKit
# canvas have no macOS implementation. Library's EditMode-driven selection is woven into view
# signatures rather than call sites, so there is no signature to gate behind.
#
# Library DOES declare a `.macOS(.v15)` platform in its manifest — but only as a build floor for
# FolinoLibraryJNI's Android cross-compile graph, whose host tests build on macOS. That declaration
# is not evidence the package belongs in this gate.
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
