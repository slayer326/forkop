#!/bin/sh
# Exercise the transaction with OpenWrt's real UCI and ucode; never touch its network.
set -eu
SOURCE_DIR="${1:?source directory}"
test -r "$SOURCE_DIR/forkop/files/usr/lib/warp/profile.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
export FORKOP_LIB=/usr/lib/forkop
export FORKOP_WARP_NETWORK_FILE="$WORK/config/network"
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
cat >"$WORK/test.uc" <<'UC'
let fs = require("fs"), service = require("warp.service");
let root = getenv("WARP_TEST_ROOT"), path = getenv("FORKOP_WARP_NETWORK_FILE");
let original = fs.readfile(path);
let profile = "[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=\nAddress = 172.16.0.2/32\nDNS = 1.1.1.1\n[Peer]\nPublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI=\nEndpoint = 162.159.192.1:2408\nAllowedIPs = 0.0.0.0/0\n";
let result = service.import_profile({ name:"fkwtest", profile }, root + "/apply");
if (!result.success) die("WARP import failed");
let network = fs.readfile(path);
if (index(network, "192.168.10.1") < 0 || index(network, "route_allowed_ips '0'") < 0 || index(network, "1.1.1.1") >= 0)
    die("Network isolation failed");
fs.writefile(path, original);
fs.writefile(root + "/fail", "1");
let refused = false;
try { service.import_profile({ name:"fkwfail", profile }, root + "/rollback"); } catch (e) { refused = true; }
if (!refused || fs.readfile(path) != original) die("WARP rollback failed");
print("WARP import and rollback with real OpenWrt UCI passed\n");
UC
ucode -L "$FORKOP_LIB" "$WORK/test.uc"
test "$(uci -q -c "$WORK/config" get network.wan.proto)" = dhcp
