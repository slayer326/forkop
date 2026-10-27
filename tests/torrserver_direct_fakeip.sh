#!/bin/sh
set -eu

# TorrServer Direct marks TorrServer's sockets to bypass Forkop. TorrServer
# resolves through the router DNS, which answers listed domains (trackers
# among them) with FakeIP addresses; marked, those went to the WAN with a
# 198.18.x.x destination and never connected. The rule leaves FakeIP
# destinations unmarked, before the bypass mark, and a rule without these
# exclusions (an older version's) does not count as active, so the worker
# replaces it. Adapted from Forkop X 2.5.0-canary.1 (83707f17).

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
SOURCE="$LIB/torrserver/direct.uc"
PACKAGE="$LIB/service/package.uc"
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() {
  printf 'torrserver_direct_fakeip: FAIL: %s\n' "$1" >&2
  exit 1
}

CGROUP=/services/torrserver/instance1
batch="$(ucode -L "$LIB" "$SOURCE" batch "$CGROUP")" || fail "no rule batch for $CGROUP"

line_of() {
  printf '%s\n' "$batch" | grep -n -F -x -- "$1" | head -n 1 | cut -d: -f1
}
v4="$(line_of 'add rule inet ForkopTorrServerDirect output ip daddr 198.18.0.0/15 return')"
v6="$(line_of 'add rule inet ForkopTorrServerDirect output ip6 daddr fc00::/18 return')"
mark="$(printf '%s\n' "$batch" | grep -n -F 'meta mark set 0x08000000' | head -n 1 | cut -d: -f1)"
[ -n "$v4" ] && [ -n "$v6" ] || fail "FakeIP destinations are not excluded: $batch"
[ -n "$mark" ] || fail "the bypass mark rule is missing: $batch"
[ "$v4" -lt "$mark" ] && [ "$v6" -lt "$mark" ] || fail "the FakeIP exclusions must precede the bypass mark"

# The listing nft prints for the applied batch.
listing() {
  printf 'table inet ForkopTorrServerDirect {\n\tchain output {\n'
  printf '\t\ttype route hook output priority mangle - 1; policy accept;\n'
  printf '%s\n' "$batch" | sed -n 's/^add rule inet ForkopTorrServerDirect output /\t\t/p' |
    sed 's/ counter / counter packets 0 bytes 0 /'
  printf '\t}\n}\n'
}
listing | ucode -L "$LIB" "$SOURCE" rule-output-active "$CGROUP" ||
  fail "the applied rule is not recognised as active"

old_level="$(printf '%s' "${CGROUP#/}" | awk -F/ '{print NF}')"
printf 'table inet ForkopTorrServerDirect {\n\tchain output {\n\t\ttype route hook output priority mangle - 1; policy accept;\n\t\tsocket cgroupv2 level %s "%s" meta mark set 0x08000000 counter packets 0 bytes 0 comment "Forkop TorrServer Direct"\n\t}\n}\n' \
  "$old_level" "${CGROUP#/}" >"${TMPDIR:-/tmp}/torrserver-old.$$"
if ucode -L "$LIB" "$SOURCE" rule-output-active "$CGROUP" <"${TMPDIR:-/tmp}/torrserver-old.$$"; then
  rm -f "${TMPDIR:-/tmp}/torrserver-old.$$"
  fail "an older rule without the FakeIP exclusions counts as active"
fi
rm -f "${TMPDIR:-/tmp}/torrserver-old.$$"

# An upgrade restarts the worker, which keeps the old module in memory.
source_require "$PACKAGE"
grep -q '"/etc/init.d/forkop-torrserver-direct", "restart"' "$PACKAGE" ||
  fail "postinst does not restart the TorrServer Direct worker"

printf 'torrserver_direct_fakeip: PASS\n'
