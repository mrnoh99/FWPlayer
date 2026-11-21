#!/usr/bin/env bash
# Bumps the build number (CURRENT_PROJECT_VERSION) in project.yml and in the
# committed Xcode project, so no xcodegen run is needed.
#
#   scripts/bump-build.sh        # current + 1
#   scripts/bump-build.sh 12     # set to 12
set -euo pipefail
cd "$(dirname "$0")/.."

current=$(grep -E '^[[:space:]]+CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([0-9]+)".*/\1/')
new=${1:-$((current + 1))}
[[ "$new" =~ ^[0-9]+$ ]] || { echo "build number must be an integer" >&2; exit 1; }

sed -i.bak -E "s/(CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\1\"$new\"/" project.yml
for pbx in ./*.xcodeproj/project.pbxproj; do
  sed -i.bak -E "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\1$new;/" "$pbx"
  rm -f "$pbx.bak"
done
rm -f project.yml.bak

echo "Build number $current -> $new"
