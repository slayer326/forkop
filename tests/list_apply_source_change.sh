#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/runtime" "$WORK_DIR/cache"
export FORKOP_LIB="$LIB" FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/runtime"
export FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/cache"
export FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json"
export TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box"
export PATH="$WORK_DIR/bin:$PATH"

# Planning must not touch the network or live nftables, even for a missing or
# corrupt cache. The fresh download belongs to the background list worker.
for cmd in curl wget nft; do
  printf '#!/bin/sh\nexit 97\n' >"$WORK_DIR/bin/$cmd"
done
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*
set_source() {
  cat >"$FORKOP_UCI_STATE_FILE" <<EOF_UCI
forkop.settings=settings
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/$1.txt
EOF_UCI
}
plan() {
  ucode -L "$LIB" "$LIB/service/lifecycle.uc" reload-list-plan-fixture "${1:-list-content}" "${2:-1}"
}
assert_plan() {
  local expected="$1" output
  output="$(plan "${2:-list-content}" "${3:-1}")"
  node -e '
    const x = JSON.parse(process.argv[1]), expected = process.argv[2], p = x.plan;
    function ok(v, s) { if (!v) throw Error(s + ": " + JSON.stringify(x)); }
    ok(x.reason === expected, "wrong recovery mode");
    if (expected === "pending") {
      ok(p.has_work === 0, "ordinary reload changed");
    } else if (expected === "list-recovery") {
      ok(p.has_work === 1 && p.needs_nft_rebuild === 1, "apply not scheduled");
      ok(p.changed_list === 1 && p.needs_list_update === 1 && p.needs_sing_box_reload === 1,
         "fresh worker must own the final runtime transition");
    } else {
      ok(p.has_work === 1 && p.needs_nft_rebuild === 1, "apply not scheduled");
      ok(p.needs_list_update === 0, "unnecessary network update");
      ok(p.changed_list === (expected === "list-content" ? 0 : 1), "wrong source change");
      if (expected === "list-sources-removed") ok(p.needs_sing_box_reload === 1, "removed source still active");
    }
  ' "$output" "$expected"
}
set_source old
signature="$(ucode -L "$LIB" "$LIB/service/state.uc" list-update-signature)"
printf 'old.example\n' >"$WORK_DIR/runtime/source-1"
source_hash="$(md5sum "$WORK_DIR/runtime/source-1" | cut -d' ' -f1)"
source_size="$(wc -c <"$WORK_DIR/runtime/source-1")"
cat >"$WORK_DIR/runtime/manifest.json" <<EOF_MANIFEST
{"format":"2","generation":"gen-before-edit","signature":"$signature","files":[{"name":"source-1","kind":"source","url":"https://lists.test/old.txt","source_format":"plain","size":$source_size,"md5":"$source_hash"}]}
EOF_MANIFEST
cp -a "$WORK_DIR/runtime/." "$WORK_DIR/cache/"
cp "$WORK_DIR/runtime/manifest.json" "$WORK_DIR/manifest.before"
assert_plan list-content

# Reproduce the report: an apply is pending for A, sources change to B while
# a worker downloads, and the B download fails. A still exists, but may not
# be applied as B. Even an otherwise no-op reload must prepare B afresh.
set_source new
assert_plan list-recovery
cmp "$WORK_DIR/manifest.before" "$WORK_DIR/runtime/manifest.json" || fail "stale runtime cache was modified"
cmp "$WORK_DIR/manifest.before" "$WORK_DIR/cache/manifest.json" || fail "stale persistent cache was modified"
assert_plan pending pending

# Once a complete B generation is committed, queued applies are local again.
new_signature="$(ucode -L "$LIB" "$LIB/service/state.uc" list-update-signature)"
sed -i "s/$signature/$new_signature/; s@old.txt@new.txt@" "$WORK_DIR/runtime/manifest.json"
assert_plan list-content

# A valid flash generation is also usable when RAM is corrupt. Without a
# valid fallback, corruption and absence require fresh downloads, not a
# failing local apply or relaxed validation.
cp -a "$WORK_DIR/runtime/." "$WORK_DIR/cache/"
printf 'corrupt\n' >>"$WORK_DIR/runtime/source-1"
assert_plan list-content
printf 'corrupt\n' >>"$WORK_DIR/cache/source-1"
assert_plan list-recovery
rm "$WORK_DIR/runtime/manifest.json" "$WORK_DIR/cache/manifest.json"
assert_plan list-recovery

# Removal of the final source must not keep downloading or applying A.
assert_plan list-sources-removed list-content 0

# The production decision must precede the first runtime transition. Its
# recovery flags use the existing changed-source path, which skips config
# and nft staging and starts the worker only after reload state is written.
awk '
  /^function reload\(reason/ { inside=1 }
  inside && /reason = plan_pending_list_reload\(/ { gate=NR }
  inside && /let needs_singbox_transition/ { transition=NR }
  inside && /^}/ { exit }
  END { exit gate && transition && gate < transition ? 0 : 1 }
' "$LIB/service/lifecycle.uc" || fail "cache decision runs after runtime staging"
printf 'pending list apply/source change checks passed\n'
