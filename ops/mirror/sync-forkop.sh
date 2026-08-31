#!/usr/bin/env bash
set -euo pipefail

GITHUB_REPOSITORY="${FORKOP_GITHUB_REPOSITORY:-Screamshow/forkop}"
MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/forkop}"
LOCK_FILE="${FORKOP_LOCK_FILE:-/run/lock/forkop-mirror.lock}"
INSTALLER_OVERRIDE="${FORKOP_INSTALLER_OVERRIDE:-/usr/local/share/forkop/install.sh}"

exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "Forkop mirror sync is already running" >&2
    exit 0
}

release_json="$(curl -fsSL --retry 3 \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/latest")"
tag="$(jq -r '.tag_name // empty' <<< "$release_json")"
version="${tag#v}"

if [[ -z "$tag" || -z "$version" ]]; then
    echo "Unable to determine the latest Forkop release" >&2
    exit 1
fi

staging="$MIRROR_ROOT/.release-$version.staging"
destination="$MIRROR_ROOT/releases/$version"
rm -rf "$staging"
mkdir -p "$staging" "$MIRROR_ROOT/releases"

jq -r '.assets[] | select(.name | test("\\.(apk|ipk)$|^SHA256SUMS$|^RELEASE_NOTES\\.md$")) | [.name, .browser_download_url] | @tsv' \
    <<< "$release_json" |
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" && -n "$url" ]] || continue
        curl -fsSL --retry 3 "$url" -o "$staging/$name"
    done

for required in \
    "forkop_${version}.apk" \
    "luci-app-forkop_${version}.apk" \
    "forkop_${version}.ipk" \
    "luci-app-forkop_${version}.ipk"; do
    [[ -s "$staging/$required" ]] || {
        echo "Required Forkop release asset is missing: $required" >&2
        exit 1
    }
done

curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$tag/install.sh" \
    -o "$staging/install.sh"
if [[ -s "$INSTALLER_OVERRIDE" ]]; then
    cp "$INSTALLER_OVERRIDE" "$staging/install.sh"
fi

date --iso-8601=seconds > "$staging/.mirrored-at"
rm -rf "$destination"
mv "$staging" "$destination"
ln -sfn "releases/$version" "$MIRROR_ROOT/latest"
cp "$destination/install.sh" "$MIRROR_ROOT/install.sh"
printf '%s\n' "$version" > "$MIRROR_ROOT/LATEST"

echo "Forkop $version mirror sync completed"
