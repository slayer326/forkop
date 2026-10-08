# OpenWrt dependency mirror

`sync-openwrt.sh` mirrors the OpenWrt target, kernel, and package feeds needed by
Forkop. Supported platforms are configured with one target/architecture pair per
line. Blank lines, full-line comments, and trailing comments are accepted:

```text
mediatek/filogic aarch64_cortex-a53
rockchip/armv8 aarch64_generic
# Optional examples:
x86/64 x86_64
ramips/mt7621 mipsel_24kc
```

The `rockchip/armv8 aarch64_generic` mapping is published by OpenWrt in the
[`24.10.6`](https://downloads.openwrt.org/releases/24.10.6/targets/rockchip/armv8/profiles.json)
and [`25.12.3`](https://downloads.openwrt.org/releases/25.12.3/targets/rockchip/armv8/profiles.json)
target profiles.

Copy `openwrt-platforms.conf.example` to
`/etc/forkop-mirror/platforms.conf`, copy `openwrt-mirror.env.example` to
`/etc/default/forkop-openwrt-mirror`, and run the systemd service. The
environment file is optional. Without a configured file, the script retains the
legacy single-platform default (`mediatek/filogic aarch64_cortex-a53`). Existing
`OPENWRT_TARGET` and `OPENWRT_ARCH` variables also retain their single-platform
behavior.

After every completely successful run, the script atomically publishes
`/openwrt/forkop-platforms.tsv`. Each row contains:

```text
target<TAB>architecture<TAB>release<TAB>format
```

The installer uses this endpoint to reject unavailable combinations before
changing package feeds. If the endpoint is absent (for compatibility with an
older mirror), it falls back to changing the feeds transactionally and checking
them with `opkg update` or `apk update`. The default dependency mirror in this
fork is `https://mirror.infotechtg.ru`: its readiness index is mandatory, so a
missing index never starts a feed migration. Forkop releases still come from
`https://fold8.ru/forkop`, not from the upstream author's release repository.

The own-mirror synchronization configuration includes OpenWrt **24.10.0,
24.10.1, 24.10.5 and 25.12.5** for Filogic and Rockchip. These are planned
combinations, not a promise that all files have already finished downloading;
consult the live platform index before installation. The exact release and
kernel ABI in an existing feed URL are preserved. Third-party firmware feeds
are not replaced. The previous built-in `mirror.51343.ru` URLs are migrated to
the own mirror; an APK key replacement is rolled back with the feeds if package
index validation fails.

Adding a line can require substantial storage: every target has its own package
and kernel ABI trees, while package feeds are downloaded once per unique
architecture. A merged code change does not enable a platform on the public
mirror; the mirror operator must update the production configuration and finish
a full successful synchronization first.

`sync-forkop-release.py` reads the latest stable release from
`https://fold8.ru/forkop/updates/latest.json`, constrains package URLs to that
release directory, verifies SHA-256 for all six packages, and calls
`publish-forkop-feed.sh` to create the signed APK repository under
`/forkop/mirror/current/`. The publisher also builds an atomic
`/forkop/updates/releases.json` catalog from complete local release sets. Run it with
`forkop-release-sync.service` after placing the OpenWrt host `apk` tool at the
configured path. The release service does not build packages on the mirror host.

## Zapret-Manager cache (home mirror)

`home/zapret-compose.yml` runs a separate, non-root Python service with no published
host ports, 128 MiB RAM, 0.25 CPU and 32 PIDs. Its cache is limited to 2 GiB/512
entries, downloads to 128 MiB, and request workers to eight. Only the repositories
listed in `zapret-manager-cache.py` and the two Routerich feed directories are
accepted. Redirect destinations and resolved public IP addresses are checked;
TLS still verifies the original hostname. No credentials or request URLs are logged.
The cache container uses its own public DNS resolvers (1.1.1.1/8.8.8.8), since
the home LAN resolver can return Fake-IP addresses. Host and other containers'
DNS settings are not changed.

The entry script served from Screamshow/Zapret-Manager is adapted to default to
`https://mirror.infotechtg.ru`, including after it recreates its own launchers.
This is a download cache, not validation or endorsement of every optional action
in the third-party manager. Some optional tools still use their original external
URLs; do not claim the manager is completely offline or install it unattended.

On the existing home deployment, use the pinned, locally available Python image
in `home/zapret-compose.yml`. Install the script/config under
`/mnt/storage/forkop-mirror/config/` and create only
`/mnt/storage/forkop-mirror/data/cache/zapret-manager` owned by 65534:65534.
Start the separate compose project, warm the manager endpoint, and validate
`home/web-with-zapret.Caddyfile` before applying it to the mirror's own web service.
Back up its old Caddyfile first. Never restart the shared edge Caddy or other
projects. Rollback: restore that Caddyfile, restart only
`forkop-mirror-web.service`, then stop only the cache compose project.

The home mirror uses `home/prune_stale_snapshots.py` to reclaim completed
OpenWrt snapshots no longer referenced by public feeds. It preserves published
snapshots and incomplete snapshots modified in the last seven days. Older
unfinished snapshots are removed only while holding the synchronizer lock;
the same rule runs before each scheduled sync so abandoned attempts cannot
accumulate indefinitely. Unreferenced dated list snapshots are removed after
the next list snapshot is published; a broken or missing public list target
blocks their cleanup. Published sing-box releases remain intact. Unlinked
content-addressed objects are removed too.
Run it without arguments for a dry-run; `--apply` performs cleanup under the
same lock as the synchronizer. The deployed synchronizer also runs this cleanup
before each daily refresh, so no separate cleanup timer is needed.

The home synchronizer source and its tests are in `home/sync.py`,
`home/guard.py`, `home/fast_https.py`, `home/test_sync.py`, and
`home/test_fast_https.py`. A downloaded OpenWrt package must match the package
index before it is published. Verification mismatches are retried with a fresh
request. A response that ends before its declared length is retried with HTTP
Range when a package digest or strong ETag can validate the combined file.
Mismatched ranges are never appended. Persistent failures defer only the
affected platform and preserve the last published feed; the journal records
the failing package name and distinguishes incomplete transfers from content
mismatches. Run `python3 -m unittest -q test_sync test_fast_https test_archive_sing_box`
from `home/` on Linux before deploying a synchronizer change. Do not restart
the web service to apply a synchronizer-only change.

After OpenWrt feed work, `home/archive_sing_box.py` retains `sing-box` and
`sing-box-tiny` IPK/APK packages from complete published feeds under
`/forkop/sing-box-archive/blobs/<sha256>/`. Its atomic `packages.json` catalog
lists the exact version, architecture, format and hash. Existing archived
versions remain available when an upstream feed rotates; corrupt blobs stop
archive publication without replacing the last catalog. The archive is not
used as a rollback source on routers until the matching client-side change has
passed package and router validation. Include `test_archive_sing_box` in the
Linux test run before deploying the next synchronizer revision.

On the home server, after the synchronization service is idle:

```sh
python3 /mnt/storage/forkop-mirror/config/prune_stale_snapshots.py
python3 /mnt/storage/forkop-mirror/config/prune_stale_snapshots.py --apply
```

Release branches `codex/release-*` build downloadable candidate artifacts without
publishing. Tag publication is gated by backend and frontend tests. A real OpenWrt
router smoke test (upgrade, arbitrary HTTPS subscription, URLTest/Priority, latency,
reload and reboot recovery) is still required before tagging a stable release.
