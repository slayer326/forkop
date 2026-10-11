#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
ACTION="$LIB/components/action.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir "$WORK/payload"
printf '%s\n' 'compressed sing-box fixture' >"$WORK/payload/sing-box"
printf '%s\n' 'cronet fixture' >"$WORK/payload/libcronet.so"
tar -czf "$WORK/payload.tar.gz" -C "$WORK/payload" sing-box libcronet.so
expected="$(wc -c <"$WORK/payload/sing-box" | tr -d '[:space:]')"
library="$(wc -c <"$WORK/payload/libcronet.so" | tr -d '[:space:]')"
measured="$(ucode -L "$LIB" "$ACTION" archive-payload-bytes-fixture "$WORK/payload.tar.gz" sing-box libcronet.so)"
[ "$measured" = "$((expected + library))" ] || {
    echo "FAIL: archive payload size: expected $((expected + library)), got $measured" >&2
    exit 1
}
ucode -L "$LIB" "$ACTION" archive-install-fixture "$WORK/payload.tar.gz" sing-box "$WORK/installed"
cmp "$WORK/payload/sing-box" "$WORK/installed"
[ -x "$WORK/installed" ]
if ucode -L "$LIB" "$ACTION" archive-install-fixture "$WORK/payload.tar.gz" missing "$WORK/installed"; then
    echo 'FAIL: missing archive member was accepted' >&2
    exit 1
fi
cmp "$WORK/payload/sing-box" "$WORK/installed"
echo 'compressed sing-box archive staging checks passed'
