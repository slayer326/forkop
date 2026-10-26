#!/bin/sh
set -eu

# podkop-engine r13 and later retries a uTLS handshake whose ClientHello goes
# unanswered with another fingerprint, when config.json carries
# experimental.utls_fallback. Its chrome fingerprint sends the X25519MLKEM768
# key; that ClientHello is frozen on some ISP paths, so links with fp=chrome
# lost their server after the switch to podkop-engine.
#
# Forkop writes the section only for a core that names tls.utls-fallback in
# its Features line (stock sing-box rejects an unknown experimental field),
# keeps it in the list-download bootstrap, and leaves it out with
# forkop.settings.utls_fallback=0.

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/singbox/generator.uc"
RUNTIME="$FORKOP_LIB/singbox/runtime.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

fail() {
  printf 'podkop_engine_utls_fallback: FAIL: %s\n' "$1" >&2
  exit 1
}

PDK_R16='sing-box version 1.14.3-pdk-r16

Tags: with_quic,with_utls,with_clash_api,podkop_slim
Features: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link,tls.utls-fallback'

runtime() {
  ucode -L "$FORKOP_LIB" "$RUNTIME" "$@" >/dev/null 2>&1
}

runtime supports-utls-fallback "1.14.3-pdk-r16" "$PDK_R16" || fail "tls.utls-fallback was not detected"
if runtime supports-utls-fallback "1.14.3-pdk-r12" "sing-box version 1.14.3-pdk-r12
Features: urltest.fallbacks,transport.xhttp"; then
  fail "a podkop-engine without tls.utls-fallback was given the fallback"
fi
if runtime supports-utls-fallback "1.14.3-extended-2.7.3" "Features: tls.utls-fallback"; then
  fail "a Features line made sing-box-extended support the fallback"
fi

generate() {
  name=$1 settings=$2 supports=$3
  cat >"$WORK_DIR/$name.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8"$settings },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix": ["example.com"] }
  ]
}
JSON
  ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/$name.json" "$WORK_DIR/$name.config.json" 192.0.2.1 0 1 '' 1.14.3-pdk-r16 "$supports" \
    >/dev/null 2>"$WORK_DIR/$name.err" || fail "generator failed for $name: $(cat "$WORK_DIR/$name.err")"
}

fallback() {
  ucode -e 'let c = json(require("fs").readfile(ARGV[0])); let e = c.experimental;
    print(type(e) != "object" || e.utls_fallback == null ? "<none>" : sprintf("%J", e.utls_fallback));' \
    "$WORK_DIR/$1.config.json"
}

generate supported "" 1
[ "$(fallback supported)" = '{ "enabled": true }' ] || fail "the fallback was not enabled: $(fallback supported)"

generate unsupported "" 0
[ "$(fallback unsupported)" = "<none>" ] || fail "a core without the feature was given the section"

generate unknown "" ""
[ "$(fallback unknown)" = "<none>" ] || fail "an unknown core was given the section"

generate disabled ', "utls_fallback": "0"' 1
[ "$(fallback disabled)" = "<none>" ] || fail "utls_fallback=0 did not turn the section off"

# The cold-start list download dials the proxy section through its own config.
cat >"$WORK_DIR/bootstrap.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8",
    "download_lists_via_proxy": "1", "download_lists_via_proxy_section": "main" },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix": ["example.com"] }
  ]
}
JSON
FORKOP_LIFECYCLE_LIST_BOOTSTRAP=1 ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/bootstrap.json" "$WORK_DIR/bootstrap.config.json" 192.0.2.1 0 1 '' 1.14.3-pdk-r16 1 \
  >/dev/null 2>"$WORK_DIR/bootstrap.err" || fail "bootstrap generator failed: $(cat "$WORK_DIR/bootstrap.err")"
[ "$(fallback bootstrap)" = '{ "enabled": true }' ] || fail "the list bootstrap lost the fallback: $(fallback bootstrap)"
ucode -e 'let c = json(require("fs").readfile(ARGV[0]));
  exit(c.experimental.clash_api == null && c.experimental.cache_file == null ? 0 : 1);' \
  "$WORK_DIR/bootstrap.config.json" || fail "the list bootstrap kept the Clash API or the shared cache"

printf 'podkop_engine_utls_fallback: PASS\n'
