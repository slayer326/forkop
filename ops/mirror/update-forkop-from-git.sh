#!/usr/bin/env bash
set -euo pipefail

GITHUB_REPOSITORY="${FORKOP_GITHUB_REPOSITORY:-slayer326/forkop}"
MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/forkop}"
BUILD_ROOT="${FORKOP_BUILD_ROOT:-/srv/mirror/build/automatic}"
LOCK_FILE="${FORKOP_BUILD_LOCK_FILE:-/run/lock/forkop-git-build.lock}"
PUBLISH_COMMAND="${FORKOP_PUBLISH_COMMAND:-/usr/local/sbin/publish-forkop-feed}"

exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "Forkop Git release build is already running" >&2
    exit 0
}

release_json="$(curl -fsSL --retry 3 \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/latest")"
tag="$(jq -r '.tag_name // empty' <<< "$release_json")"
version="${tag#v}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Latest GitHub release tag is not a stable x.y.z version: $tag" >&2
    exit 1
}

current="$(cat "$MIRROR_ROOT/MIRROR_LATEST" 2>/dev/null || true)"
if [[ "$current" == "$version" ]]; then
    echo "Forkop mirror is already current at $version"
    exit 0
fi

mkdir -p "$BUILD_ROOT"
source_dir="$(mktemp -d "$BUILD_ROOT/source.XXXXXX")"
output_dir="$BUILD_ROOT/output-$version"
cleanup() {
    rm -rf "$source_dir"
}
trap cleanup EXIT

git clone --depth 1 --branch "$tag" \
    "https://github.com/$GITHUB_REPOSITORY.git" "$source_dir"

# Keep mirrored OpenWrt dependencies and built-in lists, while Forkop itself
# follows releases from this GitHub repository.
grep -Fq 'mirror_base_url' "$source_dir/forkop/files/usr/lib/core/constants.uc"
grep -Fq 'slayer326/forkop' "$source_dir/forkop/files/usr/lib/core/constants.uc"

rm -rf "$output_dir"
"$source_dir/build.sh" "$version" "$output_dir"
"$PUBLISH_COMMAND" "$output_dir" "$version"

echo "Forkop GitHub release $version was built, verified, and published"
