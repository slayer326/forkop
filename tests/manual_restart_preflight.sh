#!/usr/bin/env bash
set -euo pipefail

# LuCI restart refreshes remote data while the old runtime is still serving.
# The preflight owns reload.lock, never invokes an intermediate reload, gives
# way to Stop, and reaches exactly one ordinary guarded restart only after all
# cache families succeeded.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIFECYCLE="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
UPDATES="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"
UI="$ROOT_DIR/forkop/files/usr/lib/service/ui.uc"
CLI="$ROOT_DIR/forkop/files/usr/bin/forkop"

# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"
source_require "$LIFECYCLE" "$UPDATES" "$UI" "$CLI"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

manual_body="$(source_function "$LIFECYCLE" manual_restart)" || exit 1
restart_body="$(source_function "$LIFECYCLE" restart)" || exit 1
stop_abort_body="$(source_function "$LIFECYCLE" abort_manual_restart_for_stop)" || exit 1
subscription_body="$(source_function "$UPDATES" subscription_prepare_only)" || exit 1
list_body="$(source_function "$UPDATES" list_update)" || exit 1
list_finish_body="$(source_function "$UPDATES" finish_list_update)" || exit 1
ui_worker_body="$(source_function "$UI" service_action_worker)" || exit 1
ui_async_body="$(source_function "$UI" service_action_async)" || exit 1
ui_finish_body="$(source_function "$UI" finish_service_action_after_command)" || exit 1

for required in \
  '"acquire-runtime-dir-lock"' \
  'return 75;' \
  '"subscription-prepare-only"' \
  '"prepare-list-cache"' \
  '"service-proxy-address", "lists"' \
  '"refresh", ruleset_proxy_address' \
  'let status = restart(true, preflight_fingerprint);'; do
  grep -Fq "$required" <<<"$manual_body" ||
    fail "manual restart is missing: $required"
done

grep -Fq 'if (list_update_prepare_only)' <<<"$list_finish_body" ||
  fail "list preparation does not have a cache-only completion path"
prepare_exit_line="$(grep -nF 'exit(status == 0 ? 0 : 1);' <<<"$list_finish_body" | head -n1 | cut -d: -f1)"
runtime_apply_line="$(grep -nF '[ SERVICE_INIT, "reload", "list-content" ]' <<<"$list_finish_body" | head -n1 | cut -d: -f1)"
[ -n "$prepare_exit_line" ] && [ -n "$runtime_apply_line" ] &&
  [ "$prepare_exit_line" -lt "$runtime_apply_line" ] ||
  fail "list preparation can reach the live runtime apply"

subscription_line="$(grep -nF '"subscription-prepare-only"' <<<"$manual_body" | head -n1 | cut -d: -f1)"
list_line="$(grep -nF '"prepare-list-cache"' <<<"$manual_body" | head -n1 | cut -d: -f1)"
ruleset_line="$(grep -nF '"refresh", ruleset_proxy_address' <<<"$manual_body" | head -n1 | cut -d: -f1)"
restart_line="$(grep -nF 'let status = restart(true, preflight_fingerprint);' <<<"$manual_body" | head -n1 | cut -d: -f1)"
[ "$subscription_line" -lt "$list_line" ] &&
  [ "$list_line" -lt "$ruleset_line" ] &&
  [ "$ruleset_line" -lt "$restart_line" ] ||
  fail "preflight order must be subscriptions, lists, rule sets, restart"

[ "$(grep -cF 'if (abort_manual_restart_for_stop())' <<<"$manual_body")" -ge 4 ] ||
  fail "manual restart does not give way to Stop after every network phase"
[ "$(grep -cF 'restart(true, preflight_fingerprint);' <<<"$manual_body")" -eq 1 ] ||
  fail "manual preflight must perform exactly one guarded restart"

grep -Fq 'if (stop_sensitive && manual_restart_stop_requested())' <<<"$restart_body" ||
  fail "guarded restart does not honor a Stop before the transition"
grep -Fq 'if (manual_restart_stop_requested())' <<<"$restart_body" ||
  fail "guarded restart does not honor a Stop after the old runtime exits"
[ "$(grep -cF 'remove_file(STOP_REQUESTED_FILE);' <<<"$restart_body")" -eq 1 ] ||
  fail "guarded restart may clear the Stop request"
if grep -Fq 'remove_file(STOP_REQUESTED_FILE);' <<<"$stop_abort_body"; then
  fail "preflight Stop cancellation clears the durable Stop request"
fi

for required in \
  'subscription_prefetch(true' \
  'acquire_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR, false)' \
  'subscription_prepare_cache_request(true' \
  'subscription_prefetch_discard()'; do
  grep -Fq "$required" <<<"$subscription_body" ||
    fail "subscription prepare-only path is missing: $required"
done

grep -Fq 'if (manual_restart_lock_held())' <<<"$list_body" ||
  fail "a competing list worker can be mistaken for successful preflight"
grep -Fq '[ BIN_PATH, "manual_restart" ]' <<<"$ui_worker_body" ||
  fail "LuCI restart does not invoke the guarded manual entrypoint"
grep -Fq 'action == "restart" ? "manual-ui-restart" : ""' <<<"$ui_async_body" ||
  fail "LuCI restart is not tagged for the guarded path"
grep -Fq 'action == "restart" && status == 75' <<<"$ui_finish_body" ||
  fail "busy reload.lock status is not exposed to LuCI"
grep -Fq 'manual_restart: [ "service/lifecycle.uc", "manual-restart", 0 ]' "$CLI" ||
  fail "CLI does not expose the internal guarded restart entrypoint"

printf 'manual restart preflight contract checks passed\n'
