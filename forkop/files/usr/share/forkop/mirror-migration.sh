#!/bin/sh
set -eu

MIRROR_BASE_URL="${FORKOP_MIRROR_BASE_URL:-https://mirror.51343.ru}"
MIRROR_BASE_URL="${MIRROR_BASE_URL%/}"
MIGRATION_ID="mirror_51343_ru_v1"
SETTINGS_SECTION="forkop.settings"
MIGRATION_ROOT="${FORKOP_MIGRATION_ROOT:-}"
APK_BIN="${FORKOP_MIGRATION_APK_BIN:-apk}"
OPKG_BIN="${FORKOP_MIGRATION_OPKG_BIN:-opkg}"
CURL_BIN="${FORKOP_MIGRATION_CURL_BIN:-curl}"
UCI_BIN="${FORKOP_MIGRATION_UCI_BIN:-uci}"

PACKAGE_MANAGER=""
if command -v "$APK_BIN" >/dev/null 2>&1; then
    PACKAGE_MANAGER="apk"
elif command -v "$OPKG_BIN" >/dev/null 2>&1; then
    PACKAGE_MANAGER="opkg"
else
    exit 0
fi

case "$MIRROR_BASE_URL" in
    https://*|http://*) ;;
    *) echo "Invalid Forkop mirror URL: $MIRROR_BASE_URL" >&2; exit 1 ;;
esac

root_path() {
    printf '%s%s\n' "$MIGRATION_ROOT" "$1"
}

TRANSACTION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/forkop-mirror-migration.XXXXXX")"
TRANSACTION_MANIFEST="$TRANSACTION_DIR/manifest"
TRANSACTION_ACTIVE=0
TRANSACTION_COUNT=0
: > "$TRANSACTION_MANIFEST"

rollback_transaction() {
    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0

    while IFS='|' read -r destination backup original_state; do
        [ -n "$destination" ] || continue
        if [ "$original_state" = "absent" ]; then
            rm -f "$destination" 2>/dev/null || true
        elif [ -f "$backup" ]; then
            cp "$backup" "$destination" 2>/dev/null || true
        fi
    done < "$TRANSACTION_MANIFEST"
    TRANSACTION_ACTIVE=0
}

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        rollback_transaction
        echo "Forkop mirror migration failed; package feeds and keys were restored" >&2
    fi
    rm -rf "$TRANSACTION_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

backup_transaction_file() {
    destination="$1"
    backup="$TRANSACTION_DIR/original.$TRANSACTION_COUNT"

    if [ -e "$destination" ]; then
        cp "$destination" "$backup"
        printf '%s|%s|present\n' "$destination" "$backup" >> "$TRANSACTION_MANIFEST"
    else
        printf '%s||absent\n' "$destination" >> "$TRANSACTION_MANIFEST"
    fi
    TRANSACTION_COUNT=$((TRANSACTION_COUNT + 1))
}

rewrite_repository_file() {
    repository_file="$1"
    [ -e "$repository_file" ] || return 0

    temporary="$TRANSACTION_DIR/repository.$TRANSACTION_COUNT.new"
    sed -E \
        -e "s#https?://(downloads|archive)\\.openwrt\\.org/releases/#${MIRROR_BASE_URL}/openwrt/releases/#" \
        -e "s#https?://[^/]+/pub/software/openwrt/releases/#${MIRROR_BASE_URL}/openwrt/releases/#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v?([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/?([[:space:]]|$)#${MIRROR_BASE_URL}/openwrt/releases/\\1/targets/\\2/\\3/packages\\4#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages/packages\\.adb#${MIRROR_BASE_URL}/openwrt/releases/\\1/targets/\\2/\\3/packages/packages.adb#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages\\.adb#${MIRROR_BASE_URL}/openwrt/releases/\\1/packages/\\2/\\3/packages.adb#" \
        "$repository_file" > "$temporary"

    if grep -E 'https?://(downloads|archive)\.openwrt\.org/releases/|https?://[^/]+/pub/software/openwrt/releases/' "$temporary" >/dev/null; then
        echo "Forkop mirror migration could not rewrite every official OpenWrt URL in $repository_file" >&2
        return 1
    fi

    if cmp -s "$repository_file" "$temporary"; then
        rm -f "$temporary"
        return 0
    fi

    backup_transaction_file "$repository_file"
    persistent_backup="${repository_file}.pre-forkop-mirror"
    [ -e "$persistent_backup" ] || cp "$repository_file" "$persistent_backup"
    cp "$temporary" "$repository_file"
    rm -f "$temporary"
}

read_release_value() {
    key="$1"
    release_file="$(root_path /etc/openwrt_release)"

    [ -f "$release_file" ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" "$release_file" 2>/dev/null | head -n 1
}

check_platform_index() {
    release="$(read_release_value DISTRIB_RELEASE)"
    target="$(read_release_value DISTRIB_TARGET)"
    architecture="$(read_release_value DISTRIB_ARCH)"
    format="$PACKAGE_MANAGER"
    [ "$format" != "opkg" ] || format="ipk"

    [ -n "$release" ] && [ -n "$target" ] && [ -n "$architecture" ] || return 0
    platform_index="$TRANSACTION_DIR/forkop-platforms.tsv"
    if ! "$CURL_BIN" -fsSL --connect-timeout 15 --max-time 60 \
        "$MIRROR_BASE_URL/openwrt/forkop-platforms.tsv" -o "$platform_index"; then
        rm -f "$platform_index"
        return 0
    fi

    if awk -v target="$target" -v architecture="$architecture" \
        -v release="$release" -v format="$format" '
            /^[[:space:]]*(#|$)/ { next }
            $1 == target && $2 == architecture && $3 == release && $4 == format { found = 1 }
            END { exit(found ? 0 : 1) }
        ' "$platform_index"; then
        return 0
    fi

    echo "The Forkop mirror does not yet contain $target / $architecture for OpenWrt $release ($format)" >&2
    return 1
}

update_package_index() {
    if [ "$PACKAGE_MANAGER" = "apk" ]; then
        "$APK_BIN" update </dev/null
    else
        "$OPKG_BIN" update </dev/null
    fi
}

check_platform_index
TRANSACTION_ACTIVE=1

repositories="$(root_path /etc/apk/repositories)"
repositories_dir="$(root_path /etc/apk/repositories.d)"
keys_dir="$(root_path /etc/apk/keys)"
opkg_distfeeds="$(root_path /etc/opkg/distfeeds.conf)"

if [ "$PACKAGE_MANAGER" = "apk" ]; then
    rewrite_repository_file "$repositories"
    rewrite_repository_file "$repositories_dir/distfeeds.list"

    mkdir -p "$keys_dir" "$repositories_dir"
    key_file="$keys_dir/forkop-mirror.pem"
    if ! grep -Fq 'BEGIN PUBLIC KEY' "$key_file" 2>/dev/null; then
        key_tmp="$TRANSACTION_DIR/forkop-mirror.pem"
        "$CURL_BIN" -fsSL --connect-timeout 15 --max-time 60 \
            "$MIRROR_BASE_URL/forkop/forkop-apk.pem" -o "$key_tmp"
        grep -Fq 'BEGIN PUBLIC KEY' "$key_tmp" || {
            echo "The downloaded Forkop mirror APK key is invalid" >&2
            exit 1
        }
        backup_transaction_file "$key_file"
        cp "$key_tmp" "$key_file"
        chmod 0644 "$key_file"
    fi

    forkop_repository="$repositories_dir/forkop.list"
    backup_transaction_file "$forkop_repository"
    printf '%s\n' "$MIRROR_BASE_URL/forkop/mirror/current/packages.adb" > "$forkop_repository"
else
    rewrite_repository_file "$opkg_distfeeds"
fi

if [ "$TRANSACTION_COUNT" -gt 0 ]; then
    update_package_index
fi

"$UCI_BIN" -q set "$SETTINGS_SECTION.mirror_base_url=$MIRROR_BASE_URL"
if ! "$UCI_BIN" -q get "$SETTINGS_SECTION.applied_migrations" 2>/dev/null |
    tr ' ' '\n' | grep -Fxq "$MIGRATION_ID"; then
    "$UCI_BIN" -q add_list "$SETTINGS_SECTION.applied_migrations=$MIGRATION_ID"
fi
"$UCI_BIN" -q commit forkop

TRANSACTION_ACTIVE=0
exit 0
