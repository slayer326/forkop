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
if (!section.includes('return uniqueDynamicListItems(getConfigListValues(section_id, "community_lists"));')) {
  fail('built-in ruleset widget must preserve values retired from the picker');
}

// Curated per-game lists are offered as suggestions of the "Domain and IP
// lists" field and stored as plain remote URLs.
const gameListsSource = constantsSource.match(/REMOTE_GAME_LIST_OPTIONS\s*=\s*\{([\s\S]*?)\n\};/);
if (!gameListsSource) {
  fail('remote game list options are missing');
}
const gameEntries = [...gameListsSource[1].matchAll(/\$\{RU_GAMING_BLOCKLIST\}\/([A-Za-z0-9_]+\.txt)/g)];
if (gameEntries.length < 20) {
  fail(`expected at least 20 curated game lists, found ${gameEntries.length}`);
}
const builtInGames = /^(BattleNet|EA_Origin|EpicGames_Fortnite|RiotGames_Valorant|LeagueOfLegends|Roblox|Steam|Ubisoft_Rainbow_Six_Siege|Cloudflare_AWS)\.txt$/;
for (const [, file] of gameEntries) {
  if (builtInGames.test(file)) {
    fail(`game list duplicates a built-in rule set or is auxiliary: ${file}`);
  }
}
if (!constantsSource.includes("https://raw.githubusercontent.com/YOZH3G/ru-gaming-blocklist/main/games")) {
  fail('game lists must point at YOZH3G/ru-gaming-blocklist');
}
if (!main.includes("REMOTE_GAME_LIST_OPTIONS")) {
  fail('bundled main.js lost the remote game list options');
}
if (!section.includes("main.REMOTE_GAME_LIST_OPTIONS")) {
  fail('the "Domain and IP lists" widget is not wired to the game list suggestions');
}
NODE

printf 'Built-in rule set UI checks passed\n'
