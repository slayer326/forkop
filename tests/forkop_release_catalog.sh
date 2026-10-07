#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
ACTION_UC="$FORKOP_LIB/components/action.uc"
BASE_URL="https://mirror.test/forkop"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

catalog() {
  FORKOP_RELEASE_BASE_URL="$BASE_URL" \
    ucode -L "$FORKOP_LIB" "$ACTION_UC" forkop-release-catalog-fixture "$1" "${2:-ipk}"
}

accepted() {
  catalog "$1" "${2:-ipk}" | tr '{' '\n' | sed -n 's/.*"tag_name": "\([0-9.]*\)".*/\1/p' | sort -u | tr '\n' ' '
}

assets() {
  local version="$1" ext="$2" digest="$3" url_prefix="$4"
  local out="" name
  for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
    name="${package}_${version}.${ext}"
    [ -n "$out" ] && out="$out,"
    out="$out{\"name\":\"$name\",\"sha256\":\"$digest\",\"browser_download_url\":\"${url_prefix}${name}\"}"
  done
  printf '%s' "$out"
}

good="$(printf 'a%.0s' $(seq 64))"

# A complete release, addressed the way the mirror publishes it.
cat >"$WORK_DIR/valid.json" <<JSON
{"format":1,"releases":[
 {"tag_name":"1.0.30","channel":"stable","html_url":"$BASE_URL/releases/1.0.30/",
  "assets":[$(assets 1.0.30 ipk "$good" "$BASE_URL/releases/1.0.30/")]}
]}
JSON
[ "$(accepted "$WORK_DIR/valid.json")" = "1.0.30 " ] ||
  fail "a complete catalog entry was rejected"

# The same entry must not satisfy an apk system: the packages differ.
[ "$(accepted "$WORK_DIR/valid.json" apk)" = "" ] ||
  fail "an ipk-only entry was accepted for apk"

# A download URL outside this release's directory is the case this guard
# exists for: a rewritten catalog must not redirect an install elsewhere.
cat >"$WORK_DIR/foreign.json" <<JSON
{"format":1,"releases":[
 {"tag_name":"1.0.30","channel":"stable","html_url":"$BASE_URL/releases/1.0.30/",
  "assets":[$(assets 1.0.30 ipk "$good" "https://evil.test/")]}
]}
JSON
[ "$(accepted "$WORK_DIR/foreign.json")" = "" ] ||
  fail "a foreign download URL was accepted"

# A missing or malformed checksum leaves the download unverifiable.
cat >"$WORK_DIR/digest.json" <<JSON
{"format":1,"releases":[
 {"tag_name":"1.0.30","channel":"stable","html_url":"$BASE_URL/releases/1.0.30/",
  "assets":[$(assets 1.0.30 ipk "nope" "$BASE_URL/releases/1.0.30/")]}
]}
JSON
[ "$(accepted "$WORK_DIR/digest.json")" = "" ] ||
  fail "a malformed sha256 was accepted"

# One missing package makes the release uninstallable as a set.
cat >"$WORK_DIR/partial.json" <<JSON
{"format":1,"releases":[
 {"tag_name":"1.0.30","channel":"stable","html_url":"$BASE_URL/releases/1.0.30/",
  "assets":[{"name":"forkop_1.0.30.ipk","sha256":"$good","browser_download_url":"$BASE_URL/releases/1.0.30/forkop_1.0.30.ipk"}]}
]}
JSON
[ "$(accepted "$WORK_DIR/partial.json")" = "" ] ||
  fail "an incomplete release was accepted"

# A bad entry must not discard the rest of the catalog.
cat >"$WORK_DIR/mixed.json" <<JSON
{"format":1,"releases":[
 {"tag_name":"1.0.31","channel":"stable","html_url":"$BASE_URL/releases/1.0.31/",
  "assets":[$(assets 1.0.31 ipk "$good" "https://evil.test/")]},
 {"tag_name":"1.0.30","channel":"stable","html_url":"$BASE_URL/releases/1.0.30/",
  "assets":[$(assets 1.0.30 ipk "$good" "$BASE_URL/releases/1.0.30/")]}
]}
JSON
[ "$(accepted "$WORK_DIR/mixed.json")" = "1.0.30 " ] ||
  fail "a rejected entry discarded the valid ones"

# Anything that is not this catalog format yields nothing to install.
printf 'not json' >"$WORK_DIR/broken.json"
[ "$(accepted "$WORK_DIR/broken.json")" = "" ] || fail "malformed JSON was accepted"
printf '{"format":2,"releases":[]}' >"$WORK_DIR/format.json"
[ "$(accepted "$WORK_DIR/format.json")" = "" ] || fail "an unknown catalog format was accepted"

# A previous release can be recovered from the public package directory even
# when its GitHub Release is missing, but only with a complete checksum set.
previous_from_sums() {
  FORKOP_RELEASE_BASE_URL="$BASE_URL" \
    ucode -L "$FORKOP_LIB" "$ACTION_UC" previous-forkop-checksums-fixture \
      1.0.41 "$1" apk
}
for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
  printf '%s  %s_1.0.41.apk\n' "$good" "$package" >>"$WORK_DIR/previous.sums"
done
[ "$(previous_from_sums "$WORK_DIR/previous.sums" | grep -o 'browser_download_url' | wc -l)" -eq 3 ] ||
  fail "complete previous release checksums were rejected"
printf '%s  %s\n' "$good" 'forkop_1.0.41.apk' >>"$WORK_DIR/previous.sums"
[ "$(previous_from_sums "$WORK_DIR/previous.sums")" = 'null' ] ||
  fail "duplicate previous release checksum was accepted"
printf '%s  %s\n' "$good" 'forkop_1.0.41.apk' >"$WORK_DIR/previous.sums"
[ "$(previous_from_sums "$WORK_DIR/previous.sums")" = 'null' ] ||
  fail "incomplete previous release checksum set was accepted"

printf 'forkop release catalog: PASS\n'
