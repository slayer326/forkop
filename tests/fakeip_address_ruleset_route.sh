#!/usr/bin/env bash
set -euo pipefail

# On sing-box 1.14 a domain whose real answer falls into an address rule-set
# (the cloudflare community list, for one) is answered with FakeIP, so its
# connection reaches the route with the domain only. The address rule-set that
# chose it cannot match a domain, and the connection fell through to
# route.final (direct): bt4.t-ru.org, on Cloudflare, left the router directly
# and timed out. A resolve rule before the first route rule with such a
# rule-set gives those rules the addresses.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'fakeip_address_ruleset_route: FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name":"settings", ".type":"settings", "dns_server":"77.88.8.8" },
  "section": [
    {
      ".name":"main", ".type":"section", "enabled":"1", "action":"connection",
      "outbound_jsons":["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix":["listed.example"],
      "community_lists":["youtube","cloudflare"]
    }
  ]
}
JSON

check_config() {
  ucode -e '
    let c = json(require("fs").readfile(ARGV[0]));
    let expect_resolve = ARGV[1] == "1";
    function tags(rule) {
      let out = [];
      if (rule.rule_set != null) out = type(rule.rule_set) == "array" ? rule.rule_set : [ rule.rule_set ];
      for (let child in rule.rules || []) out = [ ...out, ...tags(child) ];
      return out;
    }
    let resolve = -1, resolves = 0, domains = -1, cloudflare = -1;
    for (let i = 0; i < length(c.route.rules); i++) {
      let rule = c.route.rules[i], t = join(",", tags(rule));
      if (rule.action == "resolve" && rule.domain == null && rule.domain_suffix == null && rule.rule_set == null) {
        resolves++; resolve = i;
        if (rule.server != "dns-server") die("the resolve rule must use the main DNS server\n");
        if (index(sprintf("%J", rule.inbound), "tproxy-in") < 0) die("the resolve rule must be limited to the tproxy inbound\n");
      }
      if (domains < 0 && index(sprintf("%J", rule), "listed.example") >= 0) domains = i;
      if (cloudflare < 0 && index(t, "cloudflare") >= 0) cloudflare = i;
    }
    if (cloudflare < 0) die("no route rule for the cloudflare list\n");
    if (!expect_resolve) {
      if (resolves != 0) die("no resolve rule is expected without DNS response matching\n");
      exit(0);
    }
    if (resolves != 1) die(sprintf("expected one resolve rule, got %d\n", resolves));
    if (resolve != cloudflare - 1) die(sprintf("the resolve rule (%d) must directly precede the cloudflare rule (%d)\n", resolve, cloudflare));
    if (domains < 0 || domains > resolve) die("domain rules must stay ahead of the resolve rule\n");
    let response = false;
    for (let rule in c.dns.rules) if (index(sprintf("%J", rule), "match_response") >= 0 && index(sprintf("%J", rule), "cloudflare") >= 0) response = true;
    if (!response) die("the cloudflare list must be matched against the DNS response\n");
  ' "$1" "$2"
}

ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config-114.json" 192.0.2.1 0 1 '' 1.14.0
check_config "$WORK_DIR/config-114.json" 1 || fail "sing-box 1.14"

ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config-113.json" 192.0.2.1 0 1 '' 1.13.0
check_config "$WORK_DIR/config-113.json" 0 || fail "sing-box 1.13"

printf 'fakeip_address_ruleset_route: PASS\n'
