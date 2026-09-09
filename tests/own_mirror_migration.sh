#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

node > "$WORK_DIR/fixture.json" <<'NODE'
const fixture = {
  settings: {
    '.name': 'settings', '.type': 'settings', config_version: '1.0.10',
    mirror_base_url: 'https://mirror.51343.ru/',
    applied_migrations: ['interface_sections', 'enable_component_checks',
      'http_connection_urls', 'flintnet_urltest_default', 'retired_secondary_rulesets',
      'retired_secondary_rulesets_v2', 'secondary_rulesets_mirror_v1'],
  },
  section: [{'.name': 'main', '.type': 'section',
    rule_set_with_subnets: ['https://mirror.51343.ru/forkop/lists/b4geoip-forkop/srs/valve.srs',
      'https://custom.example/rules.srs', '/etc/forkop/local.srs'],
    remote_domain_lists: ['https://mirror.51343.ru/forkop/lists/allow-domains/Russia/inside-raw.lst'],
    remote_subnet_lists: ['https://custom.example/subnets.txt'],
  }],
  subscription_url: [{'.name': 'provider', '.type': 'subscription_url', section: 'main',
    url: 'https://arbitrary-provider.example/private-subscription', user_agent: 'custom-agent'}],
};
console.log(JSON.stringify(fixture));
NODE

FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$FORKOP_LIB/config/migration.uc" \
  migrate-fixture "$WORK_DIR/fixture.json" > "$WORK_DIR/result.json"

node - "$WORK_DIR/fixture.json" "$WORK_DIR/result.json" "$WORK_DIR/again.json" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const before = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const out = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
assert.equal(out.config.settings.mirror_base_url, 'https://mirror.infotechtg.ru');
assert.deepEqual(out.config.subscription_url, before.subscription_url);
assert.deepEqual(out.config.section[0].rule_set_with_subnets,
  ['https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs/valve.srs',
    'https://custom.example/rules.srs', '/etc/forkop/local.srs']);
assert.deepEqual(out.config.section[0].remote_domain_lists,
  ['https://mirror.infotechtg.ru/forkop/lists/allow-domains/Russia/inside-raw.lst']);
assert.deepEqual(out.config.section[0].remote_subnet_lists, before.section[0].remote_subnet_lists);
assert(out.config.settings.applied_migrations.includes('own_dependency_mirror_v1'));
fs.writeFileSync(process.argv[4], JSON.stringify(out.config));
NODE

FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$FORKOP_LIB/config/migration.uc" \
  migrate-fixture "$WORK_DIR/again.json" > "$WORK_DIR/again-result.json"
node - "$WORK_DIR/again.json" "$WORK_DIR/again-result.json" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[3], 'utf8')).config,
  JSON.parse(fs.readFileSync(process.argv[2], 'utf8')));
NODE

sed 's#https://mirror.51343.ru/#https://custom-mirror.example/#g' \
  "$WORK_DIR/fixture.json" > "$WORK_DIR/custom.json"
FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$FORKOP_LIB/config/migration.uc" \
  migrate-fixture "$WORK_DIR/custom.json" > "$WORK_DIR/custom-result.json"
node - "$WORK_DIR/custom-result.json" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).config;
assert.equal(out.settings.mirror_base_url, 'https://custom-mirror.example/');
assert(out.section[0].rule_set_with_subnets[0].startsWith('https://custom-mirror.example/'));
NODE
printf 'Own mirror migration and unrestricted subscription preservation passed\n'
