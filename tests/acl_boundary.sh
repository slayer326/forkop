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
function allowed(command) {
  return Object.entries(grants).some(([pattern, permissions]) => {
    const matcher = new RegExp('^' + pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\\\*/g, '.*') + '$');
    return permissions.includes('exec') && matcher.test(command);
  });
}
for (const command of [
  '/usr/bin/forkop', '/usr/bin/forkop stop', '/usr/bin/forkop full_uninstall',
  '/usr/bin/forkop show_sing_box_config raw', '/etc/init.d/forkop stop',
  '/usr/bin/forkop clash_api set_group_proxy group direct',
]) {
  if (allowed(command)) throw Error(`read role may execute ${command}`);
}
for (const command of [
  '/usr/bin/forkop get_status', '/usr/bin/forkop get_ui_state',
  '/usr/bin/forkop get_readonly_config_sections',
]) {
  if (!allowed(command)) throw Error(`read diagnostic missing: ${command}`);
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
