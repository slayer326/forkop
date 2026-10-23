#!/usr/bin/env bash
set -euo pipefail

ACTION_UC="$(dirname "$0")/../forkop/files/usr/lib/components/action.uc"
ACTION_UC="$ACTION_UC" node - <<'NODE'
const fs = require('fs');
const source = fs.readFileSync(process.env.ACTION_UC, 'utf8');
const start = source.indexOf('function install_forkop(requested_version)');
const end = source.indexOf('\nfunction ', start + 1);
if (start < 0) throw new Error('install_forkop function missing');
const body = source.slice(start, end < 0 ? undefined : end);
const positions = [
  'previous_forkop_release(FORKOP_VERSION)',
  'pkg_list_update_command()',
  'install_forkop_package_set(',
].map(text => body.indexOf(text));
if (positions.some(position => position < 0) ||
    positions.some((position, i) => i > 0 && position <= positions[i - 1])) {
  throw new Error('Package index refresh must precede service stop and package replacement');
}
if (!body.includes('action_fail("forkop", "install", "Failed to update package lists"')) {
  throw new Error('Package index refresh failure must abort the upgrade');
}
const packageStart = source.indexOf('function install_forkop_package_set(');
const packageEnd = source.indexOf('\nfunction ', packageStart + 1);
if (packageStart < 0) throw new Error('Package-set installer missing');
const packageBody = source.slice(packageStart, packageEnd < 0 ? undefined : packageEnd);
const packagePositions = [
  'Checking new Forkop package set',
  'Checking previous Forkop package set',
  'forkop_package_set_space_error(',
  'capture_managed_upgrade_sing_box_marker()',
  'stop_old_sing_box_before_forkop_upgrade()',
  '"/pending.new"',
  'Installing Forkop release packages',
].map(text => packageBody.indexOf(text));
if (packagePositions.some(position => position < 0) ||
    packagePositions.some((position, i) => i > 0 && position <= packagePositions[i - 1])) {
  throw new Error('Package-set solver and storage checks must precede service stop and package mutation');
}
if (!source.includes('restart_forkop_after_failed_release_upgrade();') ||
    !packageBody.includes('forkop_stopped_for_release_upgrade = true;')) {
  throw new Error('A failed release change after service stop must attempt safe restoration');
}
console.log('Forkop upgrade preflight order passed');
NODE
