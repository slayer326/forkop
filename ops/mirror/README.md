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

`sync-forkop-release.py` checks the latest stable GitHub release assets, verifies
their declared size and SHA-256 digest, and calls `publish-forkop-feed.sh` to
create the signed APK repository under `/forkop/mirror/current/`. Run it with
`forkop-release-sync.service` after placing the OpenWrt host `apk` tool at the
configured path. The release service does not build packages on the mirror host.

## Zapret-Manager cache (home mirror)

`home/zapret-compose.yml` runs a separate, non-root Python service with no published
host ports, 128 MiB RAM, 0.25 CPU and 32 PIDs. Its cache is limited to 2 GiB/512
entries, downloads to 128 MiB, and request workers to eight. Only the repositories
listed in `zapret-manager-cache.py` and the two Routerich feed directories are
accepted. Redirect destinations and resolved public IP addresses are checked;
TLS still verifies the original hostname. No credentials or request URLs are logged.

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

Release branches `codex/release-*` build downloadable candidate artifacts without
publishing. Tag publication is gated by backend and frontend tests. A real OpenWrt
router smoke test (upgrade, arbitrary HTTPS subscription, URLTest/Priority, latency,
reload and reboot recovery) is still required before tagging a stable release.
