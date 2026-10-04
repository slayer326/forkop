#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
STATE_UC="$FORKOP_LIB/service/state.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

snapshot=$'Active Internet connections (only servers)\nProto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name\ntcp        0      0 127.0.0.1:4534        0.0.0.0:*               LISTEN      4100/foreign\nudp        0      0 127.0.0.1:4535        0.0.0.0:*                           4200/sing-box\ntcp        0      0 127.0.0.1:4536        0.0.0.0:*               LISTEN      4200/sing-box\ntcp6       0      0 :::4537                 :::*                    LISTEN      4200/sing-box\ntcp        0      0 127.0.0.1:4538        192.0.2.1:443           ESTABLISHED 4200/sing-box'

owned() {
  NETSTAT_SNAPSHOT="$snapshot" ucode -L "$FORKOP_LIB" -e '
    let n = require("core.netstat");
    exit(n.tcp_listen_port_owned(getenv("NETSTAT_SNAPSHOT"), ARGV[0], ARGV[1], ARGV[2]) ? 0 : 1);
  ' "$@"
}

if owned 127.0.0.1 4534 4200; then
  fail "a foreign PID satisfied managed listener readiness"
fi
if owned 127.0.0.1 4535 4200; then
  fail "a UDP socket satisfied TCP listener readiness"
fi
owned 127.0.0.1 4535 4201 >/dev/null 2>&1 &&
  fail "a foreign PID on a UDP socket satisfied readiness"
if owned 127.0.0.1 4536 420; then
  fail "a PID prefix satisfied exact listener ownership"
fi
owned 127.0.0.1 4536 4200 ||
  fail "the expected PID-owned TCP LISTEN socket was rejected"
owned ::1 4537 4200 ||
  fail "a wildcard TCP6 listener owned by the expected PID was rejected"
if owned 127.0.0.1 4538 4200; then
  fail "a non-LISTEN TCP socket satisfied readiness"
fi

grep -Fq 'command_output_from_args([ "netstat", "-lntp" ])' "$STATE_UC" ||
  fail "managed listener readiness must request netstat PID ownership"
grep -Fq 'netstat.tcp_listen_port_owned(snapshot, listener.listen, listener.port, expected.pid)' "$STATE_UC" ||
  fail "managed listener readiness must match the expected PID"
if grep -Fq 'wait-managed-sing-box-listener' "$STATE_UC"; then
  fail "obsolete single-listener readiness entrypoint is still exposed"
fi

echo "managed listener ownership checks passed"
