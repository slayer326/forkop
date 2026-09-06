#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name":"settings", ".type":"settings", "dns_server":"77.88.8.8",
    "direct_proxy_enabled":"1", "direct_proxy_port":"2080"
  },
  "section": [
    {
      ".name":"first", ".type":"section", "enabled":"1", "action":"bypass",
      "domain_suffix":["shared.example"],
      "source_ip_cidr":["192.0.2.0/24"], "fully_routed_ips":["192.0.2.0/24"],
      "excluded_source_ip_cidr":["192.0.2.10/32","2001:db8::10/128"]
    },
    {
      ".name":"second", ".type":"section", "enabled":"1", "action":"block",
      "domain_suffix":["shared.example"]
    },
    {
      ".name":"customdns", ".type":"section", "enabled":"1", "action":"dns",
      "dns_type":"udp", "dns_server":"1.1.1.1",
      "domain_suffix":["custom.example"], "community_lists":["youtube"],
      "fully_routed_ips":["192.0.2.0/24"],
      "excluded_source_ip_cidr":["192.0.2.10/32"]
    },
    {
      ".name":"resolve", ".type":"section", "enabled":"1", "action":"connection",
      "outbound_jsons":["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix":["resolve.example"], "resolve_real_ip_for_routing":"1",
      "excluded_source_ip_cidr":["192.0.2.10/32"]
    }
  ]
}
JSON

for version in 1.13.0 1.14.0; do
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 192.0.2.1 0 1 '' "$version"
  ucode -e '
    let c = json(require("fs").readfile(ARGV[0]));
    function check(value, message) { if (!value) die(message + "\n"); }
    function validate_condition(rule) {
      check(rule.action == null && rule.outbound == null && rule.server == null &&
        rule.rewrite_ttl == null, "actions must not leak into nested conditions");
      if (rule.type == "logical") {
        check(rule.query_type == null, "logical DNS rules cannot have a query_type matcher at the root");
        for (let child in rule.rules || []) validate_condition(child);
      }
    }
    function excluded(rule) {
      if (rule.invert && index(sprintf("%J", rule.source_ip_cidr), "192.0.2.10/32") >= 0) return true;
      for (let child in rule.rules || []) if (excluded(child)) return true;
      return false;
    }
    let inbound = null, outbound = null, direct_index = -1, section_index = -1;
    for (let item in c.inbounds) if (item.tag == "direct-proxy-in") inbound = item;
    for (let item in c.outbounds) if (item.tag == "direct-proxy-out") outbound = item;
    check(inbound != null && inbound.type == "mixed" && inbound.listen == "192.0.2.1" &&
      inbound.listen_port == 2080, "Direct Proxy must listen on the LAN endpoint");
    check(outbound != null && outbound.type == "direct" && outbound.routing_mark == 134217728,
      "Direct Proxy must use a marked direct outbound");
    let excluded_routes = 0, custom_dns = 0, resolve_rules = 0, following_section = 0;
    for (let i = 0; i < length(c.route.rules); i++) {
      let rule = c.route.rules[i];
      for (let child in rule.rules || []) validate_condition(child);
      if (rule.inbound == "direct-proxy-in") {
        direct_index = i;
        check(rule.outbound == "direct-proxy-out" && rule.domain_suffix == null &&
          rule.rule_set == null, "Direct Proxy must not depend on section matchers");
      }
      if (excluded(rule)) {
        excluded_routes++;
        if (section_index < 0) section_index = i;
        if (rule.action == "resolve") {
          resolve_rules++;
          check(rule.server != null, "resolve server must stay on the outer rule");
        }
      }
      if (rule.action == "reject" && index(sprintf("%J", rule), "shared.example") >= 0) {
        following_section++;
        check(!excluded(rule), "exclusions must not propagate to the next section");
      }
    }
    for (let rule in c.dns.rules) {
      for (let child in rule.rules || []) validate_condition(child);
      if (rule.type == "logical") check(rule.query_type == null, "query type belongs in a child matcher");
      if (rule.server == "customdns-dns-server") {
        custom_dns++;
        check(excluded(rule), "all custom DNS variants must exclude the selected device");
        check(rule.action == "route" && rule.rewrite_ttl != null, "DNS action must stay at the root");
      }
      if (rule.server == "dnsmasq-server" && index(sprintf("%J", rule), "192.0.2.0/24") >= 0)
        check(excluded(rule), "fully routed bypass DNS must also honor exclusions");
    }
    check(direct_index >= 0 && section_index > direct_index, "Direct Proxy must precede section rules");
    check(excluded_routes >= 3 && resolve_rules >= 1 && custom_dns == 3 && following_section >= 1,
      "expected route, resolve, DNS and following-section coverage");
  ' "$WORK_DIR/config.json"
done

ucode -e '
  let fs = require("fs"); let f = json(fs.readfile(ARGV[0]));
  f.settings.direct_proxy_enabled = "0";
  fs.writefile(ARGV[1], sprintf("%J", f));
' "$WORK_DIR/fixture.json" "$WORK_DIR/disabled.json"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/disabled.json" "$WORK_DIR/disabled-config.json" 192.0.2.1
if grep -q 'direct-proxy-in' "$WORK_DIR/disabled-config.json"; then
  echo 'FAIL: disabled Direct Proxy still creates a listener' >&2
  exit 1
fi

for group in 'services/torrserver' 'services/media/torrserver'; do
  level="$(awk -F/ '{print NF}' <<<"$group")"
  printf 'type route hook output priority -151; socket cgroupv2 level %s "%s" meta mark set 0x08000000 comment "Forkop TorrServer Direct"\n' "$level" "$group" |
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/torrserver/direct.uc" rule-output-active "/$group"
done
if printf '%s\n' 'type route hook output priority -151; socket cgroupv2 level 2 "services/media" meta mark set 0x08000000 comment "Forkop TorrServer Direct"' |
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/torrserver/direct.uc" rule-output-active '/services/media/torrserver'; then
  echo 'FAIL: TorrServer Direct must not accept a shared parent cgroup' >&2
  exit 1
fi
printf 'Direct Proxy and device exclusion checks passed\n'
