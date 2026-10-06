#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/valid.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings",
    "dns_type": "doq",
    "dns_server": [ "dns.adguard-dns.com", "dns.example.com:8853" ],
    "bootstrap_dns_server": [ "1.1.1.1" ],
    "yacd_secret_key": "test-clash-secret"
  },
  "section": [
    {
      ".name": "custom_dns", ".type": "section", "enabled": "1",
      "action": "dns", "dns_type": "doq", "dns_server": "9.9.9.9:8853",
      "domain_suffix": [ "example.org" ]
    },
    {
      ".name": "vpn", ".type": "section", "enabled": "1",
      "action": "connection", "domain_suffix": [ "vpn.example" ]
    }
  ],
  "section_interface": [
    {
      ".name": "vpn-interface", ".type": "section_interface",
      "section": "vpn", "name": "tun0", "domain_resolver_enabled": "1",
      "domain_resolver_dns_type": "doq",
      "domain_resolver_dns_server": "dns.example.net"
    }
  ]
}
JSON
printf '{}\n' >"$WORK_DIR/context.json"

FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" \
  "$FORKOP_LIB/config/validator.uc" validate-runtime-fixture \
  "$WORK_DIR/valid.json" "$WORK_DIR/context.json" >"$WORK_DIR/validated.json"

for version in 1.12.25 1.13.18 1.14.0; do
  output="$WORK_DIR/config-$version.json"
  mkdir -p "$output.section-cache" "$output.rulesets"
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" \
    generate-config-fixture "$WORK_DIR/valid.json" "$output" \
    127.0.0.1 0 '' '' "$version"
  ucode -e '
    let config = json(require("fs").readfile(ARGV[0]));
    function server(tag) {
      for (let item in config.dns.servers) if (item.tag == tag) return item;
      return null;
    }
    function check(item, host, port) {
      if (item == null || item.type != "quic" || item.server != host ||
          item.server_port != port || item.tls.enabled !== true)
        die("invalid DoQ server: " + host + "\n");
    }
    check(server("dns-server"), "dns.adguard-dns.com", 853);
    if (server("dns-server").domain_resolver != "bootstrap-dns-server")
      die("DoQ hostname must use Bootstrap DNS\n");
    check(server("dns-health-main-2-server"), "dns.example.com", 8853);
    check(server("custom_dns-dns-server"), "9.9.9.9", 8853);
    check(server("vpn-interface-1-domain-resolver"), "dns.example.net", 853);
  ' "$output"
  if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c "$output"
  fi
done

cat >"$WORK_DIR/bad-main.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings", "yacd_secret_key": "test-clash-secret",
    "dns_type": "doq", "dns_server": [ "dns.example.com/dns-query" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "section": []
}
JSON
if FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" \
  "$FORKOP_LIB/config/validator.uc" validate-runtime-fixture \
  "$WORK_DIR/bad-main.json" "$WORK_DIR/context.json" >"$WORK_DIR/bad-main.out" 2>&1; then
  echo 'DoQ must reject a DoH path' >&2
  exit 1
fi
grep -Fq 'without a path or query' "$WORK_DIR/bad-main.out"

ucode -L "$FORKOP_LIB" -e '
  let dns = require("singbox.dns");
  if (dns.server_from_options("test", "doq", "dns.example.com/dns-query", "").unsupported == null)
    die("generator accepted a DoH path for DoQ\n");
  if (dns.server_from_options("test", "doq", "quic://dns.example.com", "").unsupported == null)
    die("generator accepted a scheme for DoQ\n");
'

printf 'DNS over QUIC checks passed\n'
