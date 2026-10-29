#!/bin/sh
set -eu

# The readiness wait after a sing-box component change is bounded by elapsed
# time, not by the sum of its own sleeps.
#
# Before: components/action.uc counted only the 4 s sleeps toward its 180 s
# limit. Each status probe (up to 6 s) and the 8 s confirmation went
# uncounted, so a core that died right after its start held the rollback
# back for about 450 s. Now the deadline is monotonic elapsed time; a runtime
# found running near the deadline is still confirmed rather than rolled back.
#
# The real wait of components/action.uc runs against a simulated clock: every
# status probe costs 6 s and every sleep advances the clock by its argument.

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ACTION="$ROOT_DIR/forkop/files/usr/lib/components/action.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() {
  printf 'component_readiness_deadline: FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/harness.uc" <<'UCODE'
const BIN_PATH = "/usr/bin/forkop";
const SCENARIO = getenv("SCENARIO");
let forkop_was_running = true;
let now = 1000;
let started = now;
let probes = 0;
let bad_sleep = false;
function file_exists(path) { return true; }
function monotonic_seconds() { return now; }
function command_success_from_args(args) {
    if (args[0] == "sleep") {
        let seconds = int(args[1]);
        if (seconds <= 0 || "" + seconds != args[1])
            bad_sleep = true;
        now += seconds;
    }
    return true;
}
function forkop_status_running_with_timeout() {
    probes++;
    let elapsed = now - started;
    now += 6;
    if (SCENARIO == "never-running")
        return false;
    if (SCENARIO == "running")
        return true;
    if (SCENARIO == "up-near-deadline")
        return elapsed >= 170;
    if (SCENARIO == "died-after-start")
        return probes == 1;
    return false;
}
UCODE
source_between "$ACTION" '^function wait_forkop_running_after_sing_box_change\(' '^function select_archive_member_path\(' \
  >>"$WORK_DIR/harness.uc" || fail "the readiness wait was not found"
cat >>"$WORK_DIR/harness.uc" <<'UCODE'
let ok = wait_forkop_running_after_sing_box_change();
printf("result=%s elapsed=%d bad_sleep=%s\n", ok ? "ready" : "failed", now - started, bad_sleep ? "1" : "0");
UCODE

# check SCENARIO RESULT MAX_ELAPSED
check() {
  out="$(SCENARIO="$1" ucode "$WORK_DIR/harness.uc")" || fail "$1: the harness failed"
  result="$(printf '%s\n' "$out" | sed -n 's/^result=\([a-z]*\) .*/\1/p')"
  elapsed="$(printf '%s\n' "$out" | sed -n 's/.* elapsed=\([0-9]*\) .*/\1/p')"
  [ "$result" = "$2" ] || fail "$1: expected $2, got: $out"
  [ "$elapsed" -le "$3" ] || fail "$1: waited ${elapsed} s, more than $3 s: $out"
  case "$out" in
    *bad_sleep=0*) ;;
    *) fail "$1: slept for a non-positive or non-integer time: $out" ;;
  esac
}

# A core that never comes up gives way to the rollback near 180 s: the last
# probe may start just before the deadline and take its 6 s.
check never-running failed 186
# One that dies right after its start does too, instead of about 450 s.
check died-after-start failed 186
# A healthy runtime is confirmed by two probes 8 s apart.
check running ready 20
# One that comes up just before the deadline is confirmed past it, not
# rolled back while it works.
check up-near-deadline ready 200

printf 'component_readiness_deadline: PASS\n'
