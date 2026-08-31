#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 BUILD_DIRECTORY VERSION" >&2
    exit 2
fi

BUILD_DIRECTORY="$1"
VERSION="$2"
MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/forkop}"
PRIVATE_KEY="${FORKOP_APK_PRIVATE_KEY:-/srv/mirror/keys/forkop-apk.pem}"
APK_BIN="${APK_BIN:-/root/.cache/forkop/openwrt-sdk/extracted/apk/staging_dir/host/bin/apk}"
STAGING="$MIRROR_ROOT/mirror/.${VERSION}.staging"
DESTINATION="$MIRROR_ROOT/mirror/releases/$VERSION"
UPDATES_STAGING="$MIRROR_ROOT/updates/.${VERSION}.staging"
UPDATES_DESTINATION="$MIRROR_ROOT/updates/releases/$VERSION"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Invalid APK feed version: $VERSION" >&2
    exit 1
}
[[ -x "$APK_BIN" ]] || {
    echo "OpenWrt apk host tool is unavailable: $APK_BIN" >&2
    exit 1
}

install -d -m 0700 "$(dirname "$PRIVATE_KEY")"
if [[ ! -s "$PRIVATE_KEY" ]]; then
    openssl ecparam -name prime256v1 -genkey -noout -out "$PRIVATE_KEY"
    chmod 0600 "$PRIVATE_KEY"
fi

mkdir -p "$MIRROR_ROOT/mirror/releases"
mkdir -p "$MIRROR_ROOT/updates/releases"
rm -rf "$STAGING" "$UPDATES_STAGING"
mkdir -p "$STAGING" "$UPDATES_STAGING"

for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
    for extension in apk ipk; do
        source_file="$BUILD_DIRECTORY/${package}_${VERSION}.${extension}"
        [[ -s "$source_file" ]] || {
            echo "Missing package artifact: $source_file" >&2
            exit 1
        }
        if [[ "$extension" == "apk" ]]; then
            cp "$source_file" "$STAGING/${package}-${VERSION}.apk"
        else
            cp "$source_file" "$STAGING/"
        fi
        cp "$source_file" "$UPDATES_STAGING/${package}_${VERSION}.${extension}"
    done
done

openssl ec -in "$PRIVATE_KEY" -pubout \
    -out "$MIRROR_ROOT/forkop-apk.pem" 2>/dev/null

(
    cd "$STAGING"
    "$APK_BIN" mkndx \
        --allow-untrusted \
        --sign-key "$PRIVATE_KEY" \
        --description "Forkop mirror packages" \
        --output packages.adb \
        ./*.apk
    "$APK_BIN" verify --keys-dir "$MIRROR_ROOT" packages.adb
    sha256sum ./*.apk ./*.ipk packages.adb > SHA256SUMS
)

rm -rf "$DESTINATION"
mv "$STAGING" "$DESTINATION"
ln -sfn "releases/$VERSION" "$MIRROR_ROOT/mirror/current"
printf '%s\n' "$VERSION" > "$MIRROR_ROOT/MIRROR_LATEST"

cat > "$UPDATES_STAGING/release.json" <<EOF
{
  "tag_name": "$VERSION",
  "html_url": "/forkop/updates/releases/$VERSION/",
  "assets": [
    {"name": "forkop_$VERSION.apk", "browser_download_url": "/forkop/updates/releases/$VERSION/forkop_$VERSION.apk"},
    {"name": "luci-app-forkop_$VERSION.apk", "browser_download_url": "/forkop/updates/releases/$VERSION/luci-app-forkop_$VERSION.apk"},
    {"name": "luci-i18n-forkop-ru_$VERSION.apk", "browser_download_url": "/forkop/updates/releases/$VERSION/luci-i18n-forkop-ru_$VERSION.apk"},
    {"name": "forkop_$VERSION.ipk", "browser_download_url": "/forkop/updates/releases/$VERSION/forkop_$VERSION.ipk"},
    {"name": "luci-app-forkop_$VERSION.ipk", "browser_download_url": "/forkop/updates/releases/$VERSION/luci-app-forkop_$VERSION.ipk"},
    {"name": "luci-i18n-forkop-ru_$VERSION.ipk", "browser_download_url": "/forkop/updates/releases/$VERSION/luci-i18n-forkop-ru_$VERSION.ipk"}
  ]
}
EOF
rm -rf "$UPDATES_DESTINATION"
mv "$UPDATES_STAGING" "$UPDATES_DESTINATION"
cp "$UPDATES_DESTINATION/release.json" "$MIRROR_ROOT/updates/latest.json"

echo "Published signed Forkop APK feed $VERSION"
