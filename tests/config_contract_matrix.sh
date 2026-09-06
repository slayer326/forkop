#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STABLE_REF="${FORKOP_STABLE_REF:-0.7.19.9}"
STABLE_VERSION="${FORKOP_STABLE_VERSION:-0.7.19.9}"
STABLE_COMMIT="${FORKOP_STABLE_COMMIT:-68d516e85b9a81b5a37e8e258610098ed03b02d1}"
STABLE_REPO="${FORKOP_STABLE_REPO:-}"
MATRIX_SCRIPT="$ROOT_DIR/tests/helpers/config_contract_matrix.js"
WORK_DIR="$(mktemp -d)"
LEGACY_STEM="$(printf '\160\157\144\153\157\160')"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

ensure_stable_ref() {
  if git -C "$ROOT_DIR" rev-parse --verify "$STABLE_REF^{commit}" >/dev/null 2>&1; then
    return 0
  fi

  if git -C "$ROOT_DIR" fetch --force --depth=1 origin "refs/tags/$STABLE_REF:refs/tags/$STABLE_REF" >/dev/null 2>&1; then
    return 0
  fi

  if git -C "$ROOT_DIR" rev-parse --verify "$STABLE_COMMIT^{commit}" >/dev/null 2>&1; then
    STABLE_REF="$STABLE_COMMIT"
    return 0
  fi

  fail "stable baseline is unavailable: tag $STABLE_REF or commit $STABLE_COMMIT"
}

prepare_stable_repo() {
  if [ -n "$STABLE_REPO" ]; then
    if [ ! -r "$STABLE_REPO/forkop/files/etc/config/forkop" ] &&
      [ ! -r "$STABLE_REPO/$LEGACY_STEM/files/etc/config/$LEGACY_STEM" ]; then
      fail "stable repo is missing the expected config template: $STABLE_REPO"
    fi
    return 0
  fi

  ensure_stable_ref
  STABLE_REPO="$WORK_DIR/stable-$STABLE_VERSION"
  mkdir -p "$STABLE_REPO"
  git -C "$ROOT_DIR" archive "$STABLE_REF" | tar -x -C "$STABLE_REPO" ||
    fail "failed to materialize stable baseline: $STABLE_REF"
}

prepare_stable_repo

node "$MATRIX_SCRIPT" --current "$ROOT_DIR" --stable "$STABLE_REPO" >"$WORK_DIR/matrix.json"

node - "$WORK_DIR/matrix.json" <<'NODE'
const fs = require("fs");
const matrix = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function fail(message) {
  console.error(message);
  process.exit(1);
}

const retiredMissingCurrent = new Set([
  "urltest_hide_filtered_outbounds",
  "_protocol_display",
  // Upstream 1.3.7 removes the previously disabled UCI server feature.
  // Keep this explicit: missing client/routing options must still fail below.
  "client_fingerprint", "hysteria2_down_mbps", "hysteria2_obfs_password",
  "hysteria2_obfs_type", "hysteria2_up_mbps", "listen", "listen_port",
  "mtproto_allow_fallback_on_unknown_dc", "mtproto_auto_update", "mtproto_concurrency",
  "mtproto_domain_fronting_ip", "mtproto_domain_fronting_port", "mtproto_domain_fronting_proxy_protocol",
  "mtproto_faketls", "mtproto_handshake_timeout", "mtproto_idle_timeout", "mtproto_padding",
  "mtproto_prefer_ip", "mtproto_secret", "mtproto_tolerate_time_skewness",
  "protocol", "public_host", "reality_handshake_server", "reality_handshake_server_port",
  "reality_max_time_difference", "reality_private_key", "reality_public_key", "reality_short_id",
  "routing_mode", "routing_section", "security", "server_password", "server_username",
  "server_users", "server_uuid", "shadowsocks_method", "tailscale_accept_routes",
  "tailscale_advertise_exit_node", "tailscale_advertise_routes", "tailscale_auth_key",
  "tailscale_control_url", "tailscale_hostname", "tls_alpn", "tls_certificate_path",
  "tls_key_path", "tls_server_name", "transport", "transport_host", "transport_hosts",
  "transport_path", "transport_service_name", "transport_xhttp_mode", "vless_flow", "vmess_alter_id",
]);
const missing = matrix.fields.filter((field) => field.status === "missing_current" && !retiredMissingCurrent.has(field.name));
if (missing.length) {
  fail(`stable config fields missing in current contract: ${missing.map((field) => field.name).join(", ")}`);
}

for (const name of ["dns_type", "subscription_urls", "selector_proxy_links", "action", "user_domains", "user_domains_text", "user_domain_list_type", "local_domain_lists", "remote_domain_lists", "remote_subnet_lists", "domain_ip_lists", "fully_routed_ips"]) {
  const field = matrix.fields.find((item) => item.name === name);
  if (!field) fail(`expected config field is absent from matrix: ${name}`);
  if (field.status !== "supported" && field.status !== "migrated") {
    fail(`expected config field ${name} to be supported or migrated, got ${field.status}`);
  }
}

const explicitlyRetired = matrix.fields.filter((field) => field.status === "missing_current" && retiredMissingCurrent.has(field.name)).length;
if ((matrix.summary.supported || 0) + explicitlyRetired < 140) {
  fail(`unexpectedly small supported config surface: ${matrix.summary.supported || 0}`);
}

if (matrix.stable.version !== "0.7.19.9") {
  fail(`unexpected stable baseline: ${matrix.stable.version}`);
}

function uiValues(field) {
  const result = new Set();
  for (const entry of field?.ui || []) {
    for (const value of entry.values || []) {
      result.add(value);
    }
  }
  return [...result].sort();
}

function assertCurrentKeepsStableValues(name, required = [], retired = []) {
  const field = matrix.fields.find((item) => item.name === name);
  if (!field) fail(`expected enum field is absent from matrix: ${name}`);

  const stableValues = uiValues(field.stable);
  const currentValues = uiValues(field.current);
  const missingStable = stableValues.filter((value) => !currentValues.includes(value) && !retired.includes(value));
  if (missingStable.length) {
    fail(`current UI contract for ${name} is missing stable values: ${missingStable.join(", ")}`);
  }

  const missingRequired = required.filter((value) => !currentValues.includes(value));
  if (missingRequired.length) {
    fail(`current UI contract for ${name} is missing required values: ${missingRequired.join(", ")}`);
  }
}

assertCurrentKeepsStableValues("action", ["connection", "bypass", "block", "zapret", "zapret2", "byedpi", "dns"], ["direct", "proxy", "vpn", "outbound"]);
assertCurrentKeepsStableValues("urltest_filter_mode", ["disabled", "exclude", "include", "mixed"]);
assertCurrentKeepsStableValues("dns_type", ["doh", "dot", "udp"]);
NODE

printf 'config contract matrix checks passed\n'
