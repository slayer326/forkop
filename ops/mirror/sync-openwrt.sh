#!/usr/bin/env bash
set -euo pipefail

UPSTREAM="${OPENWRT_UPSTREAM:-https://downloads.openwrt.org}"
MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/openwrt}"
ARCH="${OPENWRT_ARCH:-aarch64_cortex-a53}"
TARGET="${OPENWRT_TARGET:-mediatek/filogic}"
# OpenWrt 24 still uses opkg/IPK and keeps package feeds below each exact
# patch release. Discover every 24.10.x by default; an explicit whitespace-
# separated list may be supplied for a constrained one-off synchronization.
IPK_RELEASES="${OPENWRT_IPK_RELEASES:-}"
FORMATS="${OPENWRT_FORMATS:-ipk apk}"
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

format_enabled() {
    [[ " $FORMATS " == *" $1 "* ]]
}

validate_formats() {
    local format

    for format in $FORMATS; do
        [[ "$format" == "ipk" || "$format" == "apk" ]] || {
            echo "OPENWRT_FORMATS contains an unsupported format: $format" >&2
            return 1
        }
    done
    [[ -n "$FORMATS" ]] || {
        echo "OPENWRT_FORMATS must contain ipk, apk, or both" >&2
        return 1
    }
}

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

validate_ipk_releases() {
    local release

    for release in $IPK_RELEASES; do
        [[ "$release" =~ ^24\.10\.[0-9]+$ ]] || {
            echo "OPENWRT_IPK_RELEASES contains an unsupported release: $release" >&2
            return 1
        }
        printf '%s\n' "$release"
    done | sort -Vu
}

discover_ipk_releases() {
    curl -fsSL "$UPSTREAM/releases/" |
        sed -n 's/.*href="\(24\.10\.[0-9][0-9]*\)\/".*/\1/p' |
        sort -Vu
}

select_ipk_releases() {
    if [[ -n "$IPK_RELEASES" ]]; then
        validate_ipk_releases
    else
        discover_ipk_releases
    fi
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
    local package_index="packages.adb"

    if [[ "$release" == 24.* ]]; then
        package_index="Packages.gz"
    fi

    if ! curl -fsI "$target_base/packages/$package_index" >/dev/null; then
        echo "Required target feed is unavailable: $target_base/packages/$package_index" >&2
        return 1
    fi

    echo "Syncing OpenWrt $release target packages"
    mirror_directory "$target_base/packages/" "$destination/packages" 6

    echo "Syncing OpenWrt $release kernel modules"
    mirror_directory "$target_base/kmods/" "$destination/kmods" 6

    for metadata in profiles.json sha256sums sha256sums.asc sha256sums.sig version.buildinfo; do
        curl -fsSL "$target_base/$metadata" -o "$destination/$metadata" || true
    done
}

sync_package_root() {
    local package_root="$1"
    local package_index="$2"
    local cut_dirs=4
    local source_base="$UPSTREAM/releases/$package_root/$ARCH"
    local destination="$MIRROR_ROOT/releases/$package_root/$ARCH"

    if [[ "$package_root" == */* ]]; then
        cut_dirs=5
    fi

    for feed in base luci packages routing telephony video; do
        if curl -fsI "$source_base/$feed/$package_index" >/dev/null; then
            echo "Syncing OpenWrt $package_root $ARCH/$feed"
            mirror_directory "$source_base/$feed/" "$destination/$feed" "$cut_dirs"
        fi
    done
}

sync_ipk_release() {
    local release="$1"

    sync_release "$release"
    sync_package_root "$release/packages" "Packages.gz"
}

validate_formats
all_releases=""
selected_releases=""
selected_ipk_releases=""

if format_enabled apk; then
    all_releases="$(discover_releases)"
    selected_releases="$(select_releases "$all_releases")"
fi
if format_enabled ipk; then
    selected_ipk_releases="$(select_ipk_releases)"
    [[ -n "$selected_ipk_releases" ]] || {
        echo "No OpenWrt 24.10.x releases were discovered" >&2
        exit 1
    }
fi

if format_enabled apk && [[ -z "$selected_releases" ]]; then
    echo "No OpenWrt 25+ releases were discovered" >&2
    exit 1
fi

declare -A synced_series=()
while IFS= read -r release; do
    [[ -n "$release" ]] || continue
    sync_ipk_release "$release"
done <<< "$selected_ipk_releases"

while IFS= read -r release; do
    [[ -n "$release" ]] || continue
    sync_release "$release"
    series="${release%.*}"
    if [[ -z "${synced_series[$series]:-}" ]]; then
        sync_package_root "packages-$series" "packages.adb"
        synced_series[$series]=1
    fi
    ln -sfn "../packages-$series" "$MIRROR_ROOT/releases/$release/packages"
done <<< "$selected_releases"

printf '%s\n%s\n' "$selected_ipk_releases" "$selected_releases" |
    sed '/^$/d' | sort -Vu > "$MIRROR_ROOT/.managed-releases"
date --iso-8601=seconds > "$MIRROR_ROOT/.last-successful-sync"

echo "OpenWrt mirror sync completed"
