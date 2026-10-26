#!/bin/sh
set -eu

# A saved list generation keeps each source under the URL it was downloaded
# from, and the mirror base URL is not part of the list signature. After an
# upgrade that moved the built-in lists to the Forkop mirror, or a change of
# mirror_base_url, the generation was valid but every built-in list missed:
# the start then downloaded them before sing-box ran, through a list service
# proxy that was not listening yet, and every attempt failed.
#
# The same file from the mirror, jsDelivr or GitHub raw is now found in the
# generation, and a start with a source that is really missing prepares the
# generation anew (service/lifecycle.uc) instead of applying it.

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATES="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"
LIFECYCLE="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() {
  printf 'list_cache_source_identity: FAIL: %s\n' "$1" >&2
  exit 1
}

{
  printf '%s\n' 'function as_string(value) { return value == null ? "" : "" + value; }'
  printf '%s\n' 'let list_download_cache = {};'
  source_between "$UPDATES" '^// The same list file reached from the Forkop mirror' '^function download_to_file\(' ||
    fail "the source identity functions were not found"
} >"$WORK_DIR/harness.uc"
cat >>"$WORK_DIR/harness.uc" <<'UCODE'
function check(condition, message) { if (!condition) die(message + "\n"); }
const P = "Subnets/IPv4/discord.lst";
const MIRROR = "https://mirror.infotechtg.ru/forkop/lists/allow-domains/" + P;
const OTHER_MIRROR = "https://lists.example.net/forkop/lists/allow-domains/" + P;
const JSDELIVR = "https://cdn.jsdelivr.net/gh/itdoginfo/allow-domains@main/" + P;
const RAW = "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/" + P;

for (let url in [ MIRROR, OTHER_MIRROR, JSDELIVR, RAW ])
    check(list_source_identity(url) == "allow-domains:" + P, "wrong identity for " + url + ": " + list_source_identity(url));
check(list_source_identity("https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/x.lst") ==
    list_source_identity("https://cdn.jsdelivr.net/gh/Greeg0ry/b4geoip-forkop@main/x.lst"), "b4geoip sources differ");
check(list_source_identity("https://raw.githubusercontent.com/someone/allow-domains/main/" + P) == "",
    "a foreign repository was taken for the built-in lists");
check(list_source_identity("https://example.com/my-list.lst") == "", "a custom URL got an identity");
check(list_source_identity("https://github.com/itdoginfo/allow-domains/releases/latest/download/x.srs") == "",
    "a release asset got a list identity");

list_download_cache = {};
list_download_cache[RAW] = "/cache/source-1";
check(cached_list_source(MIRROR) == "/cache/source-1", "a raw-era generation did not serve the mirror URL");
check(cached_list_source(OTHER_MIRROR) == "/cache/source-1", "another mirror base missed");
check(cached_list_source("https://mirror.infotechtg.ru/forkop/lists/allow-domains/Subnets/IPv6/discord.lst") == "",
    "the IPv6 list was served the IPv4 file");
check(cached_list_source("https://example.com/my-list.lst") == "", "an uncached custom URL was served");
list_download_cache["https://example.com/my-list.lst"] = "/cache/source-2";
check(cached_list_source("https://example.com/my-list.lst") == "/cache/source-2", "an exact URL missed");
print("ok\n");
UCODE

out="$(ucode "$WORK_DIR/harness.uc" 2>&1)" || fail "$out"
[ "$out" = "ok" ] || fail "$out"

source_require "$LIFECYCLE"
grep -q '"list-cache-complete"' "$LIFECYCLE" ||
  fail "the start does not check that the saved generation holds every source"
grep -q 'mode == "list-cache-complete"' "$UPDATES" || fail "updates.uc has no list-cache-complete mode"

printf 'list_cache_source_identity: PASS\n'
