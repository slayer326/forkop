#!/bin/sh
set -eu

MIRROR_BASE="${1:-${FORKOP_MIRROR_BASE:-https://fold8.ru}}"
DISTFEEDS="/etc/apk/repositories.d/distfeeds.list"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v apk >/dev/null 2>&1 || fail "OpenWrt apk package manager is required"
[ -s "$DISTFEEDS" ] || fail "$DISTFEEDS is missing or empty"

case "$MIRROR_BASE" in
    http://*|https://*) ;;
    *) fail "Mirror URL must start with http:// or https://" ;;
esac
MIRROR_BASE="${MIRROR_BASE%/}"

backup="$DISTFEEDS.forkop-backup-$(date +%Y%m%d-%H%M%S)"
cp "$DISTFEEDS" "$backup"

# Preserve the exact release, target, architecture, and kernel ABI selected by
# the firmware. Only the upstream host/path prefix is changed.
sed -E \
    "s#https?://[^/]+/(pub/software/openwrt/)?releases/#${MIRROR_BASE}/openwrt/releases/#" \
    "$backup" > "$DISTFEEDS"

if grep -E 'https?://[^/]+/(pub/software/openwrt/)?releases/' "$DISTFEEDS" |
    grep -Fv "$MIRROR_BASE/openwrt/releases/" >/dev/null; then
    cp "$backup" "$DISTFEEDS"
    fail "Some OpenWrt feed URLs could not be rewritten; original file restored"
fi

echo "Using mirrored OpenWrt feeds:"
cat "$DISTFEEDS"
apk update || {
    cp "$backup" "$DISTFEEDS"
    fail "apk update failed; original feed configuration restored"
}

version="$(wget -qO- "$MIRROR_BASE/forkop/MIRROR_LATEST")"
[ -n "$version" ] || fail "Unable to determine the mirrored Forkop version"

mkdir -p /etc/apk/keys /etc/apk/repositories.d
wget -q "$MIRROR_BASE/forkop/forkop-apk.pem" -O /etc/apk/keys/forkop-mirror.pem
printf '%s\n' \
    "$MIRROR_BASE/forkop/mirror/current/packages.adb" \
    > /etc/apk/repositories.d/forkop.list

apk update
apk add sing-box forkop luci-app-forkop luci-i18n-forkop-ru

uci set forkop.settings.mirror_base_url="$MIRROR_BASE"
uci commit forkop

echo "Forkop $version was installed from $MIRROR_BASE"
echo "Original APK feeds backup: $backup"
