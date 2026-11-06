#!/bin/bash
# Publishes Remote Keeper for Windows on GitHub Releases: builds both .exe files (build.sh) and
# creates the release vX.Y.Z (the version in Core.cs) with them, marked NOT latest, so the Mac app's
# updater (which reads releases/latest) keeps seeing the newest Mac release. Windows copies find
# their update by looking through recent releases for Remote-Keeper-Windows-<arch>.exe.
# Usage: ./release.sh notes.md      (needs gh, logged in, and the private build.env for the relay)
set -euo pipefail
cd "$(dirname "$0")"
NOTES="${1:?release notes file}"
VERSION=$(sed -n 's/.*public const string Version = "\([0-9.]*\)".*/\1/p' Core.cs)
./build.sh
gh release create "v$VERSION" build/Remote-Keeper-Windows-arm64.exe build/Remote-Keeper-Windows-x64.exe \
  --repo mannyd209/remote-keeper --title "Remote Keeper $VERSION for Windows" --notes-file "$NOTES" --latest=false
gh api "repos/mannyd209/remote-keeper/releases/tags/v$VERSION" --jq '.assets[] | .name + "  " + .digest'
echo "Latest (Mac) release is still: $(gh api repos/mannyd209/remote-keeper/releases/latest --jq .tag_name)"
