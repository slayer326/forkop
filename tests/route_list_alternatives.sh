#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {".name":"settings", ".type":"settings", "dns_server":"77.88.8.8"},
  "section": [{
    ".name":"direct", ".type":"section", "enabled":"1", "action":"bypass",
    "domain_suffix":["inline.example"], "community_lists":["youtube"],
    "source_ip_cidr":["192.0.2.10/32"], "ports":["443"]
  }]
}
JSON
for version in 1.13.0 1.14.0; do
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 127.0.0.1 0 1 '' "$version"
  ucode -e '
    let config = json(require("fs").readfile(ARGV[0]));
    let domain_rule = null, list_rule = null;
    for (let rule in config.route.rules || []) {
      if (rule.outbound != "bypass-out" || rule.action != "route") continue;
      if (rule.domain_suffix != null) domain_rule = rule;
      if (rule.rule_set != null) list_rule = rule;
    }
    if (domain_rule == null || list_rule == null || domain_rule.rule_set != null || list_rule.domain_suffix != null)
      die("inline domains and lists must remain separate route alternatives\n");
    if (sprintf("%J", domain_rule.port) != sprintf("%J", list_rule.port) || domain_rule.port == null)
      die("both alternatives must retain port filters\n");
    if (sprintf("%J", domain_rule.source_ip_cidr) != sprintf("%J", list_rule.source_ip_cidr) || domain_rule.source_ip_cidr == null)
      die("both alternatives must retain source device filters\n");
  ' "$WORK_DIR/config.json"
done
printf 'route list alternative checks passed\n'
