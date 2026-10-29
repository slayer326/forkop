#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACL="$ROOT_DIR/luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json"
DIAGNOSTICS="$ROOT_DIR/forkop/files/usr/lib/diagnostics/runtime.uc"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

node - "$ACL" <<'NODE'
const fs = require('node:fs');
const groups = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const acl = groups['luci-app-forkop'];
const grants = acl.read.file;
const RO = '/usr/libexec/forkop-ro';
function allowed(command) {
  return Object.entries(grants).some(([pattern, permissions]) => {
    const matcher = new RegExp('^' + pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\\\*/g, '.*') + '$');
    return permissions.includes('exec') && matcher.test(command);
  });
}
const mutations = [
  '/usr/bin/forkop', '/usr/bin/forkop stop', '/usr/bin/forkop full_uninstall',
  '/usr/bin/forkop show_sing_box_config raw', '/etc/init.d/forkop stop',
  '/usr/bin/forkop clash_api set_group_proxy group direct',
  '/usr/bin/forkop config_snapshot_create manual',
  '/usr/bin/forkop config_snapshot_restore 1',
  '/usr/bin/forkop config_snapshot_delete 1',
  '/usr/bin/forkop validate_nfqws_strategy_json test',
  '/usr/bin/forkop autotune_policy_set mode auto',
  '/usr/bin/forkop autotune_target_set yt youtube.com',
  '/usr/bin/forkop autotune_target_remove yt',
  '/usr/bin/forkop autotune_apply youtube',
  '/usr/bin/forkop autotune_apply_async youtube',
  '/usr/bin/forkop autotune_rollback',
  '/usr/bin/forkop autotune_run_async all',
  '/usr/bin/forkop autotune_run all',
  '/usr/bin/forkop autotune_if_due',
];
// UC-001: rpcd passes the caller's env table to the child, so the read role
// may only reach the CLI through the wrapper that starts it with env -i.
for (const command of [
  ...mutations,
  ...mutations.map(command => command.replace(/^\/usr\/bin\/forkop(?= |$)/, RO)),
  RO,
  '/usr/bin/forkop get_status', '/usr/bin/forkop get_system_info',
  '/usr/bin/forkop get_ui_capabilities', '/usr/bin/forkop global_check masked',
  '/usr/bin/forkop show_sing_box_config masked',
]) {
  if (allowed(command)) throw Error(`read role may execute ${command}`);
}
// UC-034: no read-only page runs these. check_proxy starts extra sing-box
// instances and fetches through the outbounds, the latency commands probe
// arbitrary URLs and rewrite the admin's progress file, and check_nft dumps
// the unmasked nft table.
for (const command of [
  'check_proxy', 'check_nft', 'check_sing_box_logs', 'show_sing_box_version',
  'get_outbound_metadata main', 'autotune_target youtube',
  'clash_api get_proxy_latency main 5000 http://192.168.1.1/',
  'clash_api get_proxy_latencies ["main"] 5000 /tmp/run/forkop/ui-state/latency-actions/x.json',
  'clash_api get_group_latency main 10000',
]) {
  if (allowed(RO + ' ' + command)) throw Error(`read role may execute ${command}`);
}
for (const command of [
  RO + ' get_status', RO + ' get_ui_state',
  RO + ' get_readonly_config_sections',
  RO + ' get_health_status',
  RO + ' get_history',
  RO + ' get_ui_capabilities',
  RO + ' show_version',
  RO + ' check_nft_rules',
  RO + ' check_logs',
  RO + ' clash_api get_proxies',
  RO + ' clash_api get_connections',
  RO + ' route_trace example.org 192.168.1.1 TCP 443',
  RO + ' config_snapshot_list',
  RO + ' config_snapshot_diff 123',
  RO + ' connectivity_test example.org TCP 443',
]) {
  if (!allowed(command)) throw Error(`read diagnostic missing: ${command}`);
}
// Upstream 1.0.24 grants the whole CLI to the read group; this branch must not.
if ('/usr/bin/forkop' in grants || RO in grants) throw Error('wildcard CLI exec granted to read role');
for (const pattern of Object.keys(grants)) {
  if (/config_snapshot_(create|restore|delete)/.test(pattern)) {
    throw Error(`snapshot mutation granted to read role: ${pattern}`);
  }
}
// rpcd needs the ubus file.exec method before it evaluates the file-scope
// command patterns above; without it no read command can run at all.
if (!acl.read.ubus?.file?.includes('exec')) throw Error('read role cannot reach file.exec');
if (acl.read.ubus.file.length !== 1) {
  throw Error('read role got extra ubus file methods');
}
// UC-034: no Forkop page lists procd services; the list carries every
// service's command line and environment.
if ('service' in acl.read.ubus) throw Error('read role may list procd services');
for (const pattern of Object.keys(grants)) {
  if (!pattern.startsWith(RO + ' ') && !pattern.includes('/run/forkop/')) {
    throw Error(`unexpected read file grant: ${pattern}`);
  }
  // rpcd serves file.read itself, so these paths do not depend on the env.
  if (!pattern.startsWith(RO + ' ') && grants[pattern].join() !== 'read') {
    throw Error(`read role may do more than read ${pattern}`);
  }
}
if (acl.read.uci?.includes('forkop')) throw Error('raw UCI exposed to read role');
if (!groups['luci-app-forkop-admin']?.read?.uci?.includes('forkop')) {
  throw Error('admin role lost UCI read access');
}
for (const path of ['/etc/sing-box/config.json', '/tmp/sing-box/config.json']) {
  if (grants[path]?.includes('read')) throw Error(`raw JSON exposed: ${path}`);
}
for (const path of ['/var/run/forkop/section-cache/*', '/tmp/run/forkop/section-cache/*']) {
  if (grants[path]?.includes('read')) throw Error(`raw subscription cache exposed: ${path}`);
}
if (!acl.write.file['/usr/bin/forkop']?.includes('exec')) throw Error('write role lost control CLI');
NODE

cat >"$WORK_DIR/forkop" <<'EOF'
config settings 'settings'
config section 'main'
EOF
cat >"$WORK_DIR/state" <<'EOF'
forkop.settings=settings
forkop.settings.config_path=CONFIG_PATH
forkop.main=section
forkop.main.action=proxy
forkop.main.label=Main
forkop.main.password=do-not-expose
forkop.main.subscription_urls=https://example.test/?token=secret
EOF
sed -i "s|CONFIG_PATH|$WORK_DIR/sing-box.json|" "$WORK_DIR/state"
cat >"$WORK_DIR/sing-box.json" <<'EOF'
{"outbounds":[{"type":"urltest","tag":"group","outbounds":["node-a"],"url":"https://example.test/?token=secret","interval":"1m"},{"type":"vless","tag":"node-a","uuid":"do-not-expose"}]}
EOF

FORKOP_CONFIG="$WORK_DIR/forkop" FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  ucode -L "$FORKOP_LIB" "$DIAGNOSTICS" get-readonly-config-sections >"$WORK_DIR/sections.json"
FORKOP_CONFIG="$WORK_DIR/forkop" FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  ucode -L "$FORKOP_LIB" "$DIAGNOSTICS" get-dashboard-runtime-metadata >"$WORK_DIR/runtime.json"
node - "$WORK_DIR/sections.json" "$WORK_DIR/runtime.json" <<'NODE'
const fs = require('node:fs');
const sections = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const runtime = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const output = JSON.stringify({sections, runtime});
if (!sections.some(section => section['.name'] === 'main' && section.action === 'proxy')) {
  throw Error('read-only dashboard lost section metadata');
}
if (runtime.urltestGroups.group.outbounds[0] !== 'node-a') {
  throw Error('read-only dashboard lost runtime group metadata');
}
if (/secret|do-not-expose/.test(output)) throw Error('read-only metadata leaked raw secrets');
NODE

printf 'ACL read boundary checks passed\n'
