#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_UC="$ROOT_DIR/forkop/files/usr/lib/components/action.uc"
UPDATES_TS="$ROOT_DIR/fe-app-forkop/src/forkop/tabs/updates/initController.ts"
DIAGNOSTICS_TS="$ROOT_DIR/fe-app-forkop/src/forkop/tabs/diagnostic/initController.ts"
CONSTANTS_UC="$ROOT_DIR/forkop/files/usr/lib/core/constants.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

grep -Fq '/forkop/sing-box-extended/latest.json' "$ACTION_UC" ||
  fail "sing-box Extended metadata must come from the Forkop mirror"
source_refute_text "sing-box Extended resolver must not fall back to GitHub" \
  -F 'fetch_github' "$(source_function "$ACTION_UC" resolve_sing_box_extended_release)"

grep -Fq '"https://fold8.ru/forkop"' "$CONSTANTS_UC" ||
  fail "Forkop releases must default to the public fold8.ru release channel"
grep -Fq 'forkop_release_sources()' "$ACTION_UC" ||
  fail "Forkop updates must use Timeweb and the home mirror"
source_refute_text "Forkop release lookup must not use GitHub" \
  -F 'fetch_github' "$(source_function "$ACTION_UC" latest_forkop_release_json)"
grep -Fq 'asset_url: forkop_mirror_url(asset_url)' "$ACTION_UC" ||
  fail "sing-box Extended relative assets must stay on the dependency mirror"

grep -Fq "text: _('Install Tiny build')" "$UPDATES_TS" || fail "Tiny switch is missing"
grep -Fq "text: _('Install Extended build')" "$UPDATES_TS" || fail "Extended switch is missing"
if grep -Fq "text: 'Stable'" "$UPDATES_TS"; then
  fail "Stable sing-box must not be offered in LuCI"
fi
if grep -Fq "text: 'Extended compressed'" "$UPDATES_TS"; then
  fail "Extended compressed must not be offered in LuCI"
fi

grep -Fq "title: 'Zapret-Manager-Stressozz'" "$UPDATES_TS" ||
  fail "Zapret-Manager-Stressozz branding is missing"
grep -Fq 'zapret_manager_installed' "$UPDATES_TS" ||
  fail "Zapret-Manager installed-state check is missing"
grep -Fq "key: 'zapretManagerRemove'" "$UPDATES_TS" ||
  fail "Zapret-Manager remove button is missing"
grep -Fq 'function remove_zapret_manager(action)' "$ACTION_UC" ||
  fail "Zapret-Manager safe removal action is missing"
grep -Fq 'function set_packet_steering(action)' "$ACTION_UC" ||
  fail "Packet Steering action is missing"
grep -Fq 'network.@globals[0].packet_steering' "$ACTION_UC" ||
  fail "Packet Steering must target the first network globals section"
grep -Fq "component: 'packet_steering'" "$UPDATES_TS" ||
  fail "Packet Steering card is missing"
grep -Fq "key: 'packetSteeringEnable'" "$UPDATES_TS" ||
  fail "Packet Steering enable button is missing"
grep -Fq "key: 'packetSteeringRestore'" "$UPDATES_TS" ||
  fail "Packet Steering restore button is missing"
grep -Fq 'clear_version_caches();' "$ACTION_UC" ||
  fail "component installation must invalidate system-info caches"
if grep -Fq 'github_probe(proxy_address)' "$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"; then
  fail "list updates must not wait for an unrelated GitHub availability probe"
fi
grep -Fq 'grid-template-columns: repeat(3, minmax(0, 1fr))' \
  "$ROOT_DIR/fe-app-forkop/src/forkop/tabs/updates/styles.ts" ||
  fail "component columns must have equal fixed widths"
grep -Fq "key: 'Forkop X'" "$DIAGNOSTICS_TS" ||
  fail "Forkop X diagnostics branding is missing"

printf 'Forkop X component checks passed\n'
