#!/usr/bin/env bash
# The nft batches Forkop generates, checked by the real nft (UC-052).
#
# Every other nft test replaces nft with a stub that accepts any syntax. Here
# the production code renders its batches exactly as start/reload
# (service/lifecycle.uc start_main: nft/apply.uc candidate batch plus list
# data), the DPI transition and config restore guards, the cross-component
# transition guard and TorrServer Direct do.
# nft checks (-c) and applies (-f) them in a private user+net(+mount)
# namespace, and `nft -j list ruleset` shows what the kernel really holds.
#
# The test is skipped only when such a namespace cannot be created here.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
NFT_UC="$FORKOP_LIB/nft/apply.uc"
CHECK_JS="$ROOT_DIR/tests/helpers/nft_real_check.js"
NAMESPACE=(unshare --user --map-root-user --net --mount)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/net)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: nft_real: %s\n' "$1"
    exit 0
  }
  command -v nft >/dev/null 2>&1 || skip 'nft is not installed'
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  if ! probe="$("${NAMESPACE[@]}" true 2>&1)"; then
    skip "unprivileged user namespaces are unavailable: $probe"
  fi
  if ! probe="$("${NAMESPACE[@]}" nft list ruleset 2>&1)"; then
    skip "nftables is unavailable in an unprivileged network namespace: $probe"
  fi
  FORKOP_NFT_REAL_HOST_NAMESPACES="$(namespaces)" exec "${NAMESPACE[@]}" bash "$0" --in-namespace
fi

# ---- inside the namespace ---------------------------------------------------

refuse() {
  printf 'FAIL: --in-namespace is only for the private namespace this test creates (%s)\n' "$1" >&2
  exit 1
}
# Never touch the caller's ruleset or mounts. The environment can be forged,
# the user namespace cannot: only one that maps nothing but root, as
# `unshare --map-root-user` creates it, is accepted, never the initial one
# (identity map) or a container's (id ranges). Root here has no privilege
# over the network and mount namespaces those own, so at worst a forged call
# reaches another throwaway namespace of the same kind.
mapfile -t uid_map </proc/self/uid_map
read -r map_inside _ map_count <<<"${uid_map[0]:-}"
if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ]; then
  refuse "not a user namespace mapping only root: ${uid_map[*]:-}"
fi
# Both namespaces must also be new, not inherited from the caller.
read -r host_net host_mnt <<<"${FORKOP_NFT_REAL_HOST_NAMESPACES:-}"
read -r own_net own_mnt <<<"$(namespaces)"
if [ -z "${host_net:-}" ] || [ "$own_net" = "$host_net" ] || [ "$own_mnt" = "${host_mnt:-}" ]; then
  refuse "the network or mount namespace is not new"
fi

[ -z "$(nft list ruleset)" ] || {
  printf 'FAIL: the namespace does not start with an empty ruleset\n' >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
CGROUP_MOUNTED=0
cleanup() {
  [ "$CGROUP_MOUNTED" = 0 ] || umount /sys/fs/cgroup || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/tmp" "$WORK_DIR/proc_net"
export TMPDIR="$WORK_DIR/tmp"
# TorrServer Direct matches a cgroup path that nft resolves under
# /sys/fs/cgroup; the namespace gets a private, empty hierarchy there. Only
# that section needs it.
if cgroup_error="$(mount -t tmpfs forkop-nft-real /sys/fs/cgroup 2>&1)"; then
  CGROUP_MOUNTED=1
  mkdir -p /sys/fs/cgroup/services/torrserver
else
  printf 'NOTE: a private /sys/fs/cgroup cannot be mounted in the namespace, TorrServer Direct is not checked: %s\n' \
    "$cgroup_error"
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'live ruleset:\n' >&2
  nft list ruleset >&2 2>/dev/null || true
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

# The route helpers are not under test here (tests/nft_apply.sh): ip only logs.
cat >"$WORK_DIR/bin/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >>"$FORKOP_TEST_IP_LOG"
EOF
cat >"$WORK_DIR/bin/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FORKOP_TEST_LOGGER_LOG"
EOF
# Provider binaries only need to be executable for their rules to be built.
chmod 0755 "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
export FORKOP_TEST_IP_LOG="$WORK_DIR/ip.log" FORKOP_TEST_LOGGER_LOG="$WORK_DIR/logger.log"
export FORKOP_RT_TABLES="$WORK_DIR/rt_tables" FORKOP_LIB

nft_uc() { ucode -L "$FORKOP_LIB" "$NFT_UC" "$@"; }
check() { node "$CHECK_JS" "$@" || fail "ruleset check '$1' failed (${*:3})"; }
constant() { ucode -L "$FORKOP_LIB" "$FORKOP_LIB/core/constants.uc" get "$1"; }
hex_to_dec() { printf '%d' "$1"; }

RT_TABLE="$(constant RT_TABLE_NAME)"
TABLE="$(constant NFT_TABLE_NAME)"
LOCALV4="$(constant NFT_LOCALV4_SET_NAME)"
LOCALV6="$(constant NFT_LOCALV6_SET_NAME)"
COMMON="$(constant NFT_COMMON_SET_NAME)"
COMMON6="$(constant NFT_COMMON6_SET_NAME)"
PORTS="$(constant NFT_PORT_SET_NAME)"
IP_PORTS="$(constant NFT_IP_PORT_SET_NAME)"
IP6_PORTS="$(constant NFT_IP_PORT6_SET_NAME)"
INTERFACES="$(constant NFT_INTERFACE_SET_NAME)"
DISCORD="$(constant NFT_DISCORD_SET_NAME)"
DISCORD6="$(constant NFT_DISCORD6_SET_NAME)"
FAKEIP_MARK="$(constant NFT_FAKEIP_MARK)"
OUTBOUND_MARK="$(constant NFT_OUTBOUND_MARK)"
FAKEIP_RANGE="$(constant SB_FAKEIP_INET4_RANGE)"
FAKEIP6_RANGE="$(constant SB_FAKEIP_INET6_RANGE)"
TPROXY_PORT="$(constant SB_TPROXY_INBOUND_PORT)"
TPROXY6_ADDRESS="$(constant SB_TPROXY_INBOUND6_ADDRESS)"

# ---- kernel expressions -------------------------------------------------------

# A kernel may lack an expression Forkop uses (this is the case for nft_queue
# in some VM kernels without modules). Only then, and only for that
# expression, the real batch must fail nothing but the kernel's "No such file
# or directory" on it; the kernel stage then continues with the statement
# removed. Every other rejection fails the test.
MISSING=()
probe_feature() {
  local name="$1" chain="$2" rule="$3" out
  if out="$(printf 'add table inet forkop_probe\nadd chain inet forkop_probe c { %s }\nadd rule inet forkop_probe c %s\n' \
    "$chain" "$rule" | nft -c -f - 2>&1)"; then
    return 0
  fi
  case "$out" in
    *'Error: Could not process rule: No such file or directory'*) ;;
    *) fail "kernel probe for the nft $name expression failed unexpectedly: $out" ;;
  esac
  MISSING+=("$name")
  printf 'NOTE: this kernel has no nft %s expression; batches using it are checked by the nft parser and evaluator, and the kernel stage runs without it\n' "$name"
}
probe_feature queue 'type filter hook output priority 0; policy accept;' 'queue num 1 bypass'
probe_feature tproxy 'type filter hook prerouting priority 0; policy accept;' 'meta l4proto tcp tproxy ip to :1'
probe_feature redirect 'type nat hook prerouting priority 0; policy accept;' 'tcp dport 53 redirect to :1'
# The socket probe resolves the TorrServer cgroup, which only exists (and is
# only needed) with the private hierarchy.
[ "$CGROUP_MOUNTED" = 0 ] ||
  probe_feature socket 'type route hook output priority 0; policy accept;' 'socket cgroupv2 level 2 "services/torrserver"'
[ -z "$(nft list ruleset)" ] || fail "kernel probes left state behind"
supported() { [[ " ${MISSING[*]:-} " != *" $1 "* ]]; }

strip_missing() {
  local sed_args=() name
  for name in "${MISSING[@]}"; do
    case "$name" in
      queue) sed_args+=(-e 's/ queue num [0-9]+( bypass)?//') ;;
      tproxy) sed_args+=(-e 's/ tproxy ip6? to [^ ]+//') ;;
      redirect) sed_args+=(-e 's/ redirect to :[0-9]+//') ;;
      socket) sed_args+=(-e 's/ socket cgroupv2 level [0-9]+ "[^"]*"//') ;;
    esac
  done
  sed -E "${sed_args[@]}" "$1"
}

# Every error of `nft -c -f <batch>` (in $2) is the kernel lacking one of the
# MISSING expressions at exactly that expression.
only_missing_features() {
  local batch="$1" errors="$2" header line from to message token name count=0 matched
  local pattern='^.*:([0-9]+):([0-9]+)-([0-9]+): Error: (.*)$'
  while IFS= read -r header; do
    [[ "$header" =~ $pattern ]] || return 1
    line="${BASH_REMATCH[1]}" from="${BASH_REMATCH[2]}" to="${BASH_REMATCH[3]}" message="${BASH_REMATCH[4]}"
    [ "$message" = 'Could not process rule: No such file or directory' ] || return 1
    token="$(sed -n "${line}p" "$batch" | cut -c"${from}-${to}")"
    matched=0
    for name in "${MISSING[@]}"; do
      [[ "$token" == "$name"* ]] && matched=1
    done
    [ "$matched" = 1 ] || return 1
    count=$((count + 1))
  done < <(grep 'Error:' "$errors")
  [ "$count" -gt 0 ]
}

# Validates a batch through the production entry point (nft/apply.uc
# nft-validate-candidate-batch, i.e. `nft -c -f`) and leaves in CHECKED the
# batch the kernel can take.
CHECKED=""
check_batch() {
  local batch="$1" label="$2"
  CHECKED="$batch"
  if [ "${#MISSING[@]}" -gt 0 ] && ! nft -c -f "$batch" 2>"$batch.err"; then
    only_missing_features "$batch" "$batch.err" ||
      fail "$label: nft rejected the batch: $(cat "$batch.err")"
    CHECKED="$batch.kernel"
    strip_missing "$batch" >"$CHECKED"
  fi
  nft_uc nft-validate-candidate-batch "$CHECKED" 2>"$batch.err" ||
    fail "$label: nft -c rejected the batch: $(cat "$batch.err")"
}
commit_batch() {
  nft_uc nft-commit-candidate-batch "$CHECKED" 2>"$CHECKED.apply.err" ||
    fail "$2: nft -f rejected the checked batch: $(cat "$CHECKED.apply.err")"
  nft -j list ruleset >"$1"
}

# ---- start/reload candidate ---------------------------------------------------

# Arguments of service/lifecycle.uc nft_rebuild_runtime() and
# nft_populate_runtime_sets().
rebuild_args=(
  "$RT_TABLE" "$TABLE" "$LOCALV4" "$COMMON" "$PORTS" "$IP_PORTS" "$INTERFACES"
  "$FAKEIP_MARK" "$OUTBOUND_MARK" "$FAKEIP_RANGE" "$TPROXY_PORT"
  "$LOCALV6" "$COMMON6" "$IP6_PORTS" "$FAKEIP6_RANGE" "$TPROXY6_ADDRESS"
)
populate_args=(
  1 "" "$TABLE" "$COMMON" "$PORTS" "$IP_PORTS" "$INTERFACES" "$LOCALV4" "$FAKEIP_MARK"
  "$COMMON6" "$IP6_PORTS" "$LOCALV6"
)

# One candidate transaction as start/reload records it: the runtime model,
# the cached list data (components/updates.uc, same entry points), the
# runtime sets. $3 names a function adding the list data, if any.
candidate() {
  local state="$1" batch="$2" lists="${3:-}"
  printf '# Forkop nft candidate\n' >"$batch"
  export FORKOP_UCI_STATE_FILE="$state" FORKOP_NFT_BATCH_FILE="$batch"
  nft_uc nft-rebuild-runtime-from-uci "${rebuild_args[@]}" || fail "$batch: nft-rebuild-runtime-from-uci failed"
  [ -z "$lists" ] || "$lists"
  nft_uc nft-populate-runtime-sets-from-uci "${populate_args[@]}" || fail "$batch: nft-populate-runtime-sets-from-uci failed"
  unset FORKOP_UCI_STATE_FILE FORKOP_NFT_BATCH_FILE
}
first_command() { grep -v '^#' "$1" | head -n 1; }

# -- empty configuration: fresh start --
cat >"$WORK_DIR/empty.uci" <<'EOF'
forkop.settings=settings
EOF
candidate "$WORK_DIR/empty.uci" "$WORK_DIR/empty.nft"
[ "$(first_command "$WORK_DIR/empty.nft")" = "add table inet $TABLE" ] ||
  fail "a fresh start must not delete a table that is not there"
check_batch "$WORK_DIR/empty.nft" "empty configuration"
commit_batch "$WORK_DIR/empty.json" "empty configuration"
check tables "$WORK_DIR/empty.json" "$TABLE"
check production "$WORK_DIR/empty.json" "$TABLE" "$OUTBOUND_MARK" no
check set "$WORK_DIR/empty.json" "$TABLE" "$INTERFACES" br-lan
check set "$WORK_DIR/empty.json" "$TABLE" "$LOCALV4" 10.0.0.0/8 192.168.0.0/16
check set "$WORK_DIR/empty.json" "$TABLE" "$LOCALV6" fc00::/7 fe80::/10
check empty-set "$WORK_DIR/empty.json" "$TABLE" "$COMMON" "$COMMON6" "$PORTS" "$IP_PORTS" "$IP6_PORTS"
grep -Fxq "105 $RT_TABLE" "$FORKOP_RT_TABLES" || fail "the route table registry was not written to FORKOP_RT_TABLES"
ok "empty configuration: fresh candidate checked and applied"

# -- connections: domains, IPs, ports, device filters, lists (reload) --
cat >"$WORK_DIR/connections.uci" <<'EOF'
forkop.settings=settings
forkop.settings.source_network_interfaces=br-lan wg0
forkop.settings.exclude_ntp=1
forkop.main=section
forkop.main.enabled=1
forkop.main.action=connection
forkop.main.domain=example.com
forkop.main.domain_suffix=example.org
forkop.main.ip_cidr=93.184.216.0/24 2606:2800:220::/48
forkop.main.source_ip_cidr=192.168.1.0/24 fd00:1::/64
forkop.main.excluded_source_ip_cidr=192.168.1.5
forkop.main.fully_routed_ips=192.168.1.20 fd00:1::20
forkop.main.remote_subnet_lists=https://lists.example/subnets.lst
forkop.ports=section
forkop.ports.action=connection
forkop.ports.ip_cidr=93.184.217.0/24 2606:2800:221::/48
forkop.ports.ports=443 8443-8444
forkop.ports.community_lists=telegram discord
forkop.ports.rule_set_with_subnets=https://lists.example/rules.json
forkop.portonly=section
forkop.portonly.action=connection
forkop.portonly.ports=5000-5010
forkop.resolver=section
forkop.resolver.action=dns
forkop.resolver.domain=router.example
forkop.resolver.source_ip_cidr=192.168.2.40
forkop.disabled=section
forkop.disabled.enabled=0
forkop.disabled.action=connection
forkop.disabled.ip_cidr=93.184.230.0/24
EOF
# Several chunks per set, and entries overlapping other chunks and the
# section's own ip_cidr, which the batch adds later.
printf '%s\n' 93.184.221.0/24 93.184.226.0/24 93.184.221.128/25 93.184.227.1 93.184.216.128/25 \
  2606:2800:222::/48 2606:2800:226::/48 2606:2800:222:1::/64 not-an-address >"$WORK_DIR/subnets.lst"
printf '149.154.160.0/20\n2001:67c:4e8::/48\n' >"$WORK_DIR/telegram.lst"
printf '66.22.192.0/18\n162.159.0.0/16\n2606:4700::/32\n' >"$WORK_DIR/discord.lst"
printf '{"version":2,"rules":[{"ip_cidr":["93.184.222.0/24","2606:2800:223::/48"]}]}\n' >"$WORK_DIR/rules.json"
connections_lists() {
  nft_uc nft-add-subnet-file-for-uci-section main "$WORK_DIR/subnets.lst" \
    "$TABLE" "$COMMON" "$IP_PORTS" 2 "$COMMON6" "$IP6_PORTS" || fail "subnet list data"
  local service
  for service in telegram discord; do
    nft_uc nft-add-community-subnet-file-for-uci-section ports "$service" "$WORK_DIR/$service.lst" \
      "$TABLE" "$COMMON" "$IP_PORTS" "$INTERFACES" "$DISCORD" "$FAKEIP_MARK" 5000 \
      "$COMMON6" "$IP6_PORTS" "$DISCORD6" || fail "$service list data"
  done
  nft_uc nft-add-json-ruleset-subnets-for-uci-section ports "$WORK_DIR/rules.json" "fixture rule set" \
    "$TABLE" "$COMMON" "$IP_PORTS" "$WORK_DIR/unscoped.lst" "$WORK_DIR/scoped.lst" 5000 \
    "$COMMON6" "$IP6_PORTS" || fail "rule-set list data"
}
candidate "$WORK_DIR/connections.uci" "$WORK_DIR/connections.nft" connections_lists
[ "$(first_command "$WORK_DIR/connections.nft")" = "delete table inet $TABLE" ] ||
  fail "a reload candidate must replace the live table in the same transaction"
for set in forkop_rule_main_subnets forkop_rule_main_subnets6; do
  [ "$(grep -c "^add element inet $TABLE $set { " "$WORK_DIR/connections.nft")" -gt 2 ] ||
    fail "the list data did not reach $set in several chunks"
done
check_batch "$WORK_DIR/connections.nft" "connections"
commit_batch "$WORK_DIR/connections.json" "connections"
json="$WORK_DIR/connections.json"
check tables "$json" "$TABLE"
check production "$json" "$TABLE" "$OUTBOUND_MARK" no
check set "$json" "$TABLE" "$INTERFACES" br-lan wg0
check set "$json" "$TABLE" forkop_rule_main_subnets 93.184.216.0/24 93.184.221.0/24 93.184.226.0/24 93.184.227.1
check set "$json" "$TABLE" forkop_rule_main_subnets6 2606:2800:220::/48 2606:2800:222::/48 2606:2800:226::/48
check set "$json" "$TABLE" forkop_rule_main_sources 192.168.1.0/24
check set "$json" "$TABLE" forkop_rule_main_sources6 fd00:1::/64
check set "$json" "$TABLE" forkop_rule_main_excluded_sources 192.168.1.5
check set "$json" "$TABLE" forkop_rule_main_fully_sources 192.168.1.20
check set "$json" "$TABLE" forkop_rule_main_fully_sources6 fd00:1::20
check set "$json" "$TABLE" forkop_rule_ports_ip_ports '93.184.217.0/24 . 443' '93.184.217.0/24 . 8443-8444' \
  '149.154.160.0/20 . 443' '66.22.192.0/18 . 8443-8444' '93.184.222.0/24 . 443'
check set "$json" "$TABLE" forkop_rule_ports_ip6_ports '2606:2800:221::/48 . 443' '2001:67c:4e8::/48 . 8443-8444' \
  '2606:2800:223::/48 . 8443-8444'
check set "$json" "$TABLE" forkop_rule_ports_udp_ip_ports '162.159.0.0/16 . 3478'
check set "$json" "$TABLE" forkop_rule_ports_udp_ip6_ports '2606:4700::/32 . 3478'
check set "$json" "$TABLE" forkop_rule_portonly_ports 5000-5010
check set "$json" "$TABLE" forkop_dns_sources 192.168.1.0/24 192.168.2.40
check set "$json" "$TABLE" forkop_dns_sources6 fd00:1::/64
if grep -Fq 'forkop_rule_disabled_' "$WORK_DIR/connections.nft"; then
  fail "a disabled section produced nft objects"
fi
ok "connections with domains, IPs, ports, device filters and list data: reload candidate checked and applied"

# -- bypass priority rules --
cat >"$WORK_DIR/bypass.uci" <<'EOF'
forkop.settings=settings
forkop.lan=section
forkop.lan.action=bypass
forkop.lan.ip_cidr=93.184.218.0/24 2606:2800:224::/48
forkop.lan.fully_routed_ips=192.168.1.30
forkop.lan.excluded_source_ip_cidr=192.168.1.31
forkop.lanports=section
forkop.lanports.action=bypass
forkop.lanports.ip_cidr=93.184.225.0/24
forkop.lanports.ports=22
forkop.vpn=section
forkop.vpn.action=connection
forkop.vpn.ip_cidr=93.184.218.0/23
EOF
candidate "$WORK_DIR/bypass.uci" "$WORK_DIR/bypass.nft"
check_batch "$WORK_DIR/bypass.nft" "bypass"
commit_batch "$WORK_DIR/bypass.json" "bypass"
json="$WORK_DIR/bypass.json"
check production "$json" "$TABLE" "$OUTBOUND_MARK" no
check set "$json" "$TABLE" forkop_rule_lan_subnets 93.184.218.0/24
check set "$json" "$TABLE" forkop_rule_lan_subnets6 2606:2800:224::/48
check set "$json" "$TABLE" forkop_rule_lan_fully_sources 192.168.1.30
check set "$json" "$TABLE" forkop_rule_lanports_ip_ports '93.184.225.0/24 . 22'
check set "$json" "$TABLE" forkop_rule_vpn_subnets 93.184.218.0/23
# A bypass rule above a capture rule for the same addresses decides first.
check order "$json" "$TABLE" priority_rules forkop_rule_lan_subnets forkop_rule_vpn_subnets
check order "$json" "$TABLE" priority_output_rules forkop_rule_lan_subnets forkop_rule_vpn_subnets
check verdicts "$json" "$TABLE" priority_rules forkop_rule_lan_subnets accept-unmarked
check verdicts "$json" "$TABLE" priority_rules forkop_rule_vpn_subnets "accept-mark:$(hex_to_dec "$FAKEIP_MARK")"
ok "bypass priority rules: candidate checked and applied"

# An atomic rollback of the live table (delete + `nft list table` output,
# validated) restores it exactly after another candidate replaced it.
{
  printf 'delete table inet %s\n' "$TABLE"
  nft list table inet "$TABLE"
} >"$WORK_DIR/rollback.nft"
nft_uc nft-validate-candidate-batch "$WORK_DIR/rollback.nft" 2>"$WORK_DIR/rollback.err" ||
  fail "the rollback batch built from the live table is rejected: $(cat "$WORK_DIR/rollback.err")"
node "$CHECK_JS" normalize "$json" "$TABLE" >"$WORK_DIR/before-switch.norm"

# -- a second candidate replaces the table --
cat >"$WORK_DIR/switch.uci" <<'EOF'
forkop.settings=settings
forkop.off=section
forkop.off.enabled=0
forkop.off.action=connection
forkop.off.domain=off.example
forkop.yt=section
forkop.yt.action=connection
forkop.yt.domain=youtube.com
forkop.yt.ip_cidr=93.184.219.0/24
EOF
candidate "$WORK_DIR/switch.uci" "$WORK_DIR/switch.nft"
check_batch "$WORK_DIR/switch.nft" "switch"
SWITCH_CHECKED="$CHECKED"
commit_batch "$WORK_DIR/switch.json" "switch"
check production "$WORK_DIR/switch.json" "$TABLE" "$OUTBOUND_MARK" no
check set "$WORK_DIR/switch.json" "$TABLE" forkop_rule_yt_subnets 93.184.219.0/24
ok "second candidate: checked and applied over the live table"

# Rollback round trip: the saved table comes back exactly.
nft -f "$WORK_DIR/rollback.nft" || fail "the rollback batch does not apply"
nft -j list ruleset >"$WORK_DIR/rolled-back.json"
node "$CHECK_JS" normalize "$WORK_DIR/rolled-back.json" "$TABLE" >"$WORK_DIR/after-rollback.norm"
cmp -s "$WORK_DIR/before-switch.norm" "$WORK_DIR/after-rollback.norm" ||
  fail "the rollback did not restore the previous table"
ok "rollback batch round trip restores the previous table"
CHECKED="$SWITCH_CHECKED"
commit_batch "$WORK_DIR/switch.json" "switch again"

# ---- negative controls ----------------------------------------------------------

# A broken candidate is refused by the production validation and by nft -f
# alone, and the live policy stays exactly as it was.
node "$CHECK_JS" normalize "$WORK_DIR/switch.json" "$TABLE" >"$WORK_DIR/live.norm"
assert_refused() {
  local broken="$1" label="$2" location="$3" message="$4"
  if nft_uc nft-validate-candidate-batch "$broken" 2>"$broken.err"; then
    fail "$label: nft -c accepted a broken batch"
  fi
  grep -q "^$(basename "$broken"):$location: Error: .*$message" <(sed 's|^.*/||' "$broken.err") ||
    fail "$label: nft did not report the break at line ${location%%:*}: $(cat "$broken.err")"
  if nft_uc nft-commit-candidate-batch "$broken" 2>/dev/null; then
    fail "$label: nft -f applied a broken batch"
  fi
  nft -j list ruleset >"$broken.json"
  node "$CHECK_JS" normalize "$broken.json" "$TABLE" | cmp -s - "$WORK_DIR/live.norm" ||
    fail "$label: a refused batch changed the live table"
  ok "negative control: $label is refused and changes nothing"
}
# A typo in the last rule: everything before it would be valid.
last_rule="$(grep -n '^add rule ' "$SWITCH_CHECKED" | tail -n 1 | cut -d: -f1)"
sed "${last_rule}s/\$/ acept/" "$SWITCH_CHECKED" >"$WORK_DIR/broken-syntax.nft"
assert_refused "$WORK_DIR/broken-syntax.nft" "syntax error in the last rule" "$last_rule:[0-9-]*" "syntax error"
appended=$(($(wc -l <"$SWITCH_CHECKED") + 1))
{ cat "$SWITCH_CHECKED"; printf 'add rule inet %s mangle_output ip daddr @forkop_missing counter\n' "$TABLE"; } \
  >"$WORK_DIR/broken-set.nft"
assert_refused "$WORK_DIR/broken-set.nft" "reference to a missing set" "$appended:[0-9-]*" "No such file or directory"
{ cat "$SWITCH_CHECKED"; printf 'add rule inet %s mangle_output meta mark set 0x08000000 queue num 70000\n' "$TABLE"; } \
  >"$WORK_DIR/broken-range.nft"
assert_refused "$WORK_DIR/broken-range.nft" "out-of-range queue number" "$appended:[0-9-]*" "exceeds valid range"

# ---- guards -----------------------------------------------------------------------

guard_state() { nft_uc dpi-transition-guard-state "$1"; }
# nft < 1.1.0 prints `meta mark & 0xff000000` as a prefix; the verifier
# accepts only the `&` rendering (UC-106, stage S8). There it may still say
# "invalid"; everywhere else it must recognise the guard it created.
expect_guard_valid() {
  local base="$1" rendering="$2" state
  state="$(guard_state "$base")"
  if [ "$rendering" = and ]; then
    [ "$state" = valid ] || fail "${base}DpiGuard: verifier state '$state' for a guard it created"
  else
    printf 'NOTE: this nft prints the guard mark as a prefix (UC-106); verifier state: %s\n' "$state"
    [ "$state" = valid ] || [ "$state" = invalid ] || fail "${base}DpiGuard: verifier state '$state'"
  fi
}

# -- DPI transition guard: a separate table, untouched by a candidate reload --
nft_uc install-dpi-transition-guard "$TABLE" || fail "install-dpi-transition-guard failed"
nft -j list ruleset >"$WORK_DIR/guard.json"
check tables "$WORK_DIR/guard.json" "$TABLE" "${TABLE}DpiGuard"
dpi_rendering="$(node "$CHECK_JS" dpi-guard "$WORK_DIR/guard.json" "${TABLE}DpiGuard")" ||
  fail "the DPI transition guard does not have its expected structure"
expect_guard_valid "$TABLE" "$dpi_rendering"
node "$CHECK_JS" normalize "$WORK_DIR/guard.json" "${TABLE}DpiGuard" >"$WORK_DIR/guard.norm"
candidate "$WORK_DIR/connections.uci" "$WORK_DIR/reload-guarded.nft" connections_lists
check_batch "$WORK_DIR/reload-guarded.nft" "reload under the DPI guard"
commit_batch "$WORK_DIR/reload-guarded.json" "reload under the DPI guard"
node "$CHECK_JS" normalize "$WORK_DIR/reload-guarded.json" "${TABLE}DpiGuard" | cmp -s - "$WORK_DIR/guard.norm" ||
  fail "a candidate reload changed the DPI transition guard"
nft_uc remove-dpi-transition-guard "$TABLE" || fail "remove-dpi-transition-guard failed"
[ "$(guard_state "$TABLE")" = absent ] || fail "the DPI transition guard was not removed"
ok "DPI transition guard: applied as its own table, survives a candidate reload, removed"

# -- config restore guard (config/snapshots.uc: ensure / remove) --
restore_status=0
nft_uc ensure-dpi-transition-guard ForkopConfigRestore || restore_status=$?
nft -j list ruleset >"$WORK_DIR/restore-guard.json"
check tables "$WORK_DIR/restore-guard.json" "$TABLE" ForkopConfigRestoreDpiGuard
restore_rendering="$(node "$CHECK_JS" dpi-guard "$WORK_DIR/restore-guard.json" ForkopConfigRestoreDpiGuard)" ||
  fail "the config restore guard does not have its expected structure"
if [ "$restore_rendering" = and ]; then
  [ "$restore_status" = 0 ] || fail "ensure-dpi-transition-guard could not verify the guard it created"
  nft_uc ensure-dpi-transition-guard ForkopConfigRestore || fail "ensure-dpi-transition-guard is not idempotent"
fi
expect_guard_valid ForkopConfigRestore "$restore_rendering"
nft_uc remove-dpi-transition-guard ForkopConfigRestore || fail "removing the config restore guard failed"
[ "$(guard_state ForkopConfigRestore)" = absent ] || fail "the config restore guard was not removed"
ok "config restore guard: created, checked, removed"

# -- cross-component transition guard (a chain in the live table) --
nft_uc install-transition-guard "$TABLE" "$FAKEIP_MARK" || fail "install-transition-guard failed"
nft -j list ruleset >"$WORK_DIR/transition.json"
check transition-guard "$WORK_DIR/transition.json" "$TABLE" "$(hex_to_dec "$FAKEIP_MARK")"
if nft_uc install-transition-guard "$TABLE" "$FAKEIP_MARK" 2>/dev/null; then
  fail "install-transition-guard accepted an already installed guard"
fi
nft_uc remove-transition-guard "$TABLE" "$FAKEIP_MARK" || fail "remove-transition-guard failed"
nft_uc remove-transition-guard "$TABLE" "$FAKEIP_MARK" || fail "remove-transition-guard is not idempotent"
nft -j list ruleset >"$WORK_DIR/transition-removed.json"
check absent-chain "$WORK_DIR/transition-removed.json" "$TABLE" forkop_transition_guard
ok "transition guard: applied, refused twice, removed"

# ---- TorrServer Direct --------------------------------------------------------------

# Without a private cgroup hierarchy (NOTE above) nft cannot resolve the path.
if [ "$CGROUP_MOUNTED" = 1 ]; then
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/torrserver/direct.uc" batch /services/torrserver >"$WORK_DIR/torrserver.nft" ||
    fail "torrserver/direct.uc did not render its batch"
  check_batch "$WORK_DIR/torrserver.nft" "TorrServer Direct"
  commit_batch "$WORK_DIR/torrserver.json" "TorrServer Direct"
  torrserver_cgroup=-
  supported socket && torrserver_cgroup=services/torrserver
  check torrserver "$WORK_DIR/torrserver.json" ForkopTorrServerDirect "$(hex_to_dec "$OUTBOUND_MARK")" "$torrserver_cgroup"
  if supported socket; then
    nft list chain inet ForkopTorrServerDirect output |
      ucode -L "$FORKOP_LIB" "$FORKOP_LIB/torrserver/direct.uc" rule-output-active /services/torrserver ||
      fail "torrserver/direct.uc does not recognise its rule as listed by nft"
  fi
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/torrserver/direct.uc" remove
  nft -j list ruleset >"$WORK_DIR/torrserver-removed.json"
  check tables "$WORK_DIR/torrserver-removed.json" "$TABLE"
  ok "TorrServer Direct: batch checked, applied, recognised and removed"
fi

# Stop removes the table (service/lifecycle.uc stop).
nft delete table inet "$TABLE"
[ -z "$(nft list ruleset)" ] || fail "state is left behind after stop"
printf 'real nft batch checks passed\n'
