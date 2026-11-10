#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export RELEASE_VERSION=0.0.0
make_dir() { mkdir -p "$1"; }
normalize_package_root_modes() { :; }
body="$(awk '/^build_backend_root\(\) \{/ {copy=1} copy {print} copy && /^\}/ {exit}' "$ROOT_DIR/build.sh")"
[ -n "$body" ] || { echo 'backend packaging function missing' >&2; exit 1; }
eval "$body"
build_backend_root "$WORK/root"
test -r "$WORK/root/usr/lib/forkop/warp/profile.uc"
test -r "$WORK/root/usr/lib/forkop/warp/service.uc"
test "$(stat -c %a "$WORK/root/usr/libexec/rpcd/forkop-warp")" = 755
sh "$WORK/root/usr/libexec/rpcd/forkop-warp" list >"$WORK/methods.json"
node - "$WORK/methods.json" <<'JS'
const assert=require('node:assert/strict'), methods=require(process.argv[2]);
assert.deepEqual(Object.keys(methods).sort(),['ack','capabilities','job','start','status']);
assert.equal(methods.start.profile,'');
assert.equal(methods.start.accept_terms,true);
JS
printf 'WARP package contents and RPC schema passed\n'
