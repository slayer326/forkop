#!/usr/bin/env bash
set -eo pipefail

workflow="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/build.yml"

if grep -Fiq 'sourceforge' "$workflow"; then
  echo 'Build workflow must leave SourceForge publication to GitHub Integration' >&2
  exit 1
fi

grep -Fq 'uses: softprops/action-gh-release@v2.4.0' "$workflow"
grep -Fq './ops/hosting/prepare-release.sh "$VERSION"' "$workflow"
grep -Fq 'name: timeweb-files-${{ needs.preparation.outputs.version }}' "$workflow"
grep -Fq './filtered-bin/release/*.*' "$workflow"
grep -Fq './filtered-bin/hosting/*.tar.gz' "$workflow"

printf 'release workflow checks passed\n'
