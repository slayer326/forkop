#!/usr/bin/env bash
set -euo pipefail

MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/forkop/lists}"
LOCK_FILE="${LISTS_LOCK_FILE:-/run/lock/forkop-lists-mirror.lock}"
STAGING="${MIRROR_ROOT}.staging"

exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "Forkop list sync is already running" >&2
    exit 0
}

rm -rf "$STAGING"
mkdir -p "$STAGING"

download_github_tree() {
    local owner="$1"
    local repository="$2"
    local ref="$3"
    local destination="$4"
    local archive

    mkdir -p "$destination"
    archive="$(mktemp)"
    curl -fsSL --retry 3 \
        "https://codeload.github.com/$owner/$repository/tar.gz/refs/heads/$ref" \
        -o "$archive"
    tar -xzf "$archive" --strip-components=1 -C "$destination"
    rm -f "$archive"
}

# Source lists used by Forkop's built-in domains and subnet presets.
download_github_tree "itdoginfo" "allow-domains" "main" "$STAGING/allow-domains"
download_github_tree "Greeg0ry" "b4geoip-forkop" "main" "$STAGING/b4geoip-forkop"

mkdir -p "$STAGING/rulesets"
mkdir -p "$STAGING/rulesets/community"
curl -fsSL --retry 3 \
    "https://api.github.com/repos/itdoginfo/allow-domains/releases/latest" |
    jq -r '.assets[] | select(.name | endswith(".srs")) | [.name, .browser_download_url] | @tsv' |
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" && -n "$url" ]] || continue
        curl -fsSL --retry 3 "$url" -o "$STAGING/rulesets/community/$name"
    done
curl -fsSL --retry 3 \
    "https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs" \
    -o "$STAGING/rulesets/adlist.srs"
curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs" \
    -o "$STAGING/rulesets/supercell.srs"
curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs" \
    -o "$STAGING/rulesets/github.srs"

date --iso-8601=seconds > "$STAGING/.last-successful-sync"
rm -rf "${MIRROR_ROOT}.previous"
[[ ! -d "$MIRROR_ROOT" ]] || mv "$MIRROR_ROOT" "${MIRROR_ROOT}.previous"
mv "$STAGING" "$MIRROR_ROOT"

echo "Forkop list sync completed"
