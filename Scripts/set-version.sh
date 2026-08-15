#!/usr/bin/env bash
# Stamps a version into the source and promotes the changelog's Unreleased
# section. Idempotent: running it twice with the same version changes nothing
# the second time, which is what lets "prepare release" be re-run.
#
# Usage: Scripts/set-version.sh 1.2.0
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: expected a version like 1.2.0, got '${VERSION}'" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT}/Sources/AgenticCLIKit/Version.swift"
CHANGELOG="${ROOT}/CHANGELOG.md"
TODAY="$(date -u +%Y-%m-%d)"

# 1. The version constant.
/usr/bin/sed -i '' -E "s/public static let version = \".*\"/public static let version = \"${VERSION}\"/" "$VERSION_FILE"
echo "set version to ${VERSION} in Version.swift"

# 2. The changelog: promote Unreleased, unless this version is already there.
if grep -q "^## \[${VERSION}\]" "$CHANGELOG"; then
    echo "changelog already has a ${VERSION} section; leaving it alone"
else
    /usr/bin/sed -i '' -E "s|^## \[Unreleased\]\$|## [Unreleased]\\
\\
## [${VERSION}] - ${TODAY}|" "$CHANGELOG"
    echo "promoted Unreleased to ${VERSION} in CHANGELOG.md"
fi

# 3. Link definitions at the bottom of the changelog.
if ! grep -q "^\[${VERSION}\]:" "$CHANGELOG"; then
    printf '[%s]: https://github.com/messeb/AgenticCLIKit/releases/tag/%s\n' "$VERSION" "$VERSION" >> "$CHANGELOG"
fi
