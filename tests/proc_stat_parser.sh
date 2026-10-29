#!/usr/bin/env bash
set -euo pipefail

# One /proc/<pid>/stat parser (UC-158).
#
# The command name (field 2) is the only stat field that may contain spaces
# and parentheses, so the fields after it start at the last ") " of the line.
# core/process_identity.uc parsed it so; service/state.uc (sing-box
# provenance and age) and components/action.uc (sing-box processes of an
# upgrade) each carried their own copy that split at the first ") ". They now read the fields through
# process_identity.stat_fields() or start_ticks().
#
# 1. Seeded property test of the shared parser over synthetic stat lines.
# 2. A real process whose command name contains ") ".
# 3. No module other than core/process_identity.uc splits a stat line.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

process=""
cleanup() {
  if [ -n "$process" ]; then
    kill -KILL "$process" 2>/dev/null || true
    wait "$process" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
export PROPERTY_WORK="$WORK"

# 1.
node "$ROOT_DIR/tests/helpers/property/proc_stat.js" "$LIB"

# 2. A shell that renames itself: its command name shifts every field after
#    it for a parser that splits at the first ") ".
bash -c 'printf "%s" "x) 1 2 3" >/proc/$$/comm; : >"$1"; while [ ! -e "$2" ]; do sleep 0.1; done' \
  renamed "$WORK/ready" "$WORK/stop" &
process=$!
wait_until 10 test -e "$WORK/ready" || fail "fixture: the renamed process did not start"
[ "$(cat "/proc/$process/comm")" = "x) 1 2 3" ] || fail "fixture: the command name was not changed"
stat="$(cat "/proc/$process/stat")"
# shellcheck disable=SC2086 # split the fields after the command name
set -- ${stat##*) }
expected_ppid="$2"
expected_ticks="${20}"
[ "$expected_ppid" = "$$" ] || fail "fixture: unexpected parent $expected_ppid"
identity() {
  ucode -L "$LIB" -e 'let identity = require("core.process_identity");
print(identity.start_ticks(ARGV[0]), " ", identity.parent_pid(ARGV[0]), " ", identity.stat_fields(require("fs").readfile("/proc/" + ARGV[0] + "/stat"))[19], "\n");' -- "$1"
}
[ "$(identity "$process")" = "$expected_ticks $expected_ppid $expected_ticks" ] ||
  fail "process_identity misread a process whose name contains \") \": $(identity "$process"), want $expected_ticks $expected_ppid"
: >"$WORK/stop"

# 3.
mapfile -t modules < <(find "$LIB" -name '*.uc' ! -path "$LIB/core/process_identity.uc" | sort)
[ "${#modules[@]}" -gt 50 ] || fail "fixture: the module list is incomplete"
source_refute "only core/process_identity.uc may split a /proc/<pid>/stat line" -F '") "' "${modules[@]}"
source_refute "only core/process_identity.uc may read the state field of a stat line" -F '\) Z' "${modules[@]}"
for module in service/state.uc components/action.uc; do
  source_require "$LIB/$module"
  grep -Eq 'process_identity\.(stat_fields|start_ticks)\(' "$LIB/$module" ||
    fail "$module must read stat fields through core/process_identity.uc"
done

printf 'proc stat parser checks passed\n'
