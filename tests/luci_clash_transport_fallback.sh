#!/usr/bin/env bash
set -euo pipefail

# The sing-box controller websocket (ws://host:9090) is unreachable from an
# HTTPS LuCI page and can drop at any time. Dashboard widgets and Monitoring
# must then keep working through rpcd (`clash_api get_connections`) instead
# of showing "unavailable" until the page is reloaded.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

function functionBody(source, signature) {
  const start = source.indexOf(signature);
  assert(start >= 0, `${signature} not found`);
  const open = source.indexOf('{', start + signature.length - 1);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(open, i + 1);
  }
  throw Error(`${signature} is not closed`);
}

const dashboard = read('fe-app-forkop/src/forkop/tabs/dashboard/initController.ts');
const start = functionBody(dashboard, 'function startDashboardDataUpdates()');
assert.match(start, /void connectToClashSockets\(dataUpdatesId\);/,
  'dashboard must start the Clash updates');
const sockets = functionBody(dashboard, 'async function connectToClashSockets(dataUpdatesId: number)');
// UC-035, D-1: direct sockets need the Clash secret, which read-only
// sessions never receive; they poll through rpcd instead.
assert.match(sockets, /if \(!canUseDirectClashApi\(clashApiSecret\)\) \{\s*startClashRpcPolling\(dataUpdatesId\);\s*return;/,
  'dashboard must poll through rpcd when the controller socket is not reachable or there is no secret');
assert.doesNotMatch(sockets, /token=\$\{/, 'the secret must be URL-encoded by getClashWsStreamUrl');
assert.equal((sockets.match(/fallBackToClashRpcPolling\(dataUpdatesId\)/g) || []).length, 3,
  'both dashboard sockets and their watchdog must fall back to rpcd polling');
// A socket that neither opens nor fails (a remote LuCI behind Tailscale or a
// firewall dropping 9090) must not leave the widgets loading for minutes.
assert.match(sockets, /clashSocketWatchdog = setTimeout\([\s\S]*?\(!trafficReceived \|\| !connectionsReceived\)[\s\S]*?fallBackToClashRpcPolling\(dataUpdatesId\)[\s\S]*?CLASH_SOCKET_FIRST_MESSAGE_MS\)/,
  'the dashboard must poll when its sockets give no data in time');
assert.match(functionBody(dashboard, 'function stopDashboardDataUpdates()'), /clearClashSocketWatchdog\(\)/,
  'the socket watchdog must stop with the data updates');
assert.doesNotMatch(sockets, /failed: true/,
  'a socket error must not mark the widgets unavailable for good');
assert.match(functionBody(dashboard, 'function stopDashboardDataUpdates()'), /stopClashRpcPolling\(\)/,
  'dashboard polling must stop with the data updates');

// On Monitoring → Nodes the dashboard controller shares the page with the
// monitoring connections stream: it opens no Clash stream there and never
// closes sockets it did not open.
assert.match(start, /if \(overviewHost\) \{\s*clashUpdatesStarted = true;/,
  'the Clash traffic stream is only for the Overview page');
assert.match(functionBody(dashboard, 'function stopDashboardDataUpdates()'),
  /if \(clashUpdatesStarted\) socket\.resetAll\(\);/,
  'the dashboard must not close the monitoring socket');

const monitoring = read('fe-app-forkop/src/forkop/tabs/monitoring/initController.ts');
const monitoringSocket = functionBody(monitoring, 'async function connectToConnectionsSocket(updatesId: number)');
assert.match(monitoringSocket, /if \(!canUseDirectClashApi\(clashApiSecret\)\) \{\s*startConnectionsPolling\(\);\s*return;/,
  'monitoring must poll through rpcd when the controller socket is not reachable or there is no secret');
assert.doesNotMatch(monitoringSocket, /token=\$\{/, 'the secret must be URL-encoded by getClashWsStreamUrl');
assert.match(monitoringSocket, /socket\.disconnect\(connectionsSocketUrl\);[\s\S]*startConnectionsPolling\(\);/,
  'monitoring must fall back to rpcd polling when the socket fails');
assert.doesNotMatch(monitoringSocket, /failed = true/,
  'a socket error must not mark connections unavailable for good');

console.log('Clash controller socket failures fall back to rpcd polling');
NODE
