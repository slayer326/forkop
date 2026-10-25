#!/bin/sh
set -eu

# podkop-engine (github.com/podkop-net/podkop-engine) as a sing-box variant.
#
# singbox/runtime.uc tells it by its <version>-pdk-r<revision> version and
# takes XHTTP support from the Features: line of `sing-box version`.
# components/action.uc picks the package from a GitHub releases list: the
# newest release of the 1.14 line, or exactly the installed one for a
# rollback, only with files of that very release, and its SHA256SUMS entry.
#
# The real functions run against fixtures; nothing is downloaded or installed.

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
ACTION="$FORKOP_LIB/components/action.uc"
RUNTIME="$FORKOP_LIB/singbox/runtime.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() {
  printf 'podkop_engine_variant: FAIL: %s\n' "$1" >&2
  exit 1
}

runtime() {
  ucode -L "$FORKOP_LIB" "$RUNTIME" "$@" >/dev/null 2>&1
}

PDK_OUTPUT='sing-box version 1.14.3-pdk-r16

Tags: with_quic,with_utls,with_clash_api,podkop_slim
Features: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link'

runtime is-podkop-engine "1.14.3-pdk-r16" || fail "a -pdk- version was not taken for podkop-engine"
if runtime is-podkop-engine "1.14.3-extended-2.7.3"; then fail "sing-box-extended was taken for podkop-engine"; fi
if runtime is-podkop-engine "1.14.3"; then fail "stable sing-box was taken for podkop-engine"; fi
runtime supports-xhttp "1.14.3-pdk-r16" "$PDK_OUTPUT" || fail "podkop-engine with transport.xhttp lost XHTTP"
if runtime supports-xhttp "1.14.3-pdk-r10" "sing-box version 1.14.3-pdk-r10"; then
  fail "podkop-engine without a Features line was given XHTTP"
fi
if runtime supports-xhttp "1.14.3" "Features: transport.xhttp"; then
  fail "a Features line made stable sing-box support XHTTP"
fi
runtime supports-xhttp "1.14.3-extended-2.7.3" "" || fail "sing-box-extended lost XHTTP"

{
  printf '%s\n' 'function as_string(value) { return value == null ? "" : "" + value; }'
  source_between "$ACTION" '^const PODKOP_ENGINE_REPO_OWNER = ' '^function resolve_podkop_engine_release\(' ||
    fail "the podkop-engine release functions were not found"
  source_between "$ACTION" '^function podkop_engine_checksum\(' '^// The package file in tmp_dir' ||
    fail "the podkop-engine checksum function was not found"
} >"$WORK_DIR/harness.uc"
cat >>"$WORK_DIR/harness.uc" <<'UCODE'
function check(condition, message) { if (!condition) die(message + "\n"); }
const D = "https://github.com/podkop-net/podkop-engine/releases/download/";
const H = "https://github.com/podkop-net/podkop-engine/releases/tag/";
function release(tag, names, extra) {
    let assets = [];
    for (let name in names)
        push(assets, { name, browser_download_url: D + tag + "/" + name });
    let value = { tag_name: tag, html_url: H + tag, draft: false, prerelease: false, assets };
    for (let key in (extra || {}))
        value[key] = extra[key];
    return value;
}
const A = "aarch64_cortex-a53";
function pkg(name, version) { return name + "_" + version + "_openwrt_" + A + ".apk"; }
function both(version) { return [ pkg("podkop-engine", version), pkg("podkop-engine-full", version), "SHA256SUMS" ]; }

let list = sprintf("%J", [
    release("v1.13.21-r17", both("1.13.21-r17")),
    release("v1.14.4-r1", both("1.14.4-r1"), { prerelease: true }),
    release("v1.14.4-r0", both("1.14.4-r0"), { draft: true }),
    release("v1.14.3-r16", both("1.14.3-r16")),
    release("v1.14.3-r15", both("1.14.3-r15"))
]);

let latest = podkop_engine_release_from_json(list, "podkop-engine", A, "apk", "");
check(latest != null && latest.version == "1.14.3-r16", "the newest published 1.14 release was not chosen");
check(latest.asset_url == D + "v1.14.3-r16/" + pkg("podkop-engine", "1.14.3-r16"), "wrong package asset");
check(latest.sums_url == D + "v1.14.3-r16/SHA256SUMS", "wrong SHA256SUMS asset");
check(latest.release_url == H + "v1.14.3-r16", "wrong release page");

let full = podkop_engine_release_from_json(list, "podkop-engine-full", A, "apk", "");
check(full != null && full.asset_name == pkg("podkop-engine-full", "1.14.3-r16"), "the full package was not chosen");

let rollback = podkop_engine_release_from_json(list, "podkop-engine", A, "apk", "1.14.3-r15");
check(rollback != null && rollback.version == "1.14.3-r15", "a rollback did not get its exact release");

check(podkop_engine_release_from_json(list, "podkop-engine", "mips_24kc", "apk", "") == null,
    "an older release was taken when the newest lacks this architecture");
check(podkop_engine_release_from_json(list, "podkop-engine", A, "apk", "1.14.2-r14") == null,
    "a missing rollback release was invented");

let foreign = sprintf("%J", [ release("v1.14.3-r16", both("1.14.3-r16")) ]);
foreign = replace(foreign, D + "v1.14.3-r16/podkop-engine_", "https://example.com/podkop-engine_");
check(podkop_engine_release_from_json(foreign, "podkop-engine", A, "apk", "") == null,
    "a package outside the release was accepted");
check(podkop_engine_release_from_json("not json", "podkop-engine", A, "apk", "") == null, "invalid JSON was accepted");

check(podkop_engine_package_version("1.14.3-pdk-r16") == "1.14.3-r16", "binary version was not mapped to the package");
check(podkop_engine_package_version("v1.14.3-r16") == "1.14.3-r16", "release tag was not mapped to the package");
check(podkop_engine_package_version("1.14.3-extended-2.7.3") == "", "a foreign version was mapped");
check(podkop_engine_package_name("podkop-engine-full") == "podkop-engine-full", "full variant package");
check(podkop_engine_package_name("podkop-engine") == "podkop-engine", "slim variant package");

let sums = "aaaa  other\n" +
    "9989ee75d924a9f6e473b2c50d197387d08e92f9fa6eb1a76abf36f1f1b5bd63  " + pkg("podkop-engine-full", "1.14.3-r16") + "\n" +
    "be33a2f27d6f41eaa128ed82525dbc91a4ad2f9b1134dab354cb7b824599b060 *" + pkg("podkop-engine", "1.14.3-r16") + "\n";
check(podkop_engine_checksum(sums, pkg("podkop-engine", "1.14.3-r16")) == "be33a2f27d6f41eaa128ed82525dbc91a4ad2f9b1134dab354cb7b824599b060",
    "a checksum was not read");
check(podkop_engine_checksum(sums, pkg("podkop-engine", "1.14.3-r15")) == "", "a checksum was invented for an unlisted file");
print("ok\n");
UCODE

out="$(ucode "$WORK_DIR/harness.uc" 2>&1)" || fail "$out"
[ "$out" = "ok" ] || fail "$out"

printf 'podkop_engine_variant: PASS\n'
