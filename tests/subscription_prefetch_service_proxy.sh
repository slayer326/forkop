#!/usr/bin/env bash
set -euo pipefail

# A subscription source that downloads through another rule's sing-box
# service proxy is fetched ahead of reload.lock only through a live proxy,
# and a fetch through it that failed is repeated under the lock (UC-057
# follow-up).
#
# A subscription update fetches its responses before it takes reload.lock
# and commits them under the lock without going to the network again. A
# start, reload or DNS failover in progress may be restarting sing-box
# meanwhile, which the update used to wait for on reload.lock:
#
# 1. With the service proxy down, the fetch went to the subscription URL
#    directly, bypassing the configured download proxy, before the lock.
# 2. A fetch through the proxy that failed while sing-box restarted was
#    replayed under the lock as final, and the forced update failed although
#    the proxy was back up by then.
#
# The update is the real components/updates.uc with the real
# subscription/cache.uc and service/state.uc. sing-box is a sleep process
# that ubus and readlink stand-ins report as the running service; curl is a
# stand-in that records its proxy and who holds reload.lock.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -s "$EVENTS" ]; then
    sed 's/^/  event: /' "$EVENTS" >&2
  fi
  exit 1
}

RUN="$WORK_DIR/run"
SUBS="$WORK_DIR/sing-box/subscriptions"
PERSISTENT="$WORK_DIR/persistent/subscription-cache"
export RELOAD_LOCK="$RUN/reload.lock" EVENTS TEST_LIB="$LIB"
export PROXY_UP="$WORK_DIR/proxy.up" PROXY_FAILING="$WORK_DIR/proxy.failing"
export SING_BOX_PID_FILE="$WORK_DIR/sing-box.pid"
mkdir -p "$WORK_DIR/bin" "$RUN" "$WORK_DIR/tmp"
: >"$EVENTS"

sleep 600 &
SING_BOX=$!
pids+=("$SING_BOX")
printf '%s\n' "$SING_BOX" >"$SING_BOX_PID_FILE"

# procd reports sing-box running while $PROXY_UP exists.
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/bin/sh
[ -e "$PROXY_UP" ] || exit 1
printf '{"sing-box":{"instances":{"sing-box":{"running":true,"pid":%s}}}}\n' "$(cat "$SING_BOX_PID_FILE")"
SH
cat >"$WORK_DIR/bin/readlink" <<'SH'
#!/bin/sh
if [ "$#" = 1 ] && [ "$1" = "/proc/$(cat "$SING_BOX_PID_FILE")/exe" ]; then
  printf '/usr/bin/sing-box\n'
  exit 0
fi
exec /bin/readlink "$@"
SH
# A request through the service proxy fails while the proxy is down or
# $PROXY_FAILING exists (sing-box is being restarted).
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
owner="$(ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" runtime-dir-lock-owner "$RELOAD_LOCK" 2>/dev/null || true)"
if [ -z "$owner" ]; then held=free; elif [ "$owner" = "$HOLDER_PID" ]; then held=holder; else held=update; fi
output=""
headers=""
url=""
proxy=direct
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    -x) proxy="$2"; shift 2 ;;
    -H|--connect-timeout|--speed-time|--speed-limit|--resolve) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf 'curl %s proxy=%s lock=%s\n' "$url" "$proxy" "$held" >>"$EVENTS"
if [ "$proxy" != direct ] && { [ ! -e "$PROXY_UP" ] || [ -e "$PROXY_FAILING" ]; }; then
  exit 7
fi
name="${url##*/}"
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
printf 'vless://00000000-0000-4000-8000-000000000001@%s.example.com:443?type=tcp&encryption=none&security=tls&sni=example.com#%s\n' \
  "$name" "$name" >"$output"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
chmod +x "$WORK_DIR/bin/"*

state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }
cached_host() { grep -o '@[a-z0-9]*\.example\.com' "$SUBS/alpha-subscription-1.json" 2>/dev/null | head -n 1 || true; }

# start_case: a forced update of rule alpha, whose source downloads through
# rule bravo's service proxy, while another lifecycle holds reload.lock.
start_case() {
  : >"$EVENTS"
  rm -rf "$WORK_DIR/sing-box" "$WORK_DIR/persistent" "${RUN:?}"/*
  cat >"$WORK_DIR/uci.state" <<'UCI'
forkop.settings=settings
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.subscription_urls=https://sub.test/alpha
forkop.alpha.subscription_url_settings={"https://sub.test/alpha":{"download_via_proxy_enabled":"1","download_via_proxy_section":"bravo"}}
forkop.bravo=section
forkop.bravo.enabled=1
forkop.bravo.action=connection
forkop.bravo.selector_proxy_links=vless://00000000-0000-4000-8000-000000000002@bravo.example.com:443?type=tcp&encryption=none&security=tls&sni=example.com#bravo
UCI
  sleep 600 &
  HOLDER=$!
  pids+=("$HOLDER")
  export HOLDER_PID="$HOLDER"
  state acquire-runtime-dir-lock "$RELOAD_LOCK" "$HOLDER" || fail "the holder could not take reload.lock"

  env PATH="$WORK_DIR/bin:$PATH" TMPDIR="$WORK_DIR/tmp" \
    FORKOP_LIB="$LIB" \
    FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box" \
    TMP_RULESET_FOLDER="$WORK_DIR/sing-box/rulesets" \
    TMP_SUBSCRIPTION_FOLDER="$SUBS" \
    FORKOP_RUNTIME_STATE_DIR="$RUN" \
    FORKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK" \
    FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$RUN/subscription-update.lock" \
    FORKOP_PENDING_RELOAD_FILE="$RUN/reload.pending" \
    FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$PERSISTENT" \
    FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$PERSISTENT/cache-format" \
    FORKOP_SERVICE_INIT="$WORK_DIR/bin/logger" \
    FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" \
    SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
    SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
    ucode -L "$LIB" "$LIB/components/updates.uc" subscription-update alpha >"$WORK_DIR/update.log" 2>&1 &
  UPDATE=$!
  pids+=("$UPDATE")
}

# The update fetched what it fetches ahead and now waits for reload.lock.
wait_for_lock_wait() {
  wait_until 60 pgrep -f "acquire-runtime-dir-lock-wait $RELOAD_LOCK" >/dev/null ||
    fail "the subscription update did not reach reload.lock"
}

finish_case() {
  local status=0
  state release-runtime-dir-lock "$RELOAD_LOCK" "$HOLDER"
  wait_until 60 process_gone "$UPDATE" || fail "the subscription update did not finish after reload.lock was released"
  wait "$UPDATE" || status=$?
  kill -KILL "$HOLDER" 2>/dev/null || true
  wait "$HOLDER" 2>/dev/null || true
  [ "$status" = 0 ] || fail "the forced subscription update failed with status $status: $(cat "$WORK_DIR/update.log")"
  [ "$(cached_host)" = "@alpha.example.com" ] || fail "the subscription update did not commit the response"
  if grep -q 'proxy=direct' "$EVENTS"; then
    fail "the subscription was downloaded around its configured service proxy"
  fi
  grep -Eq '^curl https://sub.test/alpha proxy=http://127\.0\.0\.1:[0-9]+ lock=update$' "$EVENTS" ||
    fail "the subscription was not downloaded through the service proxy under reload.lock"
}

# 1. The service proxy is down while the update fetches ahead: nothing is
#    fetched then; under the lock, with the proxy up, it goes through it.
rm -f "$PROXY_UP"
start_case
wait_for_lock_wait
if grep -q '^curl ' "$EVENTS"; then
  fail "the subscription was fetched while its service proxy was down"
fi
: >"$PROXY_UP"
finish_case

# 2. A fetch through the proxy fails while sing-box restarts; under the
#    lock, with the proxy back, it is made again.
: >"$PROXY_UP"
: >"$PROXY_FAILING"
start_case
wait_for_lock_wait
grep -Eq '^curl https://sub.test/alpha proxy=http://127\.0\.0\.1:[0-9]+ lock=holder$' "$EVENTS" ||
  fail "the subscription was not fetched ahead of reload.lock through its service proxy"
rm -f "$PROXY_FAILING"
finish_case

# 3. Startup preparation must not turn an explicitly proxied HTTPS source
#    into a direct request. It is returned as deferred so lifecycle can bring
#    up the dependency-only temporary service proxy first.
rm -f "$PROXY_UP" "$PROXY_FAILING"
: >"$EVENTS"
rm -rf "$WORK_DIR/sing-box" "$WORK_DIR/persistent" "${RUN:?}"/*
output="$(env PATH="$WORK_DIR/bin:$PATH" TMPDIR="$WORK_DIR/tmp" \
  FORKOP_LIB="$LIB" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box" \
  TMP_RULESET_FOLDER="$WORK_DIR/sing-box/rulesets" \
  TMP_SUBSCRIPTION_FOLDER="$SUBS" \
  FORKOP_RUNTIME_STATE_DIR="$RUN" \
  FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$RUN/subscription-update.lock" \
  FORKOP_PENDING_RELOAD_FILE="$RUN/reload.pending" \
  FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$PERSISTENT" \
  FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$PERSISTENT/cache-format" \
  SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
  SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
  ucode -L "$LIB" "$LIB/subscription/cache.uc" prepare-caches startup 0 0)" ||
  fail "startup preparation rejected a recoverable proxied subscription"
[ "$output" = alpha ] || fail "startup did not return the proxied subscription as deferred: '$output'"
if grep -q '^curl ' "$EVENTS"; then
  fail "startup downloaded an explicitly proxied subscription directly"
fi

printf 'subscription prefetch service proxy checks passed\n'
