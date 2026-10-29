#!/usr/bin/env bash
set -euo pipefail

# A restore decides whether someone else edited the configuration while it
# owned the file (UC-023) by comparing the file with the snapshot it wrote.
# The lifecycle inside the reload commits its own shutdown_correctly flag
# through libuci (start_impl, mark_runtime_stopped_clean), and a libuci commit
# rewrites the whole file in uci's form: quotes, indentation and blank lines
# change and comments go. A snapshot of a hand-written configuration is then
# no longer byte-equal after its reload, but it is still the same
# configuration: that rewrite is no edit, and a failed reload of it must end
# in an ordinary recovery. A real edit committed the same way is still one,
# also when the reload ran (the restore then reports it instead of moving
# last-known-working to a configuration that may never have run), and also
# when hashing fails (the check never compares two empty hashes).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
# A call the uci test shim refused fails the test, even one it tolerated.
cleanup() {
  local rc=$?
  uci_cli_report || [ "$rc" != 0 ] || rc=1
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# The lifecycle's commit inside the reload goes through the uci CLI.
# shellcheck source=tests/helpers/uci_cli/select.sh
source "$ROOT_DIR/tests/helpers/uci_cli/select.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }
REAL_UCODE="$(command -v ucode)" || fail "ucode is required"
REAL_SHA="$(command -v sha256sum)" || fail "sha256sum is required"

# The configuration lives under a package name of its own, so neither the
# real uci nor the shim can merge changes staged on the host.
PKG=forkop_rewrite
mkdir -p "$WORK/bin" "$WORK/run" "$WORK/state" "$WORK/etc" "$WORK/uci-save" "$WORK/lc-save" "$WORK/host-save"
export FORKOP_TEST_UCI_SHIM_HOST_SAVEDIR="$WORK/host-save"
export FORKOP_CONFIG_FILE="$WORK/etc/$PKG"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_LIB="$LIB"
export FORKOP_RELOAD_COMMAND="$WORK/reload"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export FORKOP_UCI_SAVEDIR="$WORK/uci-save"
# The reload stub runs with the stubs first on PATH; the uci CLI keeps the
# original one (the test shim runs on the real ucode, not the stub).
ORIG_PATH="$PATH"
export STATE="$WORK/state" PKG UCI_CLI WORK ORIG_PATH

# Guard model (absent | valid) with the contracts of the state query, ensure
# and remove; the validator accepts; health events are logged.
cat >"$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    guard="$(cat "$STATE/guard")"
    case "$4" in
      dpi-transition-guard-state) echo "$guard"; exit 0 ;;
      ensure-dpi-transition-guard) echo valid > "$STATE/guard"; exit 0 ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard"; exit 0 ;;
    esac
    exit 1 ;;
  */config/validator.uc) exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
# sha256sum breaks once $STATE/sha-broken exists (a full tmpfs, a failing tool).
cat >"$WORK/bin/sha256sum" <<STUB
#!/bin/sh
[ ! -e "\$STATE/sha-broken" ] || exit 1
exec "$REAL_SHA" "\$@"
STUB
# Reload steps are consumed one per call from $STATE/plan. Each is
# <commit>:<exit code>: "flag" commits only the lifecycle's shutdown_correctly
# flag through uci (what start_impl and mark_runtime_stopped_clean do), "edit"
# commits that flag and a changed marker (another writer), "edit+sha" does the
# same and breaks sha256sum first, "none" writes nothing. The file as the
# first reload left it is copied to $STATE/reloaded.
cat >"$WORK/reload" <<'STUB'
#!/bin/sh
set -- $(cat "$STATE/plan")
step="${1:-none:0}"; [ $# -eq 0 ] || shift
echo "$*" > "$STATE/plan"
echo "reload:$step" >> "$STATE/events"
uci() { PATH="$ORIG_PATH" "$UCI_CLI" -c "$WORK/etc" -t "$WORK/lc-save" "$@" >/dev/null; }
case "${step%%:*}" in
  flag) uci set "$PKG.settings.shutdown_correctly=1"; uci commit "$PKG" ;;
  edit|edit+sha)
    [ "${step%%:*}" = edit ] || touch "$STATE/sha-broken"
    uci set "$PKG.settings.shutdown_correctly=1"; uci set "$PKG.settings.marker=edit"; uci commit "$PKG" ;;
esac
[ -e "$STATE/reloaded" ] || cp "$FORKOP_CONFIG_FILE" "$STATE/reloaded"
exit "${step##*:}"
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/sha256sum" "$WORK/reload"

# A hand-written configuration that ran well: comments, double quotes,
# spaces, no blank lines, an option statement without a value (libuci keeps
# the earlier value and writes no such line back). uci writes none of this
# back as it was.
handwritten() {
  cat >"$FORKOP_CONFIG_FILE" <<'CONF'
# Written by hand on the router.
config settings 'settings'
    option dns_server "1.1.1.1"   # upstream resolver
    option dns_server ''
    option unset ''
    option shutdown_correctly 0
    option marker "good"
    list domains 'a.example'
    list domains "b.example"
config section 'Dpi'
    option action zapret
    option nfqws_opt "--filter-tcp=443 --dpi-desync=fake"
CONF
}
# The configuration the restore replaces, as uci writes it.
current() {
  printf "\nconfig settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption shutdown_correctly '0'\n\toption marker '%s'\n\n" "$1" >"$FORKOP_CONFIG_FILE"
}
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined||v===null?"":v)' "$WORK/result.json" "$1"; }
marker() { "$UCI_CLI" -c "$WORK/etc" -t "$WORK/lc-save" get "$PKG.settings.marker"; }
lkg() { cat "$FORKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true; }
reloads() { grep -c '^reload:' "$STATE/events" || true; }
# The first reload's commit really rewrote the hand-written target in uci's
# form (a CLI that did nothing would make scenarios 1 and 2 prove nothing).
rewritten() {
  grep -q "^	option shutdown_correctly '1'$" "$STATE/reloaded" && ! grep -q '^#' "$STATE/reloaded"
}
concurrent_snapshots() { grep -l '"reason": *"concurrent-change"' "$FORKOP_SNAPSHOT_DIR"/*.json 2>/dev/null | wc -l; }
restore() { # restore <reload plan>
  echo absent >"$STATE/guard"; echo "$1" >"$STATE/plan"; : >"$STATE/events"; rm -f "$STATE/sha-broken" "$STATE/reloaded"
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$good_id" >"$WORK/result.json" || true
  rm -f "$STATE/sha-broken"
}

handwritten
good_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
[ -n "$good_id" ] || fail "fixture: the target snapshot was not created"

# 1. The target reload commits the lifecycle's flag (uci rewrites the whole
#    hand-written file) and then fails: no edit, an ordinary recovery.
current bad; cp "$FORKOP_CONFIG_FILE" "$WORK/before"; echo stale >"$FORKOP_SNAPSHOT_DIR/last-known-working"
restore "flag:1 none:0"
rewritten || fail "the lifecycle's commit did not rewrite the target: $(cat "$STATE/reloaded" 2>/dev/null)"
[ "$(field status)" = recovered ] && [ "$(field reason)" = target_reload_failed ] ||
  fail "uci's rewrite of the restored file taken for an edit: $(cat "$WORK/result.json")"
cmp -s "$FORKOP_CONFIG_FILE" "$WORK/before" || fail "the previous configuration was not put back: $(cat "$FORKOP_CONFIG_FILE")"
[ "$(cat "$STATE/guard")" = absent ] && [ "$(reloads)" = 2 ] || fail "recovery: guard $(cat "$STATE/guard"), $(reloads) reloads"
[ "$(concurrent_snapshots)" = 0 ] || fail "a rewrite by uci was saved as an edit"
[ "$(lkg)" = stale ] || fail "last-known-working moved"
ok "hand-written snapshot rewritten by the lifecycle's uci commit, reload failed -> recovered, no bogus edit"

# 2. The same rewrite and a reload that ran: the restore succeeds.
current bad
restore "flag:0"
rewritten || fail "the lifecycle's commit did not rewrite the target: $(cat "$STATE/reloaded" 2>/dev/null)"
[ "$(field status)" = success ] && [ "$(lkg)" = "$good_id" ] || fail "rewritten target that reloaded: $(cat "$WORK/result.json"), lkg $(lkg)"
[ "$(cat "$STATE/guard")" = absent ] && [ "$(concurrent_snapshots)" = 0 ] || fail "rewritten target that reloaded: guard or bogus snapshot"
ok "hand-written snapshot rewritten by uci, reload ran -> success"

# 3. A real edit committed the same way during a failing reload is still an
#    edit: kept, saved, needs_attention, the guard stays.
current bad; echo stale >"$FORKOP_SNAPSHOT_DIR/last-known-working"
restore "edit:1"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "edit committed through uci during a failed reload: $(cat "$WORK/result.json")"
[ "$(marker)" = edit ] && [ "$(reloads)" = 1 ] && [ "$(cat "$STATE/guard")" = valid ] ||
  fail "edit during a failed reload: marker $(marker), $(reloads) reloads, guard $(cat "$STATE/guard")"
[ "$(concurrent_snapshots)" = 1 ] && [ -n "$(field saved_snapshot)" ] || fail "the edit is not saved as a snapshot"
ok "edit committed through uci during a failed reload -> kept, saved, guard kept"

# 4. An edit committed while the target reload ran, and the reload succeeded:
#    the reload may have read the edit rather than the snapshot. The restore
#    is no success and last-known-working does not move to a configuration
#    that may never have run; the edit is kept and saved. A reload ran, so the
#    guard goes.
current bad; echo stale >"$FORKOP_SNAPSHOT_DIR/last-known-working"
restore "edit:0"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "edit committed while the target reload ran: $(cat "$WORK/result.json")"
[ "$(field guard)" = inactive ] && [ "$(cat "$STATE/guard")" = absent ] || fail "a reload ran: the guard must go: $(cat "$WORK/result.json")"
[ "$(marker)" = edit ] && [ "$(reloads)" = 1 ] || fail "edit during a reload that ran: marker $(marker), $(reloads) reloads"
[ "$(lkg)" = stale ] || fail "last-known-working moved to a snapshot the reload may not have run"
saved="$(field saved_snapshot)"
[ -n "$saved" ] && grep -q '"reason": *"concurrent-change"' "$FORKOP_SNAPSHOT_DIR/$saved.json" &&
  grep -q "option marker 'edit'" "$FORKOP_SNAPSHOT_DIR/$saved.json" || fail "the edit is not saved as a snapshot: $(cat "$WORK/result.json")"
grep -q '^health:restore:failure$' "$STATE/events" || fail "the restore is recorded as a success"
ok "edit committed while the target reload ran -> needs_attention, edit kept and saved, LKG not moved, guard released"

# 5. Hashing breaks during the reload, and an edit was committed: the check
#    must not compare two empty hashes and roll back over the edit.
current bad
restore "edit+sha:1 none:0"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "edit while hashing fails: $(cat "$WORK/result.json")"
[ "$(marker)" = edit ] && [ "$(reloads)" = 1 ] || fail "edit while hashing fails: overwritten ($(marker), $(reloads) reloads)"
[ "$(cat "$STATE/guard")" = valid ] || fail "edit while hashing fails: the guard was removed"
ok "edit while hashing fails -> still detected, kept"

printf 'config_restore_uci_rewrite: PASS\n'
