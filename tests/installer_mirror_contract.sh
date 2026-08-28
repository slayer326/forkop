#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
CONFIG="$ROOT_DIR/forkop/files/etc/config/forkop"

sh -n "$INSTALLER"

grep -Fq 'MIRROR_BASE_URL="${FORKOP_MIRROR_BASE_URL:-https://mirror.51343.ru}"' "$INSTALLER" || {
    echo "installer does not default to the Forkop mirror" >&2
    exit 1
}
grep -Fq 'configure_apk_mirror' "$INSTALLER" || {
    echo "installer does not configure mirrored OpenWrt feeds" >&2
    exit 1
}
grep -Fq 'SING_BOX_INSTALL_VARIANT="tiny"' "$INSTALLER" || {
    echo "installer does not default to sing-box-tiny" >&2
    exit 1
}
grep -Fq "option mirror_base_url 'https://mirror.51343.ru'" "$CONFIG" || {
    echo "packaged Forkop config does not enable the mirror" >&2
    exit 1
}

echo "installer mirror contract tests passed"
