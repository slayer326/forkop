#!/usr/bin/env bash
set -euo pipefail

GITHUB_REPOSITORY="${SING_BOX_EXTENDED_REPOSITORY:-shtorm-7/sing-box-extended}"
MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/forkop/sing-box-extended}"
LOCK_FILE="${SING_BOX_EXTENDED_LOCK_FILE:-/run/lock/sing-box-extended-mirror.lock}"

exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "sing-box-extended mirror sync is already running" >&2
    exit 0
}

release_json="$(curl -fsSL --retry 3 \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/latest")"
tag="$(jq -r '.tag_name // empty' <<< "$release_json")"

[[ -n "$tag" && "$tag" != *alpha* && "$tag" != *beta* && "$tag" != *-rc* ]] || {
    echo "Latest sing-box-extended release is not stable: $tag" >&2
    exit 1
}

staging="$MIRROR_ROOT/.${tag}.staging"
destination="$MIRROR_ROOT/releases/$tag"
rm -rf "$staging"
mkdir -p "$staging" "$MIRROR_ROOT/releases"

jq -r '.assets[] | select(.name | test("^sing-box-extended_.*_openwrt_.*\\.(apk|ipk)$")) | [.name, .browser_download_url] | @tsv' \
    <<< "$release_json" |
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" && -n "$url" ]] || continue
        curl -fsSL --retry 3 "$url" -o "$staging/$name"
    done

compgen -G "$staging/*.apk" >/dev/null || {
    echo "No sing-box-extended APK assets were mirrored" >&2
    exit 1
}
compgen -G "$staging/*.ipk" >/dev/null || {
    echo "No sing-box-extended IPK assets were mirrored" >&2
    exit 1
}

jq --arg tag "$tag" '
    .html_url = ("/forkop/sing-box-extended/releases/" + $tag + "/")
    | .assets = [
        .assets[]
        | select(.name | test("^sing-box-extended_.*_openwrt_.*\\.(apk|ipk)$"))
        | .browser_download_url = ("/forkop/sing-box-extended/releases/" + $tag + "/" + .name)
      ]
' <<< "$release_json" > "$staging/release.json"

(
    cd "$staging"
    sha256sum ./*.apk ./*.ipk > SHA256SUMS
)

rm -rf "$destination"
mv "$staging" "$destination"
cp "$destination/release.json" "$MIRROR_ROOT/latest.json"
printf '%s\n' "$tag" > "$MIRROR_ROOT/LATEST"

echo "sing-box-extended $tag mirror sync completed"
