# Upstream Forkop X 2.4.4 audit (2026-10-25)

Source: https://github.com/Screamshow/forkop-x/releases and upstream `main` at
`bbf1e93f`, two commits past the 2.4.4 tag. Changes are adapted selectively, as
in the [2.4.3 audit](upstream-2.4.3-audit.md).

| Upstream change | Decision |
| --- | --- |
| 2.4.4 spaces in the Trojan link display name (`222f8761`) | Ported in 1.0.58 for every link type with a `#` name: VLESS, Trojan, Shadowsocks, SOCKS and Hysteria2 (upstream changed Trojan only). Whitespace before the name and control characters anywhere are still rejected. The backend drops the name before parsing (`core/url.uc` `strip_fragment`), and `selector_proxy_links` is a UCI list, so a name with spaces is not split. VMess is base64 and is unchanged. |
| End component readiness waits after terminal startup failures (`8c5f46f0`) | Adapted in 1.0.58. Here a rejected configuration already ends the start through `service/initd.uc` `start_and_wait`, which reads the start's own result, so the readiness wait in `components/action.uc` only runs after a successful start. Its 180 s limit counted only its 4 s sleeps; status probes (up to 6 s) and the 8 s confirmation made it about 450 s for a core that died after its start. The limit is now monotonic elapsed time. Upstream's `start.failure` check is not taken: this fork writes that marker only for `runtime_guard_active`. Covered by `tests/component_readiness_deadline.sh`. |
| 2.4.4 Save & Apply native handler dispatch (`8c3622aa`) | Not applicable: this fork's `forkop.js` `handleSaveApply` saves and applies itself and does not dispatch through `view.handleSaveApply`. |
| 2.4.4 Forkop-only interface language switch (`f7a36535`) | Deferred: a new Updates-tab control and a translation loader that needs visual verification in LuCI. Its updater change that always installs `luci-i18n-forkop-ru` only serves the switch, and would reinstall the package for users who removed it. |

No Tailscale, Xrust, nftables, DNS or QUIC settings are altered by this release.
