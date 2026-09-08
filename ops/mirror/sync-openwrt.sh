#!/usr/bin/env bash
set -euo pipefail

UPSTREAM="${OPENWRT_UPSTREAM:-https://downloads.openwrt.org}"
MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/openwrt}"
PLATFORMS_FILE="${OPENWRT_PLATFORMS_FILE:-}"
DEFAULT_PLATFORMS_FILE="/etc/forkop-mirror/platforms.conf"
LEGACY_ARCH="${OPENWRT_ARCH:-aarch64_cortex-a53}"
LEGACY_TARGET="${OPENWRT_TARGET:-mediatek/filogic}"
# OpenWrt 24 still uses opkg/IPK and keeps package feeds below each exact
# patch release. Discover every 24.10.x by default; an explicit whitespace-
# separated list may be supplied for a constrained one-off synchronization.
IPK_RELEASES="${OPENWRT_IPK_RELEASES:-}"
FORMATS="${OPENWRT_FORMATS:-ipk apk}"
# "all" keeps every available patch release. This is required because routers
# remain pinned to the exact OpenWrt release and kernel ABI they were built for.
RELEASES_TO_KEEP="${OPENWRT_RELEASES_TO_KEEP:-all}"
LOCK_FILE="${OPENWRT_LOCK_FILE:-/run/lock/openwrt-mirror.lock}"
DOWNLOAD_JOBS="${OPENWRT_DOWNLOAD_JOBS:-8}"
PACKAGE_FEEDS="${OPENWRT_PACKAGE_FEEDS:-base luci packages routing telephony video}"
REQUIRED_PACKAGE_FEEDS="${OPENWRT_REQUIRED_PACKAGE_FEEDS:-base luci packages routing}"
PLATFORM_INDEX_TMP=""

exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "OpenWrt mirror sync is already running" >&2
    exit 0
}

mkdir -p "$MIRROR_ROOT/releases"

cleanup() {
    [[ -z "$PLATFORM_INDEX_TMP" ]] || rm -f "$PLATFORM_INDEX_TMP" "${PLATFORM_INDEX_TMP}.sorted"
}
trap cleanup EXIT

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

validate_download_jobs() {
    [[ "$DOWNLOAD_JOBS" =~ ^[1-9][0-9]*$ ]] || {
        echo "OPENWRT_DOWNLOAD_JOBS must be a positive integer" >&2
        return 1
    }
}

PLATFORMS=()
SEEN_PLATFORMS=$'\n'

add_platform() {
    local target="$1"
    local architecture="$2"
    local key="$target|$architecture"

    [[ "$target" =~ ^[a-zA-Z0-9._+-]+/[a-zA-Z0-9._+-]+$ ]] || {
        echo "Invalid OpenWrt target in platform configuration: $target" >&2
        return 1
    }
    [[ "$architecture" =~ ^[a-zA-Z0-9._+-]+$ ]] || {
        echo "Invalid OpenWrt architecture in platform configuration: $architecture" >&2
        return 1
    }
    [[ "$SEEN_PLATFORMS" == *$'\n'"$key"$'\n'* ]] && return 0

    PLATFORMS+=("$target"$'\t'"$architecture")
    SEEN_PLATFORMS+="$key"$'\n'
}

load_platform_file() {
    local config_file="$1"
    local line
    local target
    local architecture
    local extra
    local line_number=0

    [[ -r "$config_file" ]] || {
        echo "OpenWrt platform configuration is not readable: $config_file" >&2
        return 1
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%%#*}"
        read -r target architecture extra <<< "$line"
        [[ -n "${target:-}" ]] || continue
        [[ -n "${architecture:-}" && -z "${extra:-}" ]] || {
            echo "Invalid platform entry at $config_file:$line_number; expected: target architecture" >&2
            return 1
        }
        add_platform "$target" "$architecture"
    done < "$config_file"
}

load_platforms() {
    if [[ -n "$PLATFORMS_FILE" ]]; then
        load_platform_file "$PLATFORMS_FILE"
    elif [[ -n "${OPENWRT_TARGET+x}" || -n "${OPENWRT_ARCH+x}" ]]; then
        add_platform "$LEGACY_TARGET" "$LEGACY_ARCH"
    elif [[ -r "$DEFAULT_PLATFORMS_FILE" ]]; then
        load_platform_file "$DEFAULT_PLATFORMS_FILE"
    else
        add_platform "$LEGACY_TARGET" "$LEGACY_ARCH"
    fi

    (( ${#PLATFORMS[@]} > 0 )) || {
        echo "OpenWrt platform configuration does not contain any platforms" >&2
        return 1
    }
}

mirror_download_file() {
    local source_url="$1"
    local destination="$2"
    local filename="$3"

    wget --quiet --timestamping --no-directories \
        --directory-prefix="$destination" \
        --timeout=30 --tries=5 --waitretry=5 --retry-connrefused \
        --retry-on-http-error=429,500,502,503,504 \
        "${source_url}${filename}" || {
            echo "Failed to mirror ${source_url}${filename} after 5 attempts" >&2
            return 1
        }
}

export -f mirror_download_file

mirror_flat_directory() {
    local source_url="${1%/}/"
    local destination="$2"
    local listing

    mkdir -p "$destination"
    listing="$(curl -fsSL "$source_url")"
    printf '%s\n' "$listing" |
        sed -n 's/.*href="\([^"?#]*\)".*/\1/p' |
        sed '/^$/d; /^\//d; /^[a-zA-Z][a-zA-Z0-9+.-]*:/d; /\/$/d; /^\.\.$/d; /^index\.html/d' |
        sort -u |
        xargs -r -P "$DOWNLOAD_JOBS" -I '{}' \
            bash -c 'mirror_download_file "$@"' _ \
                "$source_url" "$destination" '{}'
}

mirror_directory_tree() {
    local source_url="${1%/}/"
    local destination="$2"
    local directory

    mirror_flat_directory "$source_url" "$destination"
    while IFS= read -r directory; do
        [[ -n "$directory" ]] || continue
        mirror_flat_directory "${source_url}${directory}" "${destination}/${directory%/}"
    done < <(
        curl -fsSL "$source_url" |
            sed -n 's/.*href="\([^"?#]*\/\)".*/\1/p' |
            sed '/^\.\.\/$/d; /^\//d; /^[a-zA-Z][a-zA-Z0-9+.-]*:/d' |
            sort -u
    )
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

sync_release_target() {
    local release="$1"
    local target="$2"
    local target_base="$UPSTREAM/releases/$release/targets/$target"
    local destination="$MIRROR_ROOT/releases/$release/targets/$target"
    local package_index="packages.adb"
    local metadata

    if [[ "$release" == 24.* ]]; then
        package_index="Packages.gz"
    fi

    if ! curl -fsI "$target_base/packages/$package_index" >/dev/null; then
        echo "Required target feed is unavailable: $target_base/packages/$package_index" >&2
        return 1
    fi

    echo "Syncing OpenWrt $release target $target packages"
    mirror_flat_directory "$target_base/packages/" "$destination/packages"

    echo "Syncing OpenWrt $release target $target kernel modules"
    mirror_directory_tree "$target_base/kmods/" "$destination/kmods"

    for metadata in profiles.json sha256sums sha256sums.asc sha256sums.sig version.buildinfo; do
        curl -fsSL "$target_base/$metadata" -o "$destination/$metadata" || true
    done
}

feed_required() {
    [[ " $REQUIRED_PACKAGE_FEEDS " == *" $1 "* ]]
}

sync_package_root() {
    local package_root="$1"
    local package_index="$2"
    local architecture="$3"
    local source_base="$UPSTREAM/releases/$package_root/$architecture"
    local destination="$MIRROR_ROOT/releases/$package_root/$architecture"
    local feed

    for feed in $PACKAGE_FEEDS; do
        if curl -fsI "$source_base/$feed/$package_index" >/dev/null; then
            echo "Syncing OpenWrt $package_root $architecture/$feed"
            mirror_flat_directory "$source_base/$feed/" "$destination/$feed"
        elif feed_required "$feed"; then
            echo "Required architecture feed is unavailable: $source_base/$feed/$package_index" >&2
            return 1
        fi
    done
}

append_platform_index() {
    local target="$1"
    local architecture="$2"
    local release="$3"
    local format="$4"

    printf '%s\t%s\t%s\t%s\n' "$target" "$architecture" "$release" "$format" >> "$PLATFORM_INDEX_TMP"
}

preserve_disabled_format_rows() {
    local current_index="$MIRROR_ROOT/forkop-platforms.tsv"
    local target
    local architecture
    local release
    local format
    local extra
    local key

    [[ -r "$current_index" ]] || return 0
    while read -r target architecture release format extra; do
        [[ -n "${target:-}" && "$target" != \#* ]] || continue
        [[ -n "${architecture:-}" && -n "${release:-}" && -n "${format:-}" && -z "${extra:-}" ]] || continue
        [[ "$format" == "ipk" || "$format" == "apk" ]] || continue
        format_enabled "$format" && continue
        key="$target|$architecture"
        [[ "$SEEN_PLATFORMS" == *$'\n'"$key"$'\n'* ]] || continue
        append_platform_index "$target" "$architecture" "$release" "$format"
    done < "$current_index"
}

publish_platform_index() {
    local sorted_index="${PLATFORM_INDEX_TMP}.sorted"

    {
        printf '# target\tarchitecture\trelease\tformat\n'
        sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$PLATFORM_INDEX_TMP" | sort -u -k3,3V -k1,1 -k2,2 -k4,4
    } > "$sorted_index"
    mv -f "$sorted_index" "$MIRROR_ROOT/forkop-platforms.tsv"
    rm -f "$PLATFORM_INDEX_TMP"
    PLATFORM_INDEX_TMP=""
}

validate_formats
validate_download_jobs
load_platforms
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

PLATFORM_INDEX_TMP="$(mktemp "$MIRROR_ROOT/.forkop-platforms.tsv.XXXXXX")"
preserve_disabled_format_rows
synced_ipk_architectures=$'\n'
synced_apk_architectures=$'\n'

while IFS= read -r release; do
    [[ -n "$release" ]] || continue
    for platform in "${PLATFORMS[@]}"; do
        IFS=$'\t' read -r target architecture <<< "$platform"
        sync_release_target "$release" "$target"
        architecture_key="$release|$architecture"
        if [[ "$synced_ipk_architectures" != *$'\n'"$architecture_key"$'\n'* ]]; then
            sync_package_root "$release/packages" "Packages.gz" "$architecture"
            synced_ipk_architectures+="$architecture_key"$'\n'
        fi
        append_platform_index "$target" "$architecture" "$release" "ipk"
    done
done <<< "$selected_ipk_releases"

while IFS= read -r release; do
    [[ -n "$release" ]] || continue
    series="${release%.*}"
    for platform in "${PLATFORMS[@]}"; do
        IFS=$'\t' read -r target architecture <<< "$platform"
        sync_release_target "$release" "$target"
        architecture_key="$series|$architecture"
        if [[ "$synced_apk_architectures" != *$'\n'"$architecture_key"$'\n'* ]]; then
            sync_package_root "packages-$series" "packages.adb" "$architecture"
            synced_apk_architectures+="$architecture_key"$'\n'
        fi
        append_platform_index "$target" "$architecture" "$release" "apk"
    done
    ln -sfn "../packages-$series" "$MIRROR_ROOT/releases/$release/packages"
done <<< "$selected_releases"

publish_platform_index
printf '%s\n%s\n' "$selected_ipk_releases" "$selected_releases" |
    sed '/^$/d' | sort -Vu > "$MIRROR_ROOT/.managed-releases"
date --iso-8601=seconds > "$MIRROR_ROOT/.last-successful-sync"

echo "OpenWrt mirror sync completed"
