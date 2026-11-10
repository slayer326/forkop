#!/bin/sh
# Exercise the transaction with OpenWrt's real UCI and ucode; never touch its network.
set -eu
SOURCE_DIR="${1:?source directory}"
test -r "$SOURCE_DIR/forkop/files/usr/lib/warp/profile.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
export FORKOP_LIB=/usr/lib/forkop
export FORKOP_WARP_NETWORK_FILE="$WORK/config/network"
export FORKOP_WARP_RUNTIME_DIR="$WORK/run"
export FORKOP_WARP_PROTO_DIR="$WORK/proto"
export WARP_TEST_ROOT="$WORK"
mkdir -p "$WORK/config" "$WORK/bin" "$WORK/proto" "$WORK/apply" "$WORK/rollback"
cat >"$FORKOP_WARP_NETWORK_FILE" <<'NET'
config interface 'wan'
 option proto 'dhcp'
config interface 'lan'
 option proto 'static'
 option ipaddr '192.168.10.1'
NET
cat >"$WORK/bin/wg" <<'SH'
#!/bin/sh
exit 0
SH
cp "$WORK/bin/wg" "$WORK/bin/ubus"
cp "$WORK/bin/wg" "$WORK/bin/ifdown"
cat >"$WORK/bin/ip" <<'SH'
#!/bin/sh
if [ "$1" = -4 ]; then printf '192.168.10.0/24 dev br-lan scope link\n'; else exit 1; fi
SH
cat >"$WORK/bin/ifup" <<'SH'
#!/bin/sh
[ ! -e "$WARP_TEST_ROOT/fail" ]
SH
chmod +x "$WORK/bin/"*
printf '# wireguard\n' >"$WORK/proto/wireguard.sh"
export PATH="$WORK/bin:$PATH"
test -x /usr/libexec/rpcd/forkop-warp
test -r "$FORKOP_LIB/warp/service.uc"
cp "$FORKOP_WARP_NETWORK_FILE" "$WORK/original"
cat >"$WORK/profile" <<'PROFILE'
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=
Address = 172.16.0.2/32
DNS = 1.1.1.1
[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI=
Endpoint = 162.159.192.1:2408
AllowedIPs = 0.0.0.0/0
PROFILE
run_import() {
    ucode -e 'let fs=require("fs"); print(sprintf("%J", {action:"import", name:ARGV[0], kind:"wireguard", profile:fs.readfile(ARGV[1])}));' "$1" "$WORK/profile" |
        /usr/libexec/rpcd/forkop-warp call start >"$WORK/start.json"
    job_id="$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).job_id || "");' "$WORK/start.json")"
    [ -n "$job_id" ] || { cat "$WORK/start.json"; return 1; }
    for _attempt in $(seq 1 200); do
        printf '{"id":"%s"}' "$job_id" | /usr/libexec/rpcd/forkop-warp call job >"$WORK/result.json"
        if ! grep -q '"pending": true' "$WORK/result.json"; then break; fi
        sleep 0.1
    done
    printf '{"id":"%s"}' "$job_id" | /usr/libexec/rpcd/forkop-warp call ack >/dev/null
}
run_import fkwtest
ucode -e 'let r=json(require("fs").readfile(ARGV[0])); if(!r.success) { warn(r.message,"\n");exit(1); }' "$WORK/result.json"
test "$(uci -q -c "$WORK/config" get network.fkwtest_peer.route_allowed_ips)" = 0
test "$(uci -q -c "$WORK/config" get network.fkwtest.peerdns)" = 0
test "$(uci -q -c "$WORK/config" get network.lan.ipaddr)" = 192.168.10.1
cp "$WORK/original" "$FORKOP_WARP_NETWORK_FILE"
touch "$WORK/fail"
run_import fkwfail
ucode -e 'let r=json(require("fs").readfile(ARGV[0])); if(r.success) exit(1);' "$WORK/result.json"
cmp "$WORK/original" "$FORKOP_WARP_NETWORK_FILE"
test "$(uci -q -c "$WORK/config" get network.wan.proto)" = dhcp
printf 'WARP import and rollback with real OpenWrt UCI and RPC entrypoint passed\n'
