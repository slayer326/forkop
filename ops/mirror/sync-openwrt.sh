#!/usr/bin/env bash
set -euo pipefail

UPSTREAM="${OPENWRT_UPSTREAM:-https://downloads.openwrt.org}"
MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/openwrt}"
ARCH="${OPENWRT_ARCH:-aarch64_cortex-a53}"
TARGET="${OPENWRT_TARGET:-mediatek/filogic}"
# "all" keeps every available patch release. This is required because routers
# remain pinned to the exact OpenWrt release and kernel ABI they were built for.
RELEASES_TO_KEEP="${OPENWRT_RELEASES_TO_KEEP:-all}"
LOCK_FILE="${OPENWRT_LOCK_FILE:-/run/lock/openwrt-mirror.lock}"

exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "OpenWrt mirror sync is already running" >&2
    exit 0
}

mkdir -p "$MIRROR_ROOT/releases"

mirror_directory() {
    local source_url="$1"
    local destination="$2"
    local cut_dirs="$3"

    mkdir -p "$destination"
    wget \
        --mirror \
        --quiet \
        --no-parent \
        --no-host-directories \
        --cut-dirs="$cut_dirs" \
        --reject='index.html*' \
        --directory-prefix="$destination" \
        --timeout=30 \
        --tries=3 \
        "$source_url"
}

discover_releases() {
    curl -fsSL "$UPSTREAM/releases/" |
        sed -n 's/.*href="\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\/".*/\1/p' |
        awk -F. '$1 >= 25' |
        sort -Vu
}

select_releases() {
    local releases="$1"

    if [[ "$RELEASES_TO_KEEP" == "all" ]]; then
        printf '%s\n' "$releases"
        return 0
    fi

    [[ "$RELEASES_TO_KEEP" =~ ^[1-9][0-9]*$ ]] || {
        echo "OPENWRT_RELEASES_TO_KEEP must be 'all' or a positive integer" >&2
        return 1
    }

    printf '%s\n' "$releases" |
        awk -F. -v keep="$RELEASES_TO_KEEP" '
            { series=$1 "." $2; values[series, ++counts[series]]=$0 }
            END {
                for (series in counts) {
                    start=counts[series]-keep+1
                    if (start < 1) start=1
                    for (i=start; i<=counts[series]; i++) print values[series, i]
                }
            }
        ' |
        sort -V
}

sync_release() {
    local release="$1"
    local target_base="$UPSTREAM/releases/$release/targets/$TARGET"
    local destination="$MIRROR_ROOT/releases/$release/targets/$TARGET"

    if ! curl -fsI "$target_base/packages/packages.adb" >/dev/null; then
        echo "Skipping $release: $TARGET APK feed is unavailable" >&2
        return 0
    fi

    echo "Syncing OpenWrt $release target packages"
    mirror_directory "$target_base/packages/" "$destination/packages" 6

    echo "Syncing OpenWrt $release kernel modules"
    mirror_directory "$target_base/kmods/" "$destination/kmods" 6

    for metadata in profiles.json sha256sums sha256sums.asc sha256sums.sig version.buildinfo; do
        curl -fsSL "$target_base/$metadata" -o "$destination/$metadata" || true
    done
}

sync_package_series() {
    local series="$1"
    local package_root="packages-$series"
    local source_base="$UPSTREAM/releases/$package_root/$ARCH"
    local destination="$MIRROR_ROOT/releases/$package_root/$ARCH"

    for feed in base luci packages routing telephony video; do
        if curl -fsI "$source_base/$feed/packages.adb" >/dev/null; then
            echo "Syncing OpenWrt $series $ARCH/$feed"
            mirror_directory "$source_base/$feed/" "$destination/$feed" 4
        fi
    done
}

all_releases="$(discover_releases)"
selected_releases="$(select_releases "$all_releases")"

if [[ -z "$selected_releases" ]]; then
    echo "No OpenWrt 25+ releases were discovered" >&2
    exit 1
fi

declare -A synced_series=()
while IFS= read -r release; do
    [[ -n "$release" ]] || continue
    sync_release "$release"
    series="${release%.*}"
    if [[ -z "${synced_series[$series]:-}" ]]; then
        sync_package_series "$series"
        synced_series[$series]=1
    fi
    ln -sfn "../packages-$series" "$MIRROR_ROOT/releases/$release/packages"
done <<< "$selected_releases"

printf '%s\n' "$selected_releases" > "$MIRROR_ROOT/.managed-releases"
date --iso-8601=seconds > "$MIRROR_ROOT/.last-successful-sync"

echo "OpenWrt mirror sync completed"
