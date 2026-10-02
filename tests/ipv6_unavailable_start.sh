#!/usr/bin/env bash
set -eo pipefail

# The IPv6 half of TPROXY is a route and a marking rule on the loopback. A
# kernel built or booted without IPv6, or one where it was turned off, has no
# loopback to carry them, and `ip -6 route add local ::/0 dev lo` fails.
#
# Reproduced on a netis NX31 with net.ipv6.conf.{all,default,lo}.disable_ipv6=1:
#
#   [fatal] Failed to add IPv6 route for tproxy. Aborted.
#   [fatal] Startup phase 'nft-rebuild' failed with exit status 1
#
# and then a start-retry loop with no proxy at all, the IPv4 half it had just
# built torn down again each time. A router that does not use IPv6 lost the
# whole product for want of it.
#
# So when IPv6 is unavailable its route and marking rule are not installed, and
# the start carries on. The IPv4 marking rule is added AFTER the IPv6 route, so
# the obvious guard - returning early once IPv6 turns out to be missing - would
# silently drop it and leave marked packets unrouted. That case is checked here
# explicitly.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
NFT_RUNTIME="$FORKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'ip log:\n' >&2
  cat "$WORK_DIR/ip.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/state"

# `ip` double: records every call, and keeps the routes and rules it was asked
# to add so the presence checks see what a real kernel would show. With
# IPV6_ADD_FAILS it refuses the IPv6 additions, as a kernel without IPv6 does.
cat >"$WORK_DIR/bin/ip" <<'IP'
#!/usr/bin/env bash
set -eo pipefail
{ printf 'ip'; for arg in "$@"; do printf '\t%s' "$arg"; done; printf '\n'; } >> "${IP_LOG:?}"
state="${IP_STATE:?}"

case "$1 $2 $3" in
  "route list table")  [ -e "$state/route4" ] && printf 'local default dev lo scope host\n'; exit 0 ;;
  "-6 route list")     [ -e "$state/route6" ] && printf 'local ::/0 dev lo metric 1024 pref medium\n'; exit 0 ;;
  "route add local")   : > "$state/route4"; exit 0 ;;
  "-6 route add")
    [ "${IPV6_ADD_FAILS:-0}" = "1" ] && { printf 'RTNETLINK answers: Permission denied\n' >&2; exit 2; }
    : > "$state/route6"; exit 0 ;;
  "-4 rule add")       : > "$state/rule4"; exit 0 ;;
  "-6 rule add")
    [ "${IPV6_ADD_FAILS:-0}" = "1" ] && { printf 'RTNETLINK answers: Permission denied\n' >&2; exit 2; }
    : > "$state/rule6"; exit 0 ;;
  "-4 rule list")      [ -e "$state/rule4" ] && printf '105: from all fwmark 0x1/0x1 lookup forkop\n'; exit 0 ;;
  "-6 rule list")      [ -e "$state/rule6" ] && printf '105: from all fwmark 0x1/0x1 lookup forkop\n'; exit 0 ;;
esac
exit 0
IP
chmod 0755 "$WORK_DIR/bin/ip"

# The kernel's IPv6 switches, as /proc exposes them.
write_ipv6_conf() {
  rm -rf "$WORK_DIR/ipv6"
  [ "$1" = "missing" ] && return 0
  for scope in all lo; do
    mkdir -p "$WORK_DIR/ipv6/$scope"
    printf '%s\n' "$1" >"$WORK_DIR/ipv6/$scope/disable_ipv6"
  done
}

run_ensure() {
  rm -rf "$WORK_DIR/state" "$WORK_DIR/ip.log" "$WORK_DIR/rt_tables"
  mkdir -p "$WORK_DIR/state"
  : >"$WORK_DIR/ip.log"
  : >"$WORK_DIR/rt_tables"
  PATH="$WORK_DIR/bin:$PATH" \
  IP_LOG="$WORK_DIR/ip.log" IP_STATE="$WORK_DIR/state" \
  IPV6_ADD_FAILS="$1" \
  FORKOP_IPV6_CONF_DIR="$WORK_DIR/ipv6" \
    ucode -L "$FORKOP_LIB" "$NFT_RUNTIME" ensure-tproxy-route-rule forkop 1 "$WORK_DIR/rt_tables"
}

ip_log_has() { grep -qF "$(printf '%s' "$1")" "$WORK_DIR/ip.log"; }

# 1. A kernel without IPv6: the start must carry on, no IPv6 route or rule is
#    attempted, and the IPv4 route AND marking rule are still installed.
write_ipv6_conf 1
run_ensure 1 || fail 'a router without IPv6 must still get its TPROXY routing'
ip_log_has $'ip\troute\tadd\tlocal\t0.0.0.0/0' ||
  fail 'the IPv4 TPROXY route must still be added'
ip_log_has $'ip\t-4\trule\tadd' ||
  fail 'the IPv4 marking rule must still be added: it comes after the IPv6 route'
if ip_log_has $'ip\t-6\troute\tadd'; then
  fail 'no IPv6 route may be attempted when the kernel has no IPv6'
fi
if ip_log_has $'ip\t-6\trule\tadd'; then
  fail 'no IPv6 marking rule may be attempted when the kernel has no IPv6'
fi

# 2. The switches absent entirely (a kernel built without IPv6) reads the same.
write_ipv6_conf missing
run_ensure 1 || fail 'a kernel built without IPv6 must still get its TPROXY routing'
ip_log_has $'ip\t-4\trule\tadd' || fail 'the IPv4 marking rule must still be added'
if ip_log_has $'ip\t-6\troute\tadd'; then
  fail 'no IPv6 route may be attempted without the kernel switches'
fi

# 3. With IPv6 present both halves are installed, as before.
write_ipv6_conf 0
run_ensure 0 || fail 'a router with IPv6 must get both halves'
for expected in $'ip\troute\tadd\tlocal\t0.0.0.0/0' $'ip\t-6\troute\tadd\tlocal\t::/0' \
  $'ip\t-4\trule\tadd' $'ip\t-6\trule\tadd'; do
  ip_log_has "$expected" || fail "IPv6 is available, so this must still run: $expected"
done

# 4. A real failure to add the IPv6 route, on a kernel that claims IPv6, still
#    aborts: that is a fault, not an absent protocol.
write_ipv6_conf 0
if run_ensure 1; then
  fail 'a kernel that reports IPv6 but refuses the route must still abort the start'
fi

# 5. The presence checks agree: with no IPv6, IPv4 alone is a complete setup.
write_ipv6_conf 1
rm -rf "$WORK_DIR/state"; mkdir -p "$WORK_DIR/state"; : >"$WORK_DIR/state/route4"; : >"$WORK_DIR/state/rule4"
: >"$WORK_DIR/ip.log"
PATH="$WORK_DIR/bin:$PATH" IP_LOG="$WORK_DIR/ip.log" IP_STATE="$WORK_DIR/state" \
  FORKOP_IPV6_CONF_DIR="$WORK_DIR/ipv6" \
  ucode -L "$FORKOP_LIB" "$NFT_RUNTIME" tproxy-route-rule-present forkop 1 ||
  fail 'with no IPv6, an IPv4-only TPROXY setup must count as present'

printf 'ipv6 unavailable start checks passed\n'
