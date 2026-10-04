#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIFECYCLE_UC="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Every transition that can rewrite or tear down the live dataplane has to
# prove sing-box ownership first. These are ordering contracts: the gate is
# only worth anything when it runs before the first destructive step, so assert
# the position in the source rather than merely the presence of the check.

# stop_main() removes the nftables policy before the controlled sing-box stop
# would reject ambiguous ownership. Without a gate at the top, a stop can
# discard the fail-closed policy while an unknown sing-box is still alive.
awk '
  /^function stop_main\([^)]*\) \{/ { inside = 1 }
  inside && /"sing-box-process-conflict"/ && !gate_line { gate_line = NR }
  inside && /module_success\(DNS_FAILOVER_UC, \[ "stop-runtime" \]\)/ && !teardown_line { teardown_line = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && gate_line && teardown_line && gate_line < teardown_line ? 0 : 1 }
' "$LIFECYCLE_UC" || fail "stop_main must refuse an ambiguous runtime before tearing down any state"

# reload() must refuse before capturing reload state or staging candidate nft
# rules, not only when the runtime already looks incomplete (the branch that
# restarts it). The read-only skip of a background reload after an explicit
# stop may look at the runtime earlier: it changes nothing.
awk '
  /^function reload\(reason\) \{/ { inside = 1 }
  inside && /"sing-box-process-conflict"/ && !gate_line { gate_line = NR }
  inside && /"capture-reload-state"/ && !capture_line { capture_line = NR }
  inside && /if \(!module_success\(STATE_UC, \[ "forkop-running"/ && !running_line { running_line = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && gate_line && capture_line && running_line && gate_line < capture_line && gate_line < running_line ? 0 : 1 }
' "$LIFECYCLE_UC" || fail "reload must refuse an ambiguous runtime before capturing state or staging nft rules"

# restart() already gated cold-start recovery; keep it that way.
awk '
  /^function restart\([^)]*\) \{/ { inside = 1 }
  inside && /"sing-box-process-conflict"/ { gate_line = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && gate_line ? 0 : 1 }
' "$LIFECYCLE_UC" || fail "restart must keep refusing an ambiguous runtime"

# The gate is fail-closed: each refusal returns a failure, never success.
# stop_main distinguishes a refusal (2) from a teardown failure, so accept any
# non-zero status rather than pinning the exact number.
for fn in stop_main reload restart; do
  awk -v fn="$fn" '
    $0 ~ "^function " fn "\\(" { inside = 1 }
    inside && /"sing-box-process-conflict"/ { armed = 1 }
    armed && /return/ { print; armed = 0 }
    inside && /^}/ { exit }
  ' "$LIFECYCLE_UC" | grep -qE 'return ([1-9][0-9]*|finish_reload_status\(1)' ||
    fail "$fn must fail closed when sing-box ownership is ambiguous"
done

printf 'runtime ownership gate checks passed\n'
