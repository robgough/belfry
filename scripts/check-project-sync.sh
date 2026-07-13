#!/bin/bash
#
# Fails the build when Swift sources on disk are missing from the generated
# Xcode project — i.e. a file was added/renamed under the iOS target's source
# dirs without re-running `xcodegen generate`.
#
# BelfryiOS.xcodeproj is a generated artifact (gitignored; produced from
# project.yml). Its per-file list is baked in at `xcodegen generate` time, so a
# file added since the last generate is invisible to Xcode and shows up as a
# baffling "Cannot find type X in scope" error rather than a missing-file one.
# This runs as the target's first build phase so the drift is caught here, with
# an actionable message, instead of downstream.
#
# Runs in Xcode (SRCROOT is set) and standalone (falls back to the git root).
set -euo pipefail

ROOT="${SRCROOT:-$(git rev-parse --show-toplevel)}"
cd "$ROOT"

PBX="BelfryiOS.xcodeproj/project.pbxproj"
[ -f "$PBX" ] || exit 0   # nothing generated yet — nothing to check

# The iOS target compiles exactly these dirs (see project.yml `sources`).
SRC_DIRS="Sources/BelfryKit Sources/BelfryiOS"

# Basenames of every Swift file that should be in the project...
disk="$(find $SRC_DIRS -name '*.swift' 2>/dev/null | sed 's#.*/##' | sort -u)"
# ...vs every Swift file reference the generated project actually contains.
proj="$(grep -oE 'path = [^;]*\.swift' "$PBX" | sed 's#path = ##; s#.*/##; s#"##g' | sort -u)"

missing="$(comm -23 <(printf '%s\n' "$disk") <(printf '%s\n' "$proj"))"

if [ -n "$missing" ]; then
  echo "error: BelfryiOS.xcodeproj is out of sync with the source tree." >&2
  echo "error: On disk but missing from the project (stale .xcodeproj):" >&2
  printf 'error:   %s\n' $missing >&2
  echo "error: Fix: run 'xcodegen generate', then build again." >&2
  exit 1
fi
