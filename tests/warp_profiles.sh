#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FORKOP_LIB="$ROOT/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export WARP_TEST_ROOT="$WORK"
mkdir -p "$WORK/bin" "$WORK/proto" "$WORK/config"
export FORKOP_WARP_NETWORK_FILE="$WORK/config/network"
export FORKOP_WARP_RUNTIME_DIR="$WORK/run"
export FORKOP_WARP_PROTO_DIR="$WORK/proto"
export FORKOP_WARP_UCI_SAVEDIR="$WORK/uci-save"
export FORKOP_UCI_STATE_FILE="$WORK/forkop.state"
export PATH="$WORK/bin:$PATH"
cat >"$FORKOP_UCI_STATE_FILE" <<'STATE'
forkop.settings=settings
forkop.settings.download_lists_via_proxy=1
forkop.settings.download_lists_via_proxy_section=relay
forkop.relay=section
forkop.relay.enabled=1
forkop.relay.action=connection
STATE
cat >"$FORKOP_WARP_NETWORK_FILE" <<'NET'
config interface 'wan'
 option proto 'dhcp'
config interface 'lan'
 option proto 'static'
 option ipaddr '192.168.10.1'
NET
cat >"$WORK/bin/uci" <<'PY'
#!/usr/bin/env python3
import os, sys, shlex, pathlib, fcntl
args = sys.argv[1:]
directory = pathlib.Path(os.environ['FORKOP_WARP_NETWORK_FILE']).parent
while args and args[0].startswith('-'):
    flag = args.pop(0)
    if flag in ('-c', '-t'):
        value = args.pop(0)
        if flag == '-c': directory = pathlib.Path(value)
path = directory/'network'
if path.exists():
    held = path.open('r')
    try: fcntl.flock(held, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        (pathlib.Path(os.environ['WARP_TEST_ROOT'])/'blocked_uci_read').touch()
        sys.exit(99)
sections = {}
current = None
for line in path.read_text().splitlines() if path.exists() else []:
    parts = shlex.split(line)
    if not parts: continue
    if parts[0] == 'config':
        current = parts[2]; sections[current] = {'.type':parts[1]}
    elif current and parts[0] in ('option', 'list'):
        sections[current][parts[1]] = parts[2]
verb = args[0]
if verb == 'changes':
    if (pathlib.Path(os.environ['WARP_TEST_ROOT'])/'pending').exists(): print("network.wan.proto='pppoe'")
elif verb == 'get':
    parts = args[1].split('.')
    entry = sections.get(parts[1])
    value = entry.get(parts[2]) if entry and len(parts)>2 else entry.get('.type') if entry else None
    if value is None: sys.exit(1)
    print(value)
elif verb == 'batch':
    for line in sys.stdin:
        parts = shlex.split(line)
        if parts[0] == 'commit': continue
        key, value = parts[1].split('=',1)
        names = key.split('.')
        if len(names)==2: sections[names[1]]={'.type':value}
        elif parts[0]=='add_list': sections[names[1]].setdefault(names[2],[]); sections[names[1]][names[2]].append(value)
        else: sections[names[1]][names[2]]=value
    text = ''
    for name, values in sections.items():
        text += f"config {values['.type']} '{name}'\n"
        for field, value in values.items():
            if field=='.type': continue
            for item in value if isinstance(value,list) else [value]:
                text += f" {'list' if isinstance(value,list) else 'option'} {field} '{item}'\n"
    path.write_text(text)
    if (pathlib.Path(os.environ['WARP_TEST_ROOT'])/'stage_race').exists():
        delta=pathlib.Path(os.environ['FORKOP_WARP_UCI_SAVEDIR']); delta.mkdir(exist_ok=True)
        (delta/'network').write_text("network.wan.proto='pppoe'\n")
else: sys.exit(1)
PY
cat >"$WORK/bin/wg" <<'SH'
#!/bin/sh
case "$1" in
genkey) printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=\n';;
pubkey) cat >/dev/null; printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI=\n';;
show) printf 'peer\t1700000000\n';;
esac
SH
cp "$WORK/bin/wg" "$WORK/bin/awg"
cat >"$WORK/bin/ubus" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$WARP_TEST_ROOT/commands"
[ "${WARP_RELOAD_FAIL:-0}" != 1 ]
SH
cat >"$WORK/bin/ifup" <<'SH'
#!/bin/sh
printf 'ifup %s\n' "$*" >>"$WARP_TEST_ROOT/commands"
[ ! -e "$WARP_TEST_ROOT/ifup_fail" ]
SH
cat >"$WORK/bin/ifdown" <<'SH'
#!/bin/sh
printf 'ifdown %s\n' "$*" >>"$WARP_TEST_ROOT/commands"
SH
cat >"$WORK/bin/ip" <<'SH'
#!/bin/sh
if [ "$1" = -4 ]; then
  if [ -e "$WARP_TEST_ROOT/overlap" ]; then printf '172.16.0.0/24 dev br-lan scope link\n';
  else printf '192.168.10.0/24 dev br-lan scope link\n'; fi
else exit 1; fi
SH
cat >"$WORK/bin/dig" <<'SH'
#!/bin/sh
if [ -e "$WARP_TEST_ROOT/fakeip" ]; then printf '198.18.0.1\n'; else printf '162.159.192.1\n'; fi
SH
cat >"$WORK/bin/modprobe" <<'SH'
#!/bin/sh
[ ! -e "$WARP_TEST_ROOT/module_fail" ]
SH
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$WARP_TEST_ROOT/commands"
output=''
proxy=''
no_proxy='unset'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2;;
    --proxy) proxy="$2"; shift 2;;
    --noproxy) no_proxy="$2"; shift 2;;
    *) shift;;
  esac
done
[ -z "$proxy" ] || [ -z "$no_proxy" ] || exit 1
printf '%s\n' '{"config":{"interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:1234::2"}},"peers":[{"public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM=","endpoint":{"v4":"162.159.192.1:0","ports":[2408]}}]}}' >"$output"
if [ -e "$WARP_TEST_ROOT/http_code" ]; then cat "$WARP_TEST_ROOT/http_code"; else printf 200; fi
SH
cat >"$WORK/bin/apk" <<'SH'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >>"$WARP_TEST_ROOT/commands"
case "$*" in
  *--simulate*|*--noaction*) [ ! -e "$WARP_TEST_ROOT/package_fail" ] ;;
  update) exit 0 ;;
  *) printf '# wireguard\n' >"$FORKOP_WARP_PROTO_DIR/wireguard.sh" ;;
esac
SH
chmod +x "$WORK/bin/"*
printf '# wireguard\n' >"$WORK/proto/wireguard.sh"
printf '# jc jmin jmax s1 s2 h1 h2 h3 h4\n' >"$WORK/proto/amneziawg.sh"
cat >"$WORK/test.uc" <<'UC'
let fs = require("fs"), profiles = require("warp.profile"), service = require("warp.service");
const root = getenv("WARP_TEST_ROOT");
let text = "[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=\nAddress = 172.16.0.2/32, 2606:4700:110:1234::2/128\nDNS = 1.1.1.1\n\n[Peer]\nPublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI=\nEndpoint = engage.cloudflareclient.com:2408\nAllowedIPs = 0.0.0.0/0, ::/0\n";
function assert(value, message) { if (!value) die(message); }
function rejects(fn, message) { let rejected = false; try { fn(); } catch (e) { rejected = true; } assert(rejected, message); }
assert(profiles.parse(text, "wireguard").addresses[0] == "172.16.0.2/32", "profile address");
for (let bad in [text + "PostUp = reboot\n", text + "[Peer]\n", replace(text,"2408","99999"), replace(text,"172.16.0.2/32","1.2.3.999/32"), replace(text,"172.16.0.2/32","192.168.1.1/24"), replace(text,"172.16.0.2/32","127.0.0.1/32"), replace(text,"engage.cloudflareclient.com","$(reboot)"), replace(text,"Address =", "Jc = 3\nAddress =")])
    rejects(function() { profiles.parse(bad, "wireguard"); }, "unsafe/invalid profile accepted");
assert(profiles.endpoint("[2606:4700::1]:2408").host == "2606:4700::1", "IPv6 endpoint");
let original = fs.readfile(getenv("FORKOP_WARP_NETWORK_FILE"));
for (let name in [ "wan", "lan", "../../network", "fkwbad-name" ])
    rejects(function() { service.import_profile({ name, profile:text }, root); }, "unsafe name accepted");
fs.mkdir(root + "/apply", 0700);
let result = service.import_profile({ name:"fkwtest", profile:text }, root + "/apply");
assert(result.success, "create interface failed");
let network = fs.readfile(getenv("FORKOP_WARP_NETWORK_FILE"));
assert(index(network, "option proto 'dhcp'") >= 0 && index(network,"192.168.10.1") >= 0, "WAN/LAN changed");
assert(index(network, "option route_allowed_ips '0'") >= 0 && index(network,"option peerdns '0'") >= 0, "default route/DNS protection missing");
assert(index(network,"option fwmark '0x08000000'") >= 0, "tunnel mark missing");
assert(index(network, "list addresses '2606:") < 0, "IPv6 enabled without opt in");
assert(index(network, "1.1.1.1") < 0, "imported DNS applied");
rejects(function() { service.import_profile({ name:"fkwtest", profile:text }, root); }, "existing interface overwritten");
assert(service.status("fkwtest").last_handshake == 1700000000, "handshake status");
fs.writefile(getenv("FORKOP_WARP_NETWORK_FILE"), original);
fs.mkdir(root + "/rollback", 0700);
fs.writefile(root + "/ifup_fail", "1");
rejects(function() { service.import_profile({ name:"fkwfail", profile:text }, root + "/rollback"); }, "ifup failure accepted");
assert(fs.readfile(getenv("FORKOP_WARP_NETWORK_FILE")) == original, "rollback changed original network");
fs.unlink(root + "/ifup_fail");
fs.writefile(root + "/pending", "1");
rejects(function() { service.import_profile({ name:"fkwpending", profile:text }, root); }, "pending changes overwritten");
fs.unlink(root + "/pending");
fs.writefile(root + "/module_fail", "1");
rejects(function() { service.import_profile({ name:"fkwabi", profile:text }, root); }, "unloadable kernel module accepted");
assert(fs.readfile(getenv("FORKOP_WARP_NETWORK_FILE")) == original, "kernel ABI failure changed network");
fs.unlink(root + "/module_fail");
fs.mkdir(root + "/race", 0700);
fs.writefile(root + "/stage_race", "1");
rejects(function() { service.import_profile({ name:"fkwrace", profile:text }, root + "/race"); }, "concurrent staged changes were ignored");
assert(fs.readfile(getenv("FORKOP_WARP_NETWORK_FILE")) == original, "staging race changed network");
fs.unlink(root + "/stage_race");
fs.unlink(getenv("FORKOP_WARP_UCI_SAVEDIR") + "/network");
fs.writefile(root + "/overlap", "1");
rejects(function() { service.import_profile({ name:"fkwoverlap", profile:text }, root); }, "local address overlap accepted");
fs.unlink(root + "/overlap");
fs.writefile(root + "/fakeip", "1");
rejects(function() { service.import_profile({ name:"fkwfake", profile:text }, root); }, "FakeIP endpoint accepted");
fs.unlink(root + "/fakeip");
fs.mkdir(root + "/generate", 0700);
rejects(function() { service.generate({}, root + "/generate"); }, "terms not required");
let generated = service.generate({ accept_terms:true }, root + "/generate");
assert(profiles.parse(generated.profile,"wireguard").endpoint.host == "162.159.192.1", "generated endpoint invalid");
let proxied = service.generate({ accept_terms:true, via_proxy:true }, root + "/generate");
assert(proxied.success, "explicit section proxy was bypassed or rejected");
fs.writefile(root + "/http_code", "403");
rejects(function() { service.generate({ accept_terms:true }, root + "/generate"); }, "Cloudflare refusal accepted");
fs.unlink(root + "/http_code");
assert(fs.readfile(getenv("FORKOP_WARP_NETWORK_FILE")) == original, "registration changed network");
let commands = fs.readfile(root + "/commands");
assert(fs.stat(root + "/blocked_uci_read") == null, "UCI was invoked while its config file was locked exclusively");
assert(index(commands, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=") < 0, "private key in process arguments");
assert(index(commands, "network restart") < 0 && index(commands, "ifup wan") < 0, "network/WAN restarted");
print("WARP validation, import, rollback, registration and privacy checks passed\n");
UC
ucode -S -L "$FORKOP_LIB" "$WORK/test.uc"
test "$(stat -c %a "$WORK/generate/response")" = 600
# Verify the real async RPC contract and private transient storage.
printf '%s\n' '{"action":"generate","kind":"wireguard","accept_terms":true}' |
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/warp/service.uc" rpc start >"$WORK/job.json"
id="$(node -e 'console.log(require(process.argv[1]).job_id)' "$WORK/job.json")"
for _attempt in $(seq 1 100); do
  printf '{"id":"%s"}\n' "$id" | ucode -L "$FORKOP_LIB" "$FORKOP_LIB/warp/service.uc" rpc job >"$WORK/result.json"
  if ! grep -q '"pending": true' "$WORK/result.json"; then break; fi
  sleep 0.1
done
node -e 'const r=require(process.argv[1]); if(!r.success || !r.profile) process.exit(1)' "$WORK/result.json"
test "$(stat -c %a "$FORKOP_WARP_RUNTIME_DIR")" = 700
test "$(stat -c %a "$FORKOP_WARP_RUNTIME_DIR/$id.result")" = 600
test ! -e "$FORKOP_WARP_RUNTIME_DIR/$id.request"
test ! -e "$FORKOP_WARP_RUNTIME_DIR/work-$id"
printf '{"id":"%s"}\n' "$id" | ucode -L "$FORKOP_LIB" "$FORKOP_LIB/warp/service.uc" rpc ack >/dev/null
test ! -e "$FORKOP_WARP_RUNTIME_DIR/$id.result"
node - "$ROOT/luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json" <<'JS'
const assert=require('node:assert/strict'), acl=require(process.argv[2])['luci-app-forkop'];
assert.deepEqual(acl.read.ubus['forkop-warp'], ['capabilities','status']);
assert.deepEqual(acl.write.ubus['forkop-warp'], ['start','job','ack']);
JS
printf 'WARP async jobs and RPC permissions passed\n'

prepare_job() {
  printf '%s\n' '{"action":"prepare","kind":"wireguard"}' | ucode -L "$FORKOP_LIB" "$FORKOP_LIB/warp/service.uc" rpc start >"$WORK/job.json"
  id="$(node -e 'console.log(require(process.argv[1]).job_id)' "$WORK/job.json")"
  for _attempt in $(seq 1 100); do
    printf '{"id":"%s"}\n' "$id" | ucode -L "$FORKOP_LIB" "$FORKOP_LIB/warp/service.uc" rpc job >"$WORK/result.json"
    if ! grep -q '"pending": true' "$WORK/result.json"; then break; fi
    sleep 0.1
  done
  printf '{"id":"%s"}\n' "$id" | ucode -L "$FORKOP_LIB" "$FORKOP_LIB/warp/service.uc" rpc ack >/dev/null
}
for pm in apk opkg; do
  if [ "$pm" = opkg ]; then mv "$WORK/bin/apk" "$WORK/bin/opkg"; fi
  rm "$WORK/proto/wireguard.sh"
  touch "$WORK/package_fail"
  prepare_job
  node -e 'if(require(process.argv[1]).success) process.exit(1)' "$WORK/result.json"
  test ! -e "$WORK/proto/wireguard.sh"
  rm "$WORK/package_fail"
  prepare_job
  node -e 'if(!require(process.argv[1]).success) process.exit(1)' "$WORK/result.json"
  test -s "$WORK/proto/wireguard.sh"
done
if grep -Eq -- '--force|--allow-untrusted|network restart' "$WORK/commands"; then exit 1; fi
printf 'WARP APK and OPKG dependency preflight checks passed\n'
