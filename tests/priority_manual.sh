#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FORKOP_LIB="$LIB" FORKOP_RUNTIME_STATE_DIR="$WORK/run" FORKOP_SECTION_CACHE_DIR="$WORK/cache"
export FORKOP_DIAGNOSTICS_UC="$WORK/diagnostics.uc" PRIORITY_TEST_WORK="$WORK"
mkdir -p "$WORK/cache" "$WORK/run"
cat >"$WORK/group.json" <<'JSON'
{"tag":"priority","health_url":"https://health.example/204","active_check_interval":"1s","check_timeout":"2s","recovery_check_interval":"1s","levels":[{"outbounds":["a"]},{"outbounds":["b"]}]}
JSON
node -e 'const fs=require("fs"),g=JSON.parse(fs.readFileSync(process.argv[1])); fs.writeFileSync(process.argv[2],JSON.stringify({priorityGroups:{priority:g}}))' "$WORK/group.json" "$WORK/cache/main.json"
cat >"$WORK/diagnostics.uc" <<'UC'
let fs = require("fs");
let dir = getenv("PRIORITY_TEST_WORK");
if (ARGV[1] == "get_proxy_latency") {
    if (fs.stat(dir + "/pin-during-probe")) {
        fs.unlink(dir + "/pin-during-probe");
        let lib = getenv("FORKOP_LIB");
        if (system(sprintf("ucode -L %s %s/singbox/priority.uc manual-select priority b manual >/dev/null", lib, lib)) != 0) exit(1);
    }
    let delays = json(fs.readfile(dir + "/delays.json"));
    if (delays[ARGV[2]] < 0) exit(1);
    print(sprintf("%J\n", { delay: delays[ARGV[2]] }));
} else if (ARGV[1] == "set_group_proxy") {
    if (fs.stat(dir + "/reject")) exit(1);
    let file = fs.open(dir + "/events", "a");
    file.write(ARGV[3] + "\n"); file.close();
    print("{}\n");
} else exit(1);
UC
printf '{"a":30,"b":10}\n' >"$WORK/delays.json"
tick() {
    if [ -f "$WORK/state.json" ]; then
        node -e 'const fs=require("fs"),p=process.argv[1],s=JSON.parse(fs.readFileSync(p)); s.nextActiveCheck=0; s.nextRecoveryCheck=0; fs.writeFileSync(p,JSON.stringify(s))' "$WORK/state.json"
    fi
    ucode -L "$LIB" "$LIB/singbox/priority.uc" tick-fixture "$WORK/group.json" "$WORK/state.json" >"$WORK/state.new"
    mv "$WORK/state.new" "$WORK/state.json"
}
select_node() { ucode -L "$LIB" "$LIB/singbox/priority.uc" manual-select "$1" "$2" "${3:-manual}"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
tick
[ "$(tail -n1 "$WORK/events")" = a ] || fail "automatic priority order changed"
select_node priority b >/dev/null
tick
tick
[ "$(tail -n1 "$WORK/events")" = b ] || fail "worker overwrote the manual selection"
select_node priority priority auto >/dev/null
tick
[ "$(tail -n1 "$WORK/events")" = a ] || fail "Auto did not restore the preferred level"
select_node priority b >/dev/null
select_node priority priority auto >/dev/null
tick
[ "$(tail -n1 "$WORK/events")" = a ] || fail "fast pin/Auto left the controller on a manually selected node"
before="$(wc -l <"$WORK/events")"
if select_node priority other >/dev/null; then fail "foreign member was accepted"; fi
if select_node unknown b >/dev/null; then fail "foreign group was accepted"; fi
[ "$before" = "$(wc -l <"$WORK/events")" ] || fail "invalid selection reached the controller"
: >"$WORK/run/stop.requested"
if select_node priority b >/dev/null; then fail "manual selection ignored an explicit stop"; fi
rm "$WORK/run/stop.requested"
: >"$WORK/reject"
if select_node priority b >/dev/null; then fail "failed API request reported success"; fi
rm "$WORK/reject"
tick
[ "$(tail -n1 "$WORK/events")" = a ] || fail "failed request retained a manual pin"

# A transient timeout must not switch a working WARP-like primary tunnel.
printf '{"a":-1,"b":10}\n' >"$WORK/delays.json"
tick
[ "$(tail -n1 "$WORK/events")" = a ] || fail "one timeout abandoned the primary tunnel"
printf '{"a":30,"b":10}\n' >"$WORK/delays.json"
tick
printf '{"a":-1,"b":10}\n' >"$WORK/delays.json"
tick
[ "$(tail -n1 "$WORK/events")" = a ] || fail "a success did not reset failure confirmation"
tick
[ "$(tail -n1 "$WORK/events")" = b ] || fail "confirmed failure did not select the fallback"

# A manual request that arrives while an automatic probe is in flight wins.
printf '{"a":30,"b":10}\n' >"$WORK/delays.json"
rm "$WORK/state.json"
: >"$WORK/pin-during-probe"
tick
[ "$(tail -n1 "$WORK/events")" = b ] || fail "in-flight probe overwrote a new manual choice"
ucode -L "$LIB" "$LIB/singbox/priority.uc" stop-runtime
[ ! -d "$WORK/run/priority-manual" ] || fail "service stop retained a manual override"
printf 'Priority manual selection and failure confirmation checks passed\n'
