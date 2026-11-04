#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
MAIN_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js"

node - "$SECTION_JS" "$MAIN_JS" <<'NODE'
const fs = require("fs");
const path = require("path");
const section = fs.readFileSync(process.argv[2], "utf8");
const main = fs.readFileSync(process.argv[3], "utf8");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

for (const option of ["russia_inside", "russia_outside", "ukraine_inside"]) {
  if (!main.includes(`${option}:`)) {
    fail(`${option} must remain available as a built-in rule set`);
  }
}

const currentSecondaryOptions = [
  "adobe", "anthropic", "apple", "blizzard", "bungie", "ccp",
  "electronicarts", "epicgames", "google", "nintendo", "riot",
  "roblox", "sony", "taketwo", "twitch", "ubisoft", "valve", "wargaming",
  "xbox",
];

// These entries are supported by the current upstream Forkop catalogue.
for (const option of currentSecondaryOptions) {
  if (!main.includes(`${option}:`)) {
    fail(`${option} must be available in built-in rule sets #2`);
  }
}

const secondaryOptions = main.match(/var SECONDARY_RULESET_OPTIONS\s*=\s*\{([^}]*)\};/);
if (!secondaryOptions) {
  fail('secondary built-in rule set options are missing');
}
for (const removed of [
  "aeza", "akamai", "amazon", "belcloud", "buyvm", "cdn77", "cloudflare",
  "cogent", "constant", "contabo", "datacamp", "digitalocean", "digitalone",
  "fastly", "gcore", "glesys", "gthost", "hetzner", "meganz", "melbicom",
  "oracle", "ovh", "play2go", "scalaxy", "scaleway", "vercel", "zerocdn",
]) {
  if (secondaryOptions[1].includes(`${removed}:`)) {
    fail(`${removed} was retired upstream and must not be offered as a secondary rule set`);
  }
}

const actualSecondaryOptions = [...secondaryOptions[1].matchAll(/(?:^|,)\s*([a-z0-9]+)\s*:/g)]
  .map((match) => match[1])
  .sort();
if (JSON.stringify(actualSecondaryOptions) !== JSON.stringify([...currentSecondaryOptions].sort())) {
  fail('secondary built-in rule sets must match the supported upstream catalogue exactly');
}

for (const required of [
  '`${_("Built-in rule sets")} #2`',
  "mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs/",
  "Greeg0ry/b4geoip-forkop/main/srs/",
  "SECONDARY_RULESET_OPTIONS",
]) {
  if (!section.includes(required)) {
    fail(`secondary built-in rule set integration is missing: ${required}`);
  }
}

for (const removed of [
  "REGIONAL_OPTIONS",
  "builtInRulesetOption.onchange",
  "Regional options cannot be used together",
  "Previous selections have been removed",
]) {
  if (section.includes(removed) || main.includes(removed)) {
    fail(`built-in rule set restriction remains: ${removed}`);
  }
}

// Roblox is offered once, as a secondary rule set: the community list holds
// only two subnets and duplicated the picker entry. The backend keeps
// accepting community_lists 'roblox' for existing configurations.
const repoRoot = path.resolve(path.dirname(process.argv[2]), "../../../../../../");
const constantsSource = fs.readFileSync(
  path.join(repoRoot, "fe-app-forkop/src/constants.ts"),
  "utf8",
);
const domainOptionsSource = constantsSource.match(/DOMAIN_LIST_OPTIONS\s*=\s*\{([^}]*)\}/);
if (!domainOptionsSource) {
  fail('domain list options are missing');
}
if (domainOptionsSource[1].includes("roblox:")) {
  fail('roblox must not duplicate the secondary rule set in the community list picker');
}
const rulesetsSource = fs.readFileSync(
  path.join(repoRoot, "forkop/files/usr/lib/singbox/rulesets.uc"),
  "utf8",
);
if (!rulesetsSource.includes("roblox: true")) {
  fail('backend community list roblox support must remain for existing configurations');
}

// Retired picker values must survive a save: the built-in list widget no
// longer filters community_lists by the picker map.
if (!/return uniqueDynamicListItems\(\s*getConfigListValues\(section_id, "community_lists"\),?\s*\);/.test(section)) {
  fail('built-in ruleset widget must preserve values retired from the picker');
}

// Curated per-game rule sets are offered in the "Built-in rule sets #2"
// picker. Their ids map to source-format JSON on the game-rulesets branch,
// built from YOZH3G/ru-gaming-blocklist by CI.
const gameOptionsSource = constantsSource.match(/SECONDARY_GAME_RULESET_OPTIONS\s*=\s*\{([\s\S]*?)\n\};/);
if (!gameOptionsSource) {
  fail('secondary game rule set options are missing');
}
const gameIds = [...gameOptionsSource[1].matchAll(/^\s{2}([a-z0-9_]+):/gm)]
  .map((match) => match[1]);
if (gameIds.length < 20) {
  fail(`expected at least 20 curated game rule sets, found ${gameIds.length}`);
}
const builtInGames = /^(battlenet|ea_origin|epicgames_fortnite|riotgames_valorant|leagueoflegends|roblox|steam|ubisoft_rainbow_six_siege|cloudflare_aws)$/;
for (const id of gameIds) {
  if (builtInGames.test(id)) {
    fail(`game rule set duplicates a built-in rule set or is auxiliary: ${id}`);
  }
}
if (constantsSource.includes("REMOTE_GAME_LIST_OPTIONS")) {
  fail('game lists must live in the built-in rule sets #2 picker, not in the domain/IP list suggestions');
}
if (!main.includes("SECONDARY_GAME_RULESET_OPTIONS")) {
  fail('bundled main.js lost the secondary game rule set options');
}
if (!section.includes("main.SECONDARY_GAME_RULESET_OPTIONS")) {
  fail('the built-in rule sets #2 widget is not wired to the game rule sets');
}
if (!section.includes("https://cdn.jsdelivr.net/gh/slayer326/forkop@game-rulesets/games/")) {
  fail('game rule sets must be served from the game-rulesets branch via jsDelivr');
}
if (!section.includes('`${SECONDARY_GAME_RULESET_CDN_PREFIX}${value}.json`')) {
  fail('secondaryRulesetUrl must map game rule set ids to source-format JSON URLs');
}
NODE

printf 'Built-in rule set UI checks passed\n'
