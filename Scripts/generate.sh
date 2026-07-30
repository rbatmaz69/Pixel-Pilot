#!/bin/bash
#
# Regenerates PixelPilot.xcodeproj from project.yml.
#
# The .xcodeproj is generated and not checked in: it is a large machine-written
# file that changes whenever a source file is added, and it merges badly. Run
# this after adding, moving or removing files.
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --quiet
echo "Generated PixelPilot.xcodeproj"
